from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import threading
import tempfile
import time
import uuid
import mimetypes
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .base import AgentBackend, ChatAttachment, ChatRequest, StreamEmitter
from ..config import UPLOADS_DIR
from ..utils.frame_audit import audit_frame

_BRIDGE_CONNECT_RETRY_DELAYS = (0.5, 1.0, 2.0, 4.0, 8.0)
_PUSH_LISTENER_PING_INTERVAL_SECONDS = 60
_PUSH_LISTENER_PING_TIMEOUT_SECONDS = 60
_PUSH_LISTENER_RECV_IDLE_SECONDS = 90
_REQUEST_PING_INTERVAL_SECONDS = 60
_REQUEST_PING_TIMEOUT_SECONDS = 60
_EMPTY_FINAL_GRACE_SECONDS = 15.0
_INITIAL_FRAME_TIMEOUT_SECONDS = 240.0
_TYPING_IDLE_TIMEOUT_SECONDS = 600.0
_ACTIVE_FRAME_IDLE_TIMEOUT_SECONDS = 600.0
_MAX_REQUEST_TIMEOUT_SECONDS = 3600.0
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


def _resolve_final_reply(*, frame_reply: str, accumulated_reply: str) -> str:
    final_text = str(frame_reply or "").strip()
    preview_text = str(accumulated_reply or "").strip()
    return final_text or preview_text


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


def _classify_bridge_media(url: str, audio_as_voice: bool = False) -> str:
    value = str(url or "").strip()
    lower = value.lower()
    if audio_as_voice:
        return "audio"
    if lower.startswith("data:image/"):
        return "image"
    if lower.startswith("data:audio/"):
        return "audio"
    if lower.startswith("data:video/"):
        return "video"
    mime_type, _ = mimetypes.guess_type(value.split("?", 1)[0])
    normalized_mime = str(mime_type or "").lower()
    if normalized_mime.startswith("image/"):
        return "image"
    if normalized_mime.startswith("audio/"):
        return "audio"
    if normalized_mime.startswith("video/"):
        return "video"
    return "file"


def _extract_bridge_media_items(payload: dict | None) -> list[dict]:
    if not isinstance(payload, dict):
        return []
    raw_urls = payload.get("mediaUrls")
    urls: list[str] = []
    if isinstance(raw_urls, list):
        urls.extend(str(item).strip() for item in raw_urls if str(item or "").strip())
    elif isinstance(payload.get("mediaUrl"), str) and str(payload.get("mediaUrl") or "").strip():
        urls.append(str(payload.get("mediaUrl") or "").strip())
    audio_as_voice = bool(payload.get("audioAsVoice"))
    return [
        {
            "url": url,
            "type": _classify_bridge_media(url, audio_as_voice),
            "audioAsVoice": audio_as_voice,
        }
        for url in urls
    ]


def _normalize_bridge_agent_event(evt: dict | None) -> dict | None:
    if not isinstance(evt, dict):
        return None
    stream = str(evt.get("stream") or "").strip()
    data = evt.get("data") if isinstance(evt.get("data"), dict) else {}
    phase = str(data.get("phase") or "").strip()
    title = str(data.get("title") or "").strip()
    summary = str(data.get("summary") or "").strip()
    progress_text = str(data.get("progressText") or "").strip()
    meta = str(data.get("meta") or "").strip()
    output = str(data.get("output") or "").strip()
    explanation = str(data.get("explanation") or "").strip()
    name = str(data.get("name") or "").strip()
    kind_hint = str(data.get("kind") or "").strip()
    status = str(data.get("status") or "").strip()
    message = str(data.get("message") or "").strip()
    reason = str(data.get("reason") or "").strip()
    command = str(data.get("command") or "").strip()
    item_id = str(data.get("itemId") or "").strip()
    tool_call_id = str(data.get("toolCallId") or "").strip()
    approval_id = str(data.get("approvalId") or "").strip()
    approval_slug = str(data.get("approvalSlug") or "").strip()
    source = str(data.get("source") or "").strip()
    args = data.get("args")
    steps = [str(item or "").strip() for item in (data.get("steps") or []) if str(item or "").strip()]
    base = {
        "eventStream": stream or "agent",
        "phase": phase,
        "status": status,
        "title": title,
        "itemId": item_id,
        "toolCallId": tool_call_id,
        "toolName": name,
        "approvalId": approval_id,
        "approvalSlug": approval_slug,
        "command": command,
        "output": output,
        "source": source,
    }
    if args is not None:
        base["args"] = args
    if stream == "plan":
        text = " · ".join(part for part in [title, explanation, f"步骤：{'；'.join(steps)}" if steps else "", source] if part)
        return {"stage": "plan", "kind": "plan", "text": text or "计划已更新", **base}
    if stream == "thinking":
        thinking_text = str(data.get("text") or "").strip()
        delta = str(data.get("delta") or "").strip()
        text = " · ".join(part for part in [thinking_text, delta, progress_text, summary, title, meta] if part)
        return {"stage": "thinking", "kind": "thinking", "text": text, **base} if text else None
    if stream == "command_output":
        text = " · ".join(part for part in [title, name, output, status, phase] if part)
        return {"stage": "tool", "kind": "exec", "text": text or "命令执行中", **base}
    if stream in {"tool", "item", "approval", "patch", "compaction"}:
        text = " · ".join(
            part
            for part in [progress_text, summary, title, meta, name, message, reason, command, status, phase, tool_call_id, item_id]
            if part
        )
        return {
            "stage": (phase or "tool") if stream == "item" else stream,
            "kind": kind_hint or _classify_progress_kind(text or f"{stream} {name} {command}", name or stream),
            "text": text or f"{stream}{f' · {name}' if name else ''}{f' · {phase}' if phase else ''}",
            **base,
        }
    return None


