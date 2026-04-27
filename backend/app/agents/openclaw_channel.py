from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
import uuid
from collections.abc import Callable

from .base import AgentBackend, ChatAttachment, ChatRequest, StreamEmitter

_BRIDGE_CONNECT_RETRY_DELAYS = (0.25, 0.5, 1.0)
_PUSH_LISTENER_PING_INTERVAL_SECONDS = 60
_PUSH_LISTENER_PING_TIMEOUT_SECONDS = 60
_PUSH_LISTENER_RECV_IDLE_SECONDS = 90
_REQUEST_PING_INTERVAL_SECONDS = 60
_REQUEST_PING_TIMEOUT_SECONDS = 60
_LOG = logging.getLogger(__name__)


def _extract_text_candidates(frame: dict, current_text: str = "") -> str:
    candidates = [
        frame.get("reply"),
        frame.get("text"),
        frame.get("message"),
        frame.get("content"),
    ]
    payload = frame.get("payload")
    if isinstance(payload, dict):
        candidates.extend([
            payload.get("reply"),
            payload.get("text"),
            payload.get("message"),
            payload.get("content"),
        ])
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            return candidate
    return current_text


def _is_retryable_bridge_connect_error(exc: BaseException) -> bool:
    if isinstance(exc, (TimeoutError, ConnectionRefusedError)):
        return True
    if isinstance(exc, OSError):
        if exc.errno in {61, 111, 10061}:
            return True
        message = str(exc).lower()
        return "connect call failed" in message or "cannot connect" in message or "connection refused" in message
    return False


async def _open_bridge_connection(bridge_url: str, **connect_kwargs):
    try:
        import websockets
    except ModuleNotFoundError as exc:
        raise RuntimeError("Python package 'websockets' is missing.") from exc

    last_exc: BaseException | None = None
    attempts = len(_BRIDGE_CONNECT_RETRY_DELAYS) + 1
    connect_options = dict(connect_kwargs)
    connect_options.setdefault("open_timeout", 3.0)
    for attempt_index in range(attempts):
        try:
            return await websockets.connect(bridge_url, **connect_options)
        except Exception as exc:  # noqa: BLE001
            if not _is_retryable_bridge_connect_error(exc) or attempt_index >= attempts - 1:
                if _is_retryable_bridge_connect_error(exc):
                    raise RuntimeError(f"Unable to connect to OpenClaw bridge at {bridge_url} after {attempts} attempts: {exc}") from exc
                raise
            last_exc = exc
            await asyncio.sleep(_BRIDGE_CONNECT_RETRY_DELAYS[attempt_index])
    if last_exc is not None:
        raise RuntimeError(f"Unable to connect to OpenClaw bridge at {bridge_url}: {last_exc}") from last_exc
    raise RuntimeError(f"Unable to connect to OpenClaw bridge at {bridge_url}")


def _normalize_base64_payload(data: str) -> str:
    import re
    value = str(data or "").strip()
    if value.startswith("data:") and "," in value:
        value = value.split(",", 1)[1]
    value = re.sub(r"\s+", "", value)
    return value


def _prepare_bridge_attachments(attachments: list[ChatAttachment]) -> list[dict]:
    import base64
    import re
    result: list[dict] = []
    for att in attachments:
        if att.type == "url":
            result.append({
                "kind": "image",
                "url": att.data,
                "mimeType": att.media_type or "image/png",
            })
        elif att.type == "base64":
            normalized = _normalize_base64_payload(att.data)
            try:
                base64.b64decode(normalized, validate=True)
            except Exception as exc:
                preview = normalized[:48]
                raise RuntimeError(f"Invalid base64 image payload: prefix={preview!r}, len={len(normalized)}") from exc
            result.append({
                "kind": "image",
                "content": normalized,
                "mimeType": att.media_type or "image/png",
            })
    return result


_PUSH_CALLBACK: Callable[[dict], None] | None = None
_PUSH_THREADS: dict[str, threading.Thread] = {}
_PUSH_STOPS: dict[str, threading.Event] = {}


def set_push_callback(callback: Callable[[dict], None] | None) -> None:
    global _PUSH_CALLBACK
    _PUSH_CALLBACK = callback


def _emit_push_message(frame: dict) -> None:
    callback = _PUSH_CALLBACK
    if callback is not None:
        callback(frame)


def _listener_id(provider_config: dict) -> str:
    provider_id = str(provider_config.get("id") or "").strip()
    bridge_url = str(provider_config.get("bridgeUrl") or "ws://127.0.0.1:18800").strip()
    return provider_id or bridge_url


