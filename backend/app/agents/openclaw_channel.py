from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass

from .base import AgentBackend, ChatAttachment, ChatRequest, StreamEmitter
from ..utils.frame_audit import audit_frame

_BRIDGE_CONNECT_RETRY_DELAYS = (0.5, 1.0, 2.0, 4.0, 8.0)
_PUSH_LISTENER_PING_INTERVAL_SECONDS = 60
_PUSH_LISTENER_PING_TIMEOUT_SECONDS = 60
_PUSH_LISTENER_RECV_IDLE_SECONDS = 90
_REQUEST_PING_INTERVAL_SECONDS = 60
_REQUEST_PING_TIMEOUT_SECONDS = 60
_EMPTY_FINAL_GRACE_SECONDS = 8.0
_TYPING_IDLE_TIMEOUT_SECONDS = 90.0
_MAX_TYPING_ONLY_WINDOW_SECONDS = 600.0
_LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class _BridgeRetryDecision:
    should_retry: bool
    reason: str = ""
    max_attempts: int = 1


class _BridgeRequestError(RuntimeError):
    def __init__(self, message: str, *, code: str, retry_decision: _BridgeRetryDecision | None = None):
        super().__init__(message)
        self.code = code
        self.retry_decision = retry_decision or _BridgeRetryDecision(False)


_RETRY_ON_COMPLETED_WITHOUT_REPLY_FINAL = _BridgeRetryDecision(
    should_retry=True,
    reason="completed_without_reply_final",
    max_attempts=2,
)

_RETRY_ON_CONNECT_HANDSHAKE_TIMEOUT = _BridgeRetryDecision(
    should_retry=True,
    reason="connect_handshake_timeout",
    max_attempts=2,
)


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


def _extract_final_reply(frame: dict) -> str:
    candidate = frame.get("reply")
    return candidate.strip() if isinstance(candidate, str) else ""


def _is_command_like_text(text: str) -> bool:
    value = str(text or "").strip()
    return value.startswith("/") if value else False


def _synthetic_command_ack(text: str) -> str:
    command = str(text or "").strip().splitlines()[0].strip()
    if not command:
        return "命令已收到 🙂"
    return f"命令已收到 🙂\n{command}"


def _is_retryable_bridge_connect_error(exc: BaseException) -> bool:
    if isinstance(exc, (TimeoutError, ConnectionRefusedError)):
        return True
    if isinstance(exc, OSError):
        if exc.errno in {61, 111, 10061}:
            return True
        message = str(exc).lower()
        return (
            "connect call failed" in message
            or "cannot connect" in message
            or "connection refused" in message
            or "timed out during opening handshake" in message
        )
    message = str(exc).lower()
    return "timed out during opening handshake" in message


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
            retryable = _is_retryable_bridge_connect_error(exc)
            if not retryable or attempt_index >= attempts - 1:
                if retryable:
                    raise RuntimeError(f"Unable to connect to OpenClaw bridge at {bridge_url} after {attempts} attempts: {exc}") from exc
                raise
            last_exc = exc
            delay = _BRIDGE_CONNECT_RETRY_DELAYS[attempt_index]
            _LOG.warning(
                "[OPENCLAW_CHANNEL CONNECT_RETRY] bridge_url=%s attempt=%s/%s delay=%.2fs error=%s",
                bridge_url,
                attempt_index + 1,
                attempts,
                delay,
                exc,
            )
            await asyncio.sleep(delay)
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