def _local_upload_url_to_path(url: str) -> Path | None:
    value = str(url or "").strip()
    if not value.startswith("/uploads/"):
        return None
    relative = value.removeprefix("/uploads/")
    candidate = (UPLOADS_DIR / relative).resolve()
    uploads_root = UPLOADS_DIR.resolve()
    try:
        candidate.relative_to(uploads_root)
    except Exception:
        return None
    return candidate if candidate.is_file() else None


def _bridge_image_suffix(media_type: str | None) -> str:
    normalized = str(media_type or "").strip().lower()
    if normalized in {"image/jpeg", "image/jpg"}:
        return ".jpg"
    if normalized == "image/png":
        return ".png"
    if normalized == "image/webp":
        return ".webp"
    if normalized == "image/gif":
        return ".gif"
    if normalized == "image/bmp":
        return ".bmp"
    if normalized == "image/tiff":
        return ".tiff"
    return ".bin"


def _write_bridge_temp_image(*, encoded: str, media_type: str | None) -> str:
    decoded = base64.b64decode(encoded, validate=True)
    with tempfile.NamedTemporaryFile(
        mode="wb",
        prefix="alicechat-bridge-inbound-",
        suffix=_bridge_image_suffix(media_type),
        delete=False,
    ) as handle:
        handle.write(decoded)
        return os.path.abspath(handle.name)


def _prepare_bridge_attachments(attachments: list[ChatAttachment]) -> list[dict]:
    result: list[dict] = []
    for att in attachments:
        att_kind = str(getattr(att, "kind", "image") or "image").strip().lower() or "image"
        if att_kind != "image":
            payload = {
                "kind": att_kind,
                "mimeType": att.media_type or "application/octet-stream",
            }
            if getattr(att, "name", None):
                payload["name"] = att.name
                payload["filename"] = att.name
            if isinstance(getattr(att, "size", None), int):
                payload["size"] = att.size
            if att.type == "url":
                local_path = _local_upload_url_to_path(att.data)
                if local_path is not None:
                    payload["path"] = str(local_path)
                payload["url"] = att.data
            elif att.type == "path":
                payload["path"] = str(Path(att.data).expanduser().resolve())
                payload["url"] = build_protected_media_url(att.data)
            elif att.type == "base64":
                payload["content"] = _normalize_base64_payload(att.data)
            result.append(payload)
            continue

        if att.type == "url":
            local_path = _local_upload_url_to_path(att.data)
            if local_path is not None:
                encoded = base64.b64encode(local_path.read_bytes()).decode("ascii")
                result.append({
                    "kind": "image",
                    "path": str(local_path),
                    "content": encoded,
                    "mimeType": att.media_type or "image/png",
                })
            else:
                result.append({
                    "kind": "image",
                    "url": att.data,
                    "mimeType": att.media_type or "image/png",
                })
        elif att.type == "path":
            path = Path(att.data).expanduser().resolve()
            encoded = base64.b64encode(path.read_bytes()).decode("ascii")
            result.append({
                "kind": "image",
                "path": str(path),
                "content": encoded,
                "mimeType": att.media_type or "image/png",
            })
        elif att.type == "base64":
            normalized = _normalize_base64_payload(att.data)
            try:
                temp_path = _write_bridge_temp_image(
                    encoded=normalized,
                    media_type=att.media_type or "image/png",
                )
            except Exception as exc:
                preview = normalized[:48]
                raise RuntimeError(f"Invalid base64 image payload: prefix={preview!r}, len={len(normalized)}") from exc
            result.append({
                "kind": "image",
                "path": temp_path,
                "content": normalized,
                "mimeType": att.media_type or "image/png",
            })
    return result