def ensure_bridge_listener(provider_config: dict) -> None:
    provider_type = str(provider_config.get("type") or "").strip()
    if provider_type != "openclaw-channel":
        return
    listener_id = _listener_id(provider_config)
    existing = _PUSH_THREADS.get(listener_id)
    if existing and existing.is_alive():
        return
    stop_event = threading.Event()
    _PUSH_STOPS[listener_id] = stop_event
    thread = threading.Thread(
        target=_run_bridge_listener_forever,
        args=(dict(provider_config), stop_event),
        daemon=True,
        name=f"openclaw-channel-push:{listener_id}",
    )
    _PUSH_THREADS[listener_id] = thread
    thread.start()


def stop_bridge_listener() -> None:
    for stop_event in _PUSH_STOPS.values():
        stop_event.set()
    _PUSH_STOPS.clear()
    _PUSH_THREADS.clear()


def _run_bridge_listener_forever(provider_config: dict, stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        try:
            asyncio.run(_bridge_listener_loop(provider_config, stop_event))
        except (asyncio.CancelledError, ConnectionResetError, BrokenPipeError):
            print(f"[OpenClawChannel] push listener disconnected: {provider_config.get('id')}")
        except Exception as exc:
            print(f"[OpenClawChannel] push listener error: {exc}")
        if not stop_event.wait(3.0):
            continue
        break


async def _bridge_listener_loop(provider_config: dict, stop_event: threading.Event) -> None:
    bridge_url = str(provider_config.get("bridgeUrl") or "ws://127.0.0.1:18800").strip()
    sender_id = str(provider_config.get("senderId") or "alicechat-user")
    sender_name = str(provider_config.get("senderName") or "AliceChat User")
    ws = await _open_bridge_connection(
        bridge_url,
        ping_interval=_PUSH_LISTENER_PING_INTERVAL_SECONDS,
        ping_timeout=_PUSH_LISTENER_PING_TIMEOUT_SECONDS,
    )
    print(
        "[OpenClawChannel] push listener connected to "
        f"{bridge_url} (ping_interval={_PUSH_LISTENER_PING_INTERVAL_SECONDS}s, "
        f"ping_timeout={_PUSH_LISTENER_PING_TIMEOUT_SECONDS}s, "
        f"recv_idle={_PUSH_LISTENER_RECV_IDLE_SECONDS}s)"
    )
    try:
        await ws.send(json.dumps({
            "type": "bridge.register",
            "target": sender_id,
            "senderId": sender_id,
            "senderName": sender_name,
            "providerId": str(provider_config.get("id") or "").strip(),
            "ts": time.time(),
        }))
        while not stop_event.is_set():
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=_PUSH_LISTENER_RECV_IDLE_SECONDS)
            except TimeoutError:
                await ws.send(json.dumps({"type": "ping", "ts": time.time()}))
                continue
            frame = json.loads(raw)
            ftype = str(frame.get("type") or "")
            if ftype == "push.message":
                frame["providerId"] = str(provider_config.get("id") or frame.get("providerId") or "openclaw-channel").strip()
                _emit_push_message(frame)
            elif ftype in {"pong", "bridge.registered"}:
                continue
    finally:
        await ws.close()


