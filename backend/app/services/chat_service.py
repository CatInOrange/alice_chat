from __future__ import annotations

"""Chat service.

This wraps provider selection and persistence side-effects.

During migration we keep message payload format identical to the legacy backend.
"""

from dataclasses import dataclass, replace
import json
import logging
import mimetypes
import re
import uuid

from ..agents import ChatRequest, create_agent_backend
from ..config import get_chat_config, get_chat_provider
from ..store import MessageStore, SessionStore
from ..media_utils import normalize_attachment_url


_LOG = logging.getLogger(__name__)
_LEADING_BRACKET_PREFIX_RE = re.compile(r'^\s*(?:\[[^\]\r\n]{1,80}\]\s*)+')
_RECOVERY_MESSAGE_PREFIX_RE = re.compile(r'^\s*\[恢复消息\]\s*', re.IGNORECASE)
_IMPORTED_ASSISTANT_SOURCES = {'recovery', 'transcript_backfill', 'transcript_reconcile'}


@dataclass(slots=True)
class ChatResolvedRequest:
    model_config: dict
    provider: dict
    text: str
    history_text: str
    agent: str
    session_name: str
    attachments: list
    assistant_meta: str
    message_source: str
    extra_system_prompts: list[str]
    session_key: str = ''
    contact_id: str = ''
    user_id: str = ''
    client_message_id: str = ''