def _prepare_bridge_images(attachments: list[dict]) -> list[dict]:
    result: list[dict] = []
    for item in attachments:
        if not isinstance(item, dict):
            continue
        mime_type = str(item.get("mimeType") or item.get("mediaType") or item.get("media_type") or "image/png").strip() or "image/png"
        if not mime_type.startswith("image/"):
            continue
        content = str(item.get("content") or "").strip()
        if not content:
            continue
        result.append({
            "type": "image",
            "data": content,
            "mimeType": mime_type,
        })
    return result


def _build_bridge_agent_media_payload(attachments: list[dict]) -> dict:
    media_list: list[dict] = []
    for item in attachments:
        if not isinstance(item, dict):
            continue
        mime_type = str(item.get("mimeType") or item.get("mediaType") or item.get("media_type") or "").strip()
        media_ref = str(item.get("path") or item.get("url") or "").strip()
        if not media_ref:
            continue
        media_list.append({
            "path": media_ref,
            "contentType": mime_type or None,
        })
    first = media_list[0] if media_list else None
    media_paths = [media.get("path") for media in media_list if media.get("path")]
    media_types = [media.get("contentType") for media in media_list if media.get("contentType")]
    return {
        "MediaPath": first.get("path") if first else None,
        "MediaType": first.get("contentType") if first else None,
        "MediaUrl": first.get("path") if first else None,
        "MediaPaths": media_paths or None,
        "MediaUrls": media_paths or None,
        "MediaTypes": media_types or None,
    }


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
        timeout_seconds: float = _INITIAL_FRAME_TIMEOUT_SECONDS,
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
        timeout_seconds: float = _INITIAL_FRAME_TIMEOUT_SECONDS,
        *,
        attempt: int = 1,
    ) -> dict:
        agent = request.agent or str(self.provider_config.get("agent") or "main")
        session_name = request.session_name or str(self.provider_config.get("session") or "main")
        bridge_url = str(self.provider_config.get("bridgeUrl") or "ws://127.0.0.1:18800").strip()
        sender_id = str(self.provider_config.get("senderId") or "alicechat-user")
        sender_name = str(self.provider_config.get("senderName") or "AliceChat User")
        attachments = _prepare_bridge_attachments(request.attachments)
        bridge_images = _prepare_bridge_images(attachments)
        bridge_agent_media = _build_bridge_agent_media_payload(attachments)
        request_id = str(uuid.uuid4())
        session_key = str(request.context.get("sessionKey") or "").strip() or f"agent:{agent}:{session_name}"
        instruction_text = "\n\n".join(
            item.strip()
            for item in (request.extra_system_prompts or [])
            if str(item or "").strip()
        ).strip()

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
                "instructionText": instruction_text,
                "attachments": attachments,
                "images": bridge_images,
                "agentMedia": bridge_agent_media,
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
            last_activity_at: float | None = None
            last_progress_signature = ""

            def current_reply() -> str:
                return str(accumulated_reply or "").strip()

            def current_final_reply() -> str:
                return str(final_reply or "").strip()

            def emit_progress(*, text: str = "", stage: str = "working", kind: str = "tool", reply_preview: str = "", **meta) -> None:
                nonlocal last_progress_signature
                if not emit:
                    return
                trimmed_text = str(text or "").strip()
                preview_text = str(reply_preview or "").strip()
                tool_call_id = str(meta.get("toolCallId") or "").strip()
                item_id = str(meta.get("itemId") or "").strip()
                signature = (
                    f"{stage}::{kind}::{trimmed_text}::{preview_text}::{tool_call_id}::{item_id}::"
                    f"{str(meta.get('status') or '')}::{str(meta.get('phase') or '')}"
                )
                has_structured_meta = any(str(value or "").strip() for value in meta.values())
                if not trimmed_text and not preview_text and not has_structured_meta:
                    return
                if signature == last_progress_signature:
                    return
                last_progress_signature = signature
                emit({
                    "type": "progress",
                    "text": trimmed_text,
                    "stage": stage,
                    "kind": kind,
                    "replyPreview": preview_text,
                    "state": "streaming",
                    **{key: value for key, value in meta.items() if value is not None and value != ""},
                })

            def emit_snapshot_delta(snapshot_text: str) -> None:
                nonlocal accumulated_reply
                next_text = str(snapshot_text or "")
                if not next_text:
                    return
                previous = accumulated_reply
                delta_text = next_text[len(previous):] if next_text.startswith(previous) else next_text
                accumulated_reply = next_text
                if emit and delta_text:
                    emit({
                        "type": "delta",
                        "delta": delta_text,
                        "replyPreview": current_reply(),
                        "state": "streaming",
                    })

            while True:
                now = time.monotonic()
                total_elapsed = now - request_started_at
                total_remaining = _MAX_REQUEST_TIMEOUT_SECONDS - total_elapsed
                if total_remaining <= 0:
                    raise RuntimeError(
                        "Timeout waiting for OpenClaw bridge reply_final frame "
                        f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                        f"saw_relevant_frame={saw_relevant_frame}, total_elapsed={total_elapsed:.1f}s, reason=max_request_timeout_exceeded)"
                    )

                recv_timeout = min(timeout_seconds, total_remaining)
                if pending_empty_final_deadline is not None:
                    remaining = pending_empty_final_deadline - now
                    if remaining <= 0:
                        break
                    recv_timeout = max(0.1, min(remaining, total_remaining))
                elif not saw_relevant_frame:
                    recv_timeout = max(0.1, min(timeout_seconds, total_remaining))
                elif last_typing_at is not None and not accumulated_reply and not final_media:
                    typing_remaining = _TYPING_IDLE_TIMEOUT_SECONDS - (now - last_typing_at)
                    recv_timeout = max(0.1, min(max(typing_remaining, 0.1), total_remaining))
                elif last_activity_at is not None:
                    active_remaining = _ACTIVE_FRAME_IDLE_TIMEOUT_SECONDS - (now - last_activity_at)
                    recv_timeout = max(0.1, min(max(active_remaining, 0.1), total_remaining))
                else:
                    recv_timeout = max(0.1, min(timeout_seconds, total_remaining))
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=recv_timeout)
                except TimeoutError as exc:
                    timeout_now = time.monotonic()
                    total_elapsed = timeout_now - request_started_at
                    if pending_empty_final_deadline is not None:
                        break
                    if not saw_relevant_frame:
                        raise RuntimeError(
                            "Timeout waiting for OpenClaw bridge reply_final frame "
                            f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                            f"saw_relevant_frame={saw_relevant_frame}, initial_wait_for={total_elapsed:.1f}s)"
                        ) from exc
                    if last_typing_at is not None and not accumulated_reply and not final_media:
                        idle_for = timeout_now - last_typing_at
                        raise RuntimeError(
                            "Timeout waiting for OpenClaw bridge reply_final frame "
                            f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                            f"saw_relevant_frame={saw_relevant_frame}, typing_idle_for={idle_for:.1f}s, total_elapsed={total_elapsed:.1f}s)"
                        ) from exc
                    if last_activity_at is not None:
                        idle_for = timeout_now - last_activity_at
                        raise RuntimeError(
                            "Timeout waiting for OpenClaw bridge reply_final frame "
                            f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                            f"saw_relevant_frame={saw_relevant_frame}, active_idle_for={idle_for:.1f}s, total_elapsed={total_elapsed:.1f}s)"
                        ) from exc
                    raise RuntimeError(
                        "Timeout waiting for OpenClaw bridge reply_final frame "
                        f"(requestId={request_id}, last_frame_type={last_frame_type or 'none'}, "
                        f"saw_relevant_frame={saw_relevant_frame}, total_elapsed={total_elapsed:.1f}s)"
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
                last_activity_at = time.monotonic()
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
                    now = time.monotonic()
                    if last_typing_at is None:
                        last_typing_at = now
                    else:
                        idle_since_last_typing = now - last_typing_at
                        if idle_since_last_typing <= _TYPING_IDLE_TIMEOUT_SECONDS:
                            last_typing_at = now
                    if emit:
                        emit({
                            "type": "progress",
                            "text": "",
                            "stage": "typing",
                            "kind": "thinking",
                            "replyPreview": current_reply(),
                            "state": "streaming",
                        })
                elif ftype == "chat.reply_start":
                    now = time.monotonic()
                    last_typing_at = now
                    emit_progress(stage="typing", kind="thinking", reply_preview=current_reply())
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
                elif ftype == "chat.raw_partial":
                    partial_text = str(frame.get("text") or "").strip()
                    if partial_text:
                        emit_snapshot_delta(partial_text)
                    if pending_empty_final_deadline is not None and (partial_text or accumulated_reply):
                        pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                    last_typing_at = None
                elif ftype == "chat.raw_reasoning":
                    reasoning_text = str(frame.get("text") or "").strip()
                    if reasoning_text:
                        emit_progress(
                            text=reasoning_text,
                            stage="thinking",
                            kind="thinking",
                            reply_preview=current_reply(),
                        )
                    last_typing_at = None
                elif ftype == "chat.raw_agent_event":
                    normalized = _normalize_bridge_agent_event(frame.get("event") if isinstance(frame.get("event"), dict) else None)
                    if normalized is not None:
                        emit_progress(reply_preview=current_reply(), **normalized)
                    last_typing_at = None
                elif ftype == "chat.raw_deliver":
                    payload_kind = str(frame.get("payloadKind") or "block").strip() or "block"
                    payload = frame.get("payload") if isinstance(frame.get("payload"), dict) else {}
                    payload_text = str(payload.get("text") or payload.get("body") or "").strip()
                    media_items = _extract_bridge_media_items(payload)
                    media_added = False
                    for item in media_items:
                        final_media.append(item)
                        media_added = True
                    if payload_kind == "tool":
                        emit_progress(
                            text=payload_text,
                            stage="tool",
                            kind=_classify_progress_kind(payload_text),
                            reply_preview=current_reply(),
                        )
                    elif payload_kind == "block":
                        if payload_text:
                            accumulated_reply = f"{accumulated_reply}{payload_text}"
                            if emit:
                                emit({
                                    "type": "delta",
                                    "delta": payload_text,
                                    "replyPreview": current_reply(),
                                    "state": "streaming",
                                })
                    elif payload_kind == "final":
                        if payload_text:
                            emit_snapshot_delta(payload_text)
                            final_reply = current_reply()
                        elif media_added and not final_reply:
                            final_reply = current_reply()
                    elif payload_text:
                        emit_progress(
                            text=payload_text,
                            stage=payload_kind,
                            kind=_classify_progress_kind(payload_text, payload_kind),
                            reply_preview=current_reply(),
                        )
                    if pending_empty_final_deadline is not None and (payload_text or accumulated_reply or media_added or final_media):
                        pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                    last_typing_at = None
                elif ftype == "chat.media":
                    media = frame.get("media") or {}
                    last_typing_at = None
                    if isinstance(media, dict):
                        final_media.append(media)
                        if pending_empty_final_deadline is not None:
                            pending_empty_final_deadline = time.monotonic() + _EMPTY_FINAL_GRACE_SECONDS
                elif ftype in {"chat.reply_final", "chat.final"}:
                    final_reply_text = _resolve_final_reply(
                        frame_reply=_extract_final_reply(frame),
                        accumulated_reply=accumulated_reply,
                    )
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
                        if final_reply or accumulated_reply or final_media:
                            final_reply = current_reply()
                            saw_reply_final_frame = True
                            _LOG.warning(
                                "[OPENCLAW_CHANNEL RECOVERED_FINAL] requestId=%s sessionKey=%s reply_len=%s media_count=%s",
                                request_id,
                                session_key,
                                len(final_reply),
                                len(final_media),
                            )
                            break
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
        media = [m for m in final_media if isinstance(m, dict) and m.get("url")]
        images = [m for m in media if m.get("type") == "image"]
        audio = [m for m in media if m.get("type") == "audio"]
        return {
            "reply": reply,
            "rawReply": reply,
            "media": media,
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