class OpenClawChannelAgentBackend(AgentBackend):
    async def _run_channel_chat(
        self,
        request: ChatRequest,
        emit: StreamEmitter | None = None,
        timeout_seconds: float = 120.0,
    ) -> dict:
        agent = request.agent or str(self.provider_config.get("agent") or "main")
        session_name = request.session_name or str(self.provider_config.get("session") or "main")
        bridge_url = str(self.provider_config.get("bridgeUrl") or "ws://127.0.0.1:18800").strip()
        sender_id = str(self.provider_config.get("senderId") or "alicechat-user")
        sender_name = str(self.provider_config.get("senderName") or "AliceChat User")
        attachments = _prepare_bridge_attachments(request.attachments)
        request_id = str(uuid.uuid4())
        session_key = str(request.context.get("sessionKey") or "").strip() or f"agent:{agent}:{session_name}"

        ws = await _open_bridge_connection(
            bridge_url,
            ping_interval=_REQUEST_PING_INTERVAL_SECONDS,
            ping_timeout=_REQUEST_PING_TIMEOUT_SECONDS,
        )
        try:
            peer = None
            local = None
            transport = getattr(ws, 'transport', None)
            if transport is not None:
                try:
                    peer = transport.get_extra_info('peername')
                except Exception:
                    peer = None
                try:
                    local = transport.get_extra_info('sockname')
                except Exception:
                    local = None
            debug_msg = (
                f"[OPENCLAW_CHANNEL DEBUG] request.agent={request.agent} final_agent={agent} "
                f"provider_agent={self.provider_config.get('agent')} session={session_name} sessionKey={session_key}"
            )
            print(debug_msg, flush=True)
            _LOG.warning(debug_msg)
            outbound = {
                "type": "chat.request",
                "requestId": request_id,
                "text": request.user_text,
                "attachments": attachments,
                "agent": agent,
                "session": session_name,
                "sessionKey": session_key,
                "senderId": sender_id,
                "senderName": sender_name,
                "conversationLabel": session_name,
            }
            outbound_text = json.dumps(outbound, ensure_ascii=False)
            conn_msg = (
                f"[OPENCLAW_CHANNEL CONN] bridge_url={bridge_url} local={local} peer={peer} "
                f"ping_interval={_REQUEST_PING_INTERVAL_SECONDS}s ping_timeout={_REQUEST_PING_TIMEOUT_SECONDS}s"
            )
            print(conn_msg, flush=True)
            _LOG.warning(conn_msg)
            print(f"[OPENCLAW_CHANNEL OUTBOUND] {outbound_text}", flush=True)
            _LOG.warning("[OPENCLAW_CHANNEL OUTBOUND] %s", outbound_text)
            await ws.send(json.dumps(outbound, ensure_ascii=False))

            accumulated_text = ""
            final_media: list[dict] = []
            saw_relevant_frame = False
            saw_final_frame = False
            last_frame_type = ""

            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=timeout_seconds)
                except TimeoutError as exc:
                    raise RuntimeError(
                        "Timeout waiting for OpenClaw bridge final frame "
                        f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                        f"saw_relevant_frame={saw_relevant_frame})"
                    ) from exc
                print(f"[OPENCLAW_CHANNEL RAW] {raw}", flush=True)
                _LOG.warning("[OPENCLAW_CHANNEL RAW] %s", raw)
                frame = json.loads(raw)
                if frame.get("requestId") not in {None, request_id}:
                    skip_msg = (
                        f"[OPENCLAW_CHANNEL SKIP] requestId={frame.get('requestId')} "
                        f"expected={request_id} type={frame.get('type')}"
                    )
                    print(skip_msg, flush=True)
                    _LOG.warning(skip_msg)
                    continue

                saw_relevant_frame = True
                ftype = str(frame.get("type") or "")
                last_frame_type = ftype
                if ftype == "chat.delta":
                    delta = str(frame.get("delta") or "")
                    accumulated_text = _extract_text_candidates(frame, accumulated_text + delta)
                    if emit and delta:
                        emit({
                            "type": "delta",
                            "delta": delta,
                            "reply": accumulated_text,
                            "state": "streaming",
                        })
                elif ftype == "chat.media":
                    media = frame.get("media") or {}
                    if isinstance(media, dict):
                        final_media.append(media)
                elif ftype == "chat.final":
                    saw_final_frame = True
                    accumulated_text = _extract_text_candidates(frame, accumulated_text)
                    more_media = frame.get("media") or []
                    if isinstance(more_media, list):
                        final_media = more_media
                    break
                elif ftype == "chat.error":
                    raise RuntimeError(str(frame.get("error") or "openclaw channel bridge error"))
                else:
                    accumulated_text = _extract_text_candidates(frame, accumulated_text)
                    if accumulated_text.strip() and ftype in {"message", "assistant", "reply"}:
                        break
                    continue
        except Exception as exc:
            raise RuntimeError(
                "OpenClaw bridge request failed "
                f"(requestId={request_id}, sessionKey={session_key}, cause={exc})"
            ) from exc
        finally:
            await ws.close()

        reply = accumulated_text.strip()
        if not saw_final_frame and not reply and not final_media:
            raise RuntimeError(
                "OpenClaw bridge request ended without final frame or visible content "
                f"(requestId={request_id}, sessionKey={session_key}, last_frame_type={last_frame_type or 'none'})"
            )
        if not reply and not final_media:
            reply = "……我刚刚没有拿到可显示的回复。"
        final_msg = f"[OPENCLAW_CHANNEL FINAL] reply={reply!r} media_count={len(final_media)}"
        print(final_msg, flush=True)
        _LOG.warning(final_msg)
        images = [m for m in final_media if isinstance(m, dict) and m.get("type") == "image" and m.get("url")]
        audio = [m for m in final_media if isinstance(m, dict) and m.get("type") == "audio" and m.get("url")]
        return {
            "reply": reply,
            "images": images,
            "audio": audio,
            "provider": self.provider_config.get("id") or "openclaw-channel",
            "providerLabel": self.provider_config.get("name") or "OpenClaw Channel",
            "model": "channel-bridge",
            "usage": {},
            "agent": agent,
            "session": session_name,
            "sessionKey": session_key,
            "state": "final",
        }

    def send_chat(self, request: ChatRequest) -> dict:
        return asyncio.run(self._run_channel_chat(request))

    def stream_chat(self, request: ChatRequest, emit: StreamEmitter) -> dict:
        return asyncio.run(self._run_channel_chat(request, emit=emit))