class ChatService:
    def __init__(self, *, sessions: SessionStore | None = None, messages: MessageStore | None = None):
        self.sessions = sessions or SessionStore()
        self.messages = messages or MessageStore()

    def resolve_request(self, body: dict) -> ChatResolvedRequest:
        text = str(body.get("text", "")).strip()
        history_text = str(body.get("historyText", body.get("displayText", text)) or "").strip()
        assistant_meta = str(body.get("assistantMeta") or "").strip()
        message_source = str(body.get("messageSource") or body.get("source") or "chat").strip() or "chat"
        model_id = str(body.get("modelId") or "alicechat-default").strip() or "alicechat-default"
        model_config = {"id": model_id, "name": model_id, "chatDefaults": {}}
        provider_id = str(body.get("providerId") or get_chat_config().get("defaultProviderId") or "")
        provider = get_chat_provider(provider_id)
        defaults = (model_config.get("chatDefaults") or {}).get(provider_id) or {}
        agent = str(body.get("agent", defaults.get("agent") or provider.get("agent") or "")).strip()
        session_name = str(body.get("session", defaults.get("session") or provider.get("session") or "")).strip()
        # Provider overrides. Secrets stay server-side and are not accepted from the browser.
        # TODO: 这里要解耦，改为调用provider的接口来解析
        overrides = dict(provider)

        attachments = body.get("attachments") or []
        parsed_attachments = []
        for item in attachments:
            if not isinstance(item, dict):
                continue
            kind = str(item.get("kind") or item.get("type") or "file").strip().lower() or "file"
            att_type = str(item.get("type") or ("url" if item.get("url") else "base64")).strip()
            att_data = str(item.get("data") or item.get("url") or "").strip()
            if not att_data:
                continue
            att_media_type = item.get("mimeType") or item.get("mediaType") or item.get("media_type") or None
            att_name = str(item.get("name") or item.get("filename") or "").strip() or None
            att_size_raw = item.get("size")
            att_size = att_size_raw if isinstance(att_size_raw, int) else None
            # Reuse backend Attachment model.
            from ..agents.base import ChatAttachment

            parsed_attachments.append(
                ChatAttachment(
                    type=att_type,
                    data=att_data,
                    media_type=att_media_type,
                    kind=kind,
                    name=att_name,
                    size=att_size,
                )
            )

        return ChatResolvedRequest(
            model_config=model_config,
            provider=overrides,
            text=text,
            history_text=history_text,
            agent=agent,
            session_name=session_name,
            attachments=parsed_attachments,
            assistant_meta=assistant_meta,
            message_source=message_source,
            extra_system_prompts=[],
            session_key=str(body.get('sessionKey') or '').strip(),
            contact_id=str(body.get('contactId') or '').strip(),
            user_id=str(body.get('userId') or '').strip(),
            client_message_id=str(body.get('clientMessageId') or '').strip(),
        )

    def persist_user_message(
        self,
        *,
        session_id: str,
        history_text: str,
        attachments: list,
        source: str = "chat",
        message_id: str | None = None,
        meta: str = "",
    ) -> dict | None:
        # The legacy server strips stage directives from persisted history.
        from ..utils import strip_stage_directives

        user_attachments = []
        for att in attachments:
            att_kind = str(getattr(att, "kind", "file") or "file").strip() or "file"
            att_name = getattr(att, "name", None)
            att_size = getattr(att, "size", None)
            base_payload = {
                "id": f"att_{__import__('uuid').uuid4().hex[:12]}",
                "kind": att_kind,
                "mimeType": getattr(att, "media_type") or ("image/png" if att_kind == "image" else "application/octet-stream"),
                "status": "ready",
                "meta": {},
            }
            if att_name:
                base_payload["name"] = att_name
                base_payload["filename"] = att_name
            if isinstance(att_size, int) and att_size >= 0:
                base_payload["size"] = att_size
            if getattr(att, "type") == "url":
                user_attachments.append({
                    **base_payload,
                    "url": getattr(att, "data"),
                })
            elif getattr(att, "type") == "base64":
                user_attachments.append({
                    **base_payload,
                    "data": getattr(att, "data"),
                })
            elif getattr(att, "type") == "path":
                user_attachments.append({
                    **base_payload,
                    "url": normalize_attachment_url(getattr(att, "data")),
                })

        if not history_text and not user_attachments:
            return None

        return self.messages.create_message(
            session_id=session_id,
            role="user",
            text=strip_stage_directives(history_text),
            attachments=user_attachments,
            source=str(source or "chat"),
            meta=str(meta or ""),
            message_id=message_id,
        )

    def update_message_content(
        self,
        *,
        message_id: str,
        text: str | None = None,
        raw_text: str | None = None,
        meta: str | dict | None = None,
    ) -> dict | None:
        meta_value = meta
        if isinstance(meta, dict):
            meta_value = json.dumps(meta, ensure_ascii=False)
        return self.messages.update_message_content(
            message_id,
            text=text,
            raw_text=raw_text,
            meta=meta_value,
        )

    def persist_assistant_message(
        self,
        *,
        session_id: str,
        reply: str,
        raw_reply: str | None = None,
        images: list[dict] | None = None,
        media: list[dict] | None = None,
        meta: str = "",
        source: str = "chat",
        dedupe_after_created_at: float | None = None,
    ) -> list[dict]:
        """Persist assistant output.

        Media and text are stored as separate assistant messages. Media messages
        stay attachment-only. Text, when present, is persisted as its own
        assistant text message.
        """

        from ..utils import strip_stage_directives

        visible_text = strip_stage_directives(str(reply or "")).strip()
        assistant_attachments = []
        media_items = media if media is not None else images
        for item in media_items or []:
            if isinstance(item, dict) and item.get("url"):
                raw_url = str(item.get("url") or "").strip()
                stored_url = normalize_attachment_url(raw_url)
                kind = str(item.get("kind") or item.get("type") or "").strip().lower()
                guessed_mime_type, _ = mimetypes.guess_type(raw_url.split("?", 1)[0])
                mime_type = str(item.get("mimeType") or item.get("mime_type") or guessed_mime_type or "").strip()
                if not kind:
                    if mime_type.startswith("image/"):
                        kind = "image"
                    elif mime_type.startswith("audio/"):
                        kind = "audio"
                    elif mime_type.startswith("video/"):
                        kind = "video"
                    else:
                        kind = "file"
                if kind == "document":
                    kind = "file"
                if not mime_type:
                    mime_type = {
                        "image": "image/png",
                        "audio": "audio/mpeg",
                        "video": "video/mp4",
                    }.get(kind, "application/octet-stream")
                filename = str(item.get("name") or item.get("filename") or "").strip()
                size = item.get("size")
                assistant_attachments.append({
                    "id": f"att_{uuid.uuid4().hex[:12]}",
                    "kind": kind if kind in {"image", "audio", "video", "file"} else "file",
                    "mimeType": mime_type,
                    "url": stored_url,
                    "filename": filename,
                    "name": filename,
                    **({"size": size} if isinstance(size, int) and size >= 0 else {}),
                    "status": "ready",
                    "meta": {
                        "rawUrl": raw_url,
                    },
                })

        persisted: list[dict] = []

        if assistant_attachments:
            persisted.append(
                self.messages.create_message(
                    session_id=session_id,
                    role="assistant",
                    text="",
                    raw_text=str(raw_reply or ""),
                    attachments=assistant_attachments,
                    source=str(source or "chat"),
                    meta=str(meta or ""),
                )
            )

        if visible_text:
            imported_match = self._find_imported_equivalent_assistant(
                session_id=session_id,
                text=visible_text,
                after_created_at=dedupe_after_created_at,
            )
            if imported_match is not None:
                updated_meta = self._merge_reused_import_meta(
                    existing_meta=imported_match.get("meta"),
                    meta=meta,
                    source=source,
                )
                updated = self.update_message_content(
                    message_id=str(imported_match.get("id") or ""),
                    text=visible_text,
                    raw_text=str(raw_reply or ""),
                    meta=updated_meta,
                )
                persisted.append(updated or imported_match)
                return persisted

            persisted.append(
                self.messages.create_message(
                    session_id=session_id,
                    role="assistant",
                    text=visible_text,
                    raw_text=str(raw_reply or ""),
                    attachments=[],
                    source=str(source or "chat"),
                    meta=str(meta or ""),
                )
            )

        if persisted:
            return persisted

        _LOG.warning(
            "[alicechat.chat_service] skip empty assistant message session_id=%s source=%s raw_reply_len=%s visible_text_len=%s image_count=%s",
            session_id,
            str(source or "chat"),
            len(str(raw_reply or "")),
            len(visible_text),
            len(assistant_attachments),
        )
        return []

    def _normalize_compare_text(self, text: str) -> str:
        value = str(text or "").strip()
        value = _RECOVERY_MESSAGE_PREFIX_RE.sub("", value, count=1)
        value = _LEADING_BRACKET_PREFIX_RE.sub("", value.strip(), count=1)
        return re.sub(r"\s+", " ", value.strip())

    def _find_imported_equivalent_assistant(
        self,
        *,
        session_id: str,
        text: str,
        after_created_at: float | None,
    ) -> dict | None:
        target = self._normalize_compare_text(text)
        if not target:
            return None
        after = float(after_created_at or 0)
        if after <= 0:
            return None
        candidates = [
            item
            for item in self.messages.list_session_messages(session_id, limit=5000)
            if str(item.get("role") or "") == "assistant"
            and str(item.get("source") or "") in _IMPORTED_ASSISTANT_SOURCES
            and float(item.get("createdAt") or 0) >= after
        ]
        for item in reversed(candidates):
            if self._normalize_compare_text(str(item.get("text") or "")) == target:
                return item
        return None

    def _merge_reused_import_meta(
        self,
        *,
        existing_meta: object,
        meta: str,
        source: str,
    ) -> dict:
        def _parse(value: object) -> dict:
            if isinstance(value, dict):
                return dict(value)
            if not value:
                return {}
            try:
                parsed = json.loads(str(value))
            except json.JSONDecodeError:
                return {}
            return dict(parsed) if isinstance(parsed, dict) else {}

        merged = _parse(existing_meta)
        chat_meta = _parse(meta)
        if chat_meta:
            merged.update(chat_meta)
        merged["reusedImportedAssistant"] = True
        merged["finalSource"] = str(source or "chat")
        return merged

    def _build_prior_messages(self, session_id: str, *, limit: int = 12) -> list[dict]:
        history = self.messages.list_session_messages(session_id, limit=2000)
        items: list[dict] = []
        for message in history[-max(1, int(limit or 12)):]:
            role = str(message.get("role") or "").strip()
            if role not in {"user", "assistant"}:
                continue
            text = str(message.get("text") or "").strip()
            if not text:
                continue
            items.append({"role": role, "content": text})
        return items

    def run_chat_stream(self, resolved: ChatResolvedRequest, emit_delta, *, session_id: str = "", route_key: str = "") -> dict:
        session_key = resolved.session_key or (f"agent:{resolved.agent}:{resolved.session_name}" if resolved.agent and resolved.session_name else "")
        backend = create_agent_backend(resolved.provider)
        return backend.stream_chat(
            ChatRequest(
                user_text=resolved.text,
                agent=resolved.agent,
                session_name=resolved.session_name,
                model_config=resolved.model_config,
                attachments=resolved.attachments,
                prior_messages=self._build_prior_messages(session_id) if session_id else [],
                extra_system_prompts=resolved.extra_system_prompts,
                context={
                    "sessionId": session_id,
                    "routeKey": route_key,
                    "runId": session_key or route_key,
                    "sessionKey": session_key,
                    "contactId": resolved.contact_id,
                    "userId": resolved.user_id,
                },
            ),
            emit=emit_delta,
        )