def _classify_progress_kind(text: str, hint: str = "") -> str:
    haystack = f"{hint} {text}".strip().lower()
    if not haystack:
        return "tool"

    if any(marker in haystack for marker in (
        "web_search", "web search", "web_fetch", "web fetch", "search", "搜索", "查一下", "查一查", "lookup", "google", "bing",
    )):
        return "search"
    if any(marker in haystack for marker in (
        "read(", " read ", "cat ", "sed ", "tail ", "head ", "grep ", "查看文件", "读取", "读一下", "翻文件", "inspect", "open file",
    )):
        return "read"
    if any(marker in haystack for marker in (
        "exec(", " exec ", "bash", "shell", "command", "命令", "运行", "python3", "git ", "npm ", "pnpm ", "flutter ", "pytest", "make ",
    )):
        return "exec"
    if any(marker in haystack for marker in (
        "think", "reason", "推理", "思考", "思路",
    )):
        return "thinking"
    if any(marker in haystack for marker in (
        "plan", "步骤", "计划", "方案",
    )):
        return "plan"
    return "tool"


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
        register_frame = {
            "type": "bridge.register",
            "target": sender_id,
            "senderId": sender_id,
            "senderName": sender_name,
            "providerId": str(provider_config.get("id") or "").strip(),
            "ts": time.time(),
        }
        audit_frame(
            "gateway_backend_ws",
            "backend->gateway",
            register_frame,
            phase="push_listener_register",
            providerId=str(provider_config.get("id") or "").strip(),
            bridgeUrl=bridge_url,
        )
        await ws.send(json.dumps(register_frame))
        while not stop_event.is_set():
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=_PUSH_LISTENER_RECV_IDLE_SECONDS)
            except TimeoutError:
                await ws.send(json.dumps({"type": "ping", "ts": time.time()}))
                continue
            frame = json.loads(raw)
            audit_frame(
                "gateway_backend_ws",
                "gateway->backend",
                frame,
                phase="push_listener_recv",
                providerId=str(provider_config.get("id") or frame.get("providerId") or "openclaw-channel").strip(),
                bridgeUrl=bridge_url,
            )
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
        session_key_hint = str(request.context.get("sessionKey") or "").strip() or "unknown"
        max_attempts = _RETRY_ON_COMPLETED_WITHOUT_REPLY_FINAL.max_attempts
        last_error: BaseException | None = None
        for attempt in range(1, max_attempts + 1):
            try:
                return await self._run_channel_chat_once(
                    request,
                    emit=emit,
                    timeout_seconds=timeout_seconds,
                    attempt=attempt,
                )
            except _BridgeRequestError as exc:
                last_error = exc
                decision = exc.retry_decision
                if not decision.should_retry or attempt >= decision.max_attempts:
                    raise RuntimeError(
                        "OpenClaw bridge request failed "
                        f"(sessionKey={session_key_hint}, cause={exc})"
                    ) from exc
                _LOG.warning(
                    "[OPENCLAW_CHANNEL RETRY] reason=%s attempt=%s/%s sessionKey=%s user_text=%r",
                    decision.reason or exc.code,
                    attempt,
                    decision.max_attempts,
                    session_key_hint,
                    request.user_text[:120],
                )
                continue
            except Exception as exc:
                last_error = exc
                raise RuntimeError(
                    "OpenClaw bridge request failed "
                    f"(sessionKey={session_key_hint}, cause={exc})"
                ) from exc
        if last_error is not None:
            raise RuntimeError(str(last_error)) from last_error
        raise RuntimeError("OpenClaw bridge request failed (cause=unknown)")

    async def _run_channel_chat_once(
        self,
        request: ChatRequest,
        emit: StreamEmitter | None = None,
        timeout_seconds: float = 120.0,
        *,
        attempt: int = 1,
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
                f"provider_agent={self.provider_config.get('agent')} session={session_name} sessionKey={session_key} attempt={attempt}"
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
            audit_frame(
                "gateway_backend_ws",
                "backend->gateway",
                outbound,
                phase="chat_request_send",
                providerId=str(self.provider_config.get("id") or "openclaw-channel"),
                bridgeUrl=bridge_url,
                requestId=request_id,
                sessionKey=session_key,
                agent=agent,
                session=session_name,
            )
            await ws.send(json.dumps(outbound, ensure_ascii=False))

            accumulated_reply = ""
            final_reply = ""
            final_media: list[dict] = []
            saw_relevant_frame = False
            saw_reply_final_frame = False
            saw_run_final_frame = False
            saw_empty_final_frame = False
            pending_empty_final_deadline: float | None = None
            last_frame_type = ""
            last_seq = 0
            request_started_at = time.monotonic()
            last_typing_at: float | None = None

            def current_reply() -> str:
                return str(accumulated_reply or "").strip()

            def current_final_reply() -> str:
                return str(final_reply or "").strip()

            while True:
                recv_timeout = timeout_seconds
                if pending_empty_final_deadline is not None:
                    remaining = pending_empty_final_deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    recv_timeout = max(0.1, min(timeout_seconds, remaining))
                elif last_typing_at is not None and not accumulated_reply and not final_media:
                    typing_remaining = _TYPING_IDLE_TIMEOUT_SECONDS - (time.monotonic() - last_typing_at)
                    total_remaining = _MAX_TYPING_ONLY_WINDOW_SECONDS - (time.monotonic() - request_started_at)
                    if total_remaining <= 0:
                        raise RuntimeError(
                            "Timeout waiting for OpenClaw bridge reply_final frame "
                            f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                            f"saw_relevant_frame={saw_relevant_frame}, reason=max_typing_window_exceeded)"
                        )
                    recv_timeout = max(0.1, min(timeout_seconds, _TYPING_IDLE_TIMEOUT_SECONDS, max(typing_remaining, 0.1), total_remaining))
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=recv_timeout)
                except TimeoutError as exc:
                    if pending_empty_final_deadline is not None:
                        break
                    if last_typing_at is not None and not accumulated_reply and not final_media:
                        idle_for = time.monotonic() - last_typing_at
                        total_elapsed = time.monotonic() - request_started_at
                        raise RuntimeError(
                            "Timeout waiting for OpenClaw bridge reply_final frame "
                            f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                            f"saw_relevant_frame={saw_relevant_frame}, typing_idle_for={idle_for:.1f}s, total_elapsed={total_elapsed:.1f}s)"
                        ) from exc
                    raise RuntimeError(
                        "Timeout waiting for OpenClaw bridge reply_final frame "
                        f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                        f"saw_relevant_frame={saw_relevant_frame})"
                    ) from exc
                print(f"[OPENCLAW_CHANNEL RAW] {raw}", flush=True)
                _LOG.warning("[OPENCLAW_CHANNEL RAW] %s", raw)
                frame = json.loads(raw)
                audit_frame(
                    "gateway_backend_ws",
                    "gateway->backend",
                    frame,
                    phase="chat_request_recv",
                    providerId=str(self.provider_config.get("id") or frame.get("providerId") or "openclaw-channel"),
                    bridgeUrl=bridge_url,
                    requestId=request_id,
                    sessionKey=session_key,
                    agent=agent,
                    session=session_name,
                )
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
                seq = frame.get("seq")
                if isinstance(seq, int):
                    if seq <= last_seq:
                        _LOG.warning("[OPENCLAW_CHANNEL ORDER] non-increasing seq=%s last_seq=%s type=%s", seq, last_seq, ftype)
                    last_seq = seq
                if ftype == "chat.delta":
                    delta_text = str(frame.get("delta") or "")
                    if delta_text:
                        accumulated_reply = f"{accumulated_reply}{delta_text}"
                    if pending_empty_final_deadline is not None and (delta_text or accumulated_reply):
                        pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                    last_typing_at = None
                    if emit and delta_text:
                        emit({
                            "type": "delta",
                            "delta": delta_text,
                            "replyPreview": current_reply(),
                            "state": "streaming",
                        })
                elif ftype == "chat.block":
                    block_text = str(frame.get("text") or "").strip()
                    if block_text:
                        accumulated_reply = f"{accumulated_reply}\n{block_text}".strip() if accumulated_reply else block_text
                    if pending_empty_final_deadline is not None and (block_text or accumulated_reply):
                        pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                    last_typing_at = None
                    if emit and block_text:
                        emit({
                            "type": "delta",
                            "delta": block_text,
                            "replyPreview": current_reply(),
                            "state": "streaming",
                        })
                elif ftype == "chat.typing":
                    last_typing_at = time.monotonic()
                    if emit:
                        emit({
                            "type": "progress",
                            "text": "",
                            "stage": "typing",
                            "kind": "thinking",
                            "replyPreview": current_reply(),
                            "state": "streaming",
                        })
                elif ftype == "chat.progress":
                    progress_text = str(frame.get("text") or "").strip()
                    progress_stage = str(frame.get("stage") or "working")
                    progress_hint = str(frame.get("kind") or progress_stage)
                    progress_kind = _classify_progress_kind(progress_text, progress_hint)
                    progress_reply_preview = str(frame.get("replyPreview") or "").strip()
                    progress_meta = {
                        "eventStream": str(frame.get("eventStream") or "").strip(),
                        "toolCallId": str(frame.get("toolCallId") or "").strip(),
                        "toolName": str(frame.get("toolName") or "").strip(),
                        "phase": str(frame.get("phase") or "").strip(),
                        "status": str(frame.get("status") or "").strip(),
                        "itemId": str(frame.get("itemId") or "").strip(),
                        "approvalId": str(frame.get("approvalId") or "").strip(),
                        "approvalSlug": str(frame.get("approvalSlug") or "").strip(),
                        "command": str(frame.get("command") or "").strip(),
                        "output": str(frame.get("output") or "").strip(),
                        "title": str(frame.get("title") or "").strip(),
                        "source": str(frame.get("source") or "").strip(),
                    }
                    has_structured_meta = any(progress_meta.values())
                    last_typing_at = None
                    if emit and (progress_text or progress_reply_preview or has_structured_meta):
                        emit({
                            "type": "progress",
                            "text": progress_text,
                            "stage": progress_stage,
                            "kind": progress_kind,
                            "replyPreview": progress_reply_preview,
                            "state": "streaming",
                            **{key: value for key, value in progress_meta.items() if value},
                        })
                elif ftype == "chat.media":
                    media = frame.get("media") or {}
                    last_typing_at = None
                    if isinstance(media, dict):
                        final_media.append(media)
                        if pending_empty_final_deadline is not None:
                            pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                elif ftype in {"chat.reply_final", "chat.final"}:
                    final_reply_text = _extract_final_reply(frame)
                    media = frame.get("media") or []
                    media_added = False
                    if isinstance(media, list):
                        for item in media:
                            if isinstance(item, dict):
                                final_media.append(item)
                                media_added = True
                    last_typing_at = None
                    if final_reply_text:
                        final_reply = final_reply_text
                        accumulated_reply = final_reply_text
                        saw_reply_final_frame = True
                        break
                    if media_added or final_media:
                        saw_reply_final_frame = True
                        break
                    saw_empty_final_frame = True
                    pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                    continue
                elif ftype == "chat.run_final":
                    saw_run_final_frame = True
                    last_typing_at = None
                    run_state = str(frame.get("runState") or "").strip().lower()
                    had_reply_final = bool(frame.get("hadReplyFinal"))
                    if run_state == "completed" and not had_reply_final and not saw_reply_final_frame:
                        if _is_command_like_text(request.user_text):
                            final_reply = _synthetic_command_ack(request.user_text)
                            accumulated_reply = final_reply
                            saw_reply_final_frame = True
                            _LOG.warning(
                                "[OPENCLAW_CHANNEL SYNTHETIC_FINAL] requestId=%s sessionKey=%s command=%r",
                                request_id,
                                session_key,
                                str(request.user_text or "").strip(),
                            )
                            break
                        raise _BridgeRequestError(
                            "Invalid bridge completion: received chat.run_final(completed) without chat.reply_final "
                            f"(requestId={request_id}, attempt={attempt}, last_frame_type={last_frame_type or 'none'})",
                            code="completed_without_reply_final",
                            retry_decision=_RETRY_ON_COMPLETED_WITHOUT_REPLY_FINAL,
                        )
                    if not accumulated_reply and not final_media and run_state in {"failed", "aborted", "timeout", "incomplete"}:
                        raise RuntimeError(str(frame.get("reason") or frame.get("runState") or "openclaw channel run failed"))
                    continue
                elif ftype == "chat.error":
                    if saw_reply_final_frame:
                        _LOG.warning("[OPENCLAW_CHANNEL] tail error after reply_final requestId=%s error=%s", request_id, str(frame.get("error") or ""))
                        continue
                    raise RuntimeError(str(frame.get("error") or "openclaw channel bridge error"))
                else:
                    fallback_text = _extract_text_candidates(frame, "").strip()
                    if fallback_text and ftype in {"message", "assistant", "reply"}:
                        accumulated_reply = fallback_text
                        break
                    continue
        except _BridgeRequestError:
            raise
        except Exception as exc:
            raise RuntimeError(
                "OpenClaw bridge request failed "
                f"(requestId={request_id}, sessionKey={session_key}, attempt={attempt}, cause={exc})"
            ) from exc
        finally:
            await ws.close()

        reply = current_final_reply()
        if not saw_reply_final_frame and not saw_empty_final_frame:
            raise RuntimeError(
                "OpenClaw bridge request ended without reply_final frame "
                f"(requestId={request_id}, sessionKey={session_key}, last_frame_type={last_frame_type or 'none'}, "
                f"saw_run_final_frame={saw_run_final_frame}, preview_reply={current_reply()[:120]!r})"
            )
        if not reply and not final_media:
            reply = "……我刚刚没有拿到可显示的回复。"
        final_msg = (
            f"[OPENCLAW_CHANNEL FINAL] reply={reply!r} preview={current_reply()!r} "
            f"media_count={len(final_media)} saw_reply_final_frame={saw_reply_final_frame}"
        )
        print(final_msg, flush=True)
        _LOG.warning(final_msg)
        images = [m for m in final_media if isinstance(m, dict) and m.get("type") == "image" and m.get("url")]
        audio = [m for m in final_media if isinstance(m, dict) and m.get("type") == "audio" and m.get("url")]
        return {
            "reply": reply,
            "rawReply": reply,
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
            "replyFinalReceived": saw_reply_final_frame,
            "runFinalReceived": saw_run_final_frame,
        }

    def send_chat(self, request: ChatRequest) -> dict:
        return asyncio.run(self._run_channel_chat(request))

    def stream_chat(self, request: ChatRequest, emit: StreamEmitter) -> dict:
        return asyncio.run(self._run_channel_chat(request, emit=emit))
