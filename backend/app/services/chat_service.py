from __future__ import annotations

"""Chat service.

This wraps provider selection and persistence side-effects.

During migration we keep message payload format identical to the legacy backend.
"""

from dataclasses import dataclass, replace

from ..agents import ChatRequest, create_agent_backend
from ..config import get_chat_config, get_chat_provider
from ..store import MessageStore, SessionStore


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
            kind = str(item.get("kind") or "").strip().lower()
            att_type = str(item.get("type") or ("url" if item.get("url") else "base64")).strip()
            att_data = str(item.get("data") or item.get("url") or "").strip()
            if not att_data:
                continue
            att_media_type = item.get("mimeType") or item.get("mediaType") or item.get("media_type") or None
            if kind and kind != 'image':
                continue
            # Reuse backend Attachment model.
            from ..agents.base import ChatAttachment

            parsed_attachments.append(ChatAttachment(type=att_type, data=att_data, media_type=att_media_type))

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
            if getattr(att, "type") == "url":
                user_attachments.append({
                    "id": f"att_{__import__('uuid').uuid4().hex[:12]}",
                    "kind": "image",
                    "mimeType": getattr(att, "media_type") or "image/png",
                    "url": getattr(att, "data"),
                    "status": "ready",
                    "meta": {},
                })
            elif getattr(att, "type") == "base64":
                user_attachments.append({
                    "id": f"att_{__import__('uuid').uuid4().hex[:12]}",
                    "kind": "image",
                    "mimeType": getattr(att, "media_type") or "image/png",
                    "data": getattr(att, "data"),
                    "status": "ready",
                    "meta": {},
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

    def persist_assistant_message(
        self,
        *,
        session_id: str,
        reply: str,
        raw_reply: str | None = None,
        images: list[dict] | None = None,
        meta: str = "",
        source: str = "chat",
    ) -> dict:
        """Persist assistant message.

        `reply` is the display text (stage directives already stripped).
        `raw_reply` keeps the original streamed text for debugging / reprocessing.
        """

        from ..utils import strip_stage_directives

        assistant_attachments = []
        for img in images or []:
            if isinstance(img, dict) and img.get("url"):
                assistant_attachments.append({
                    "id": f"att_{__import__('uuid').uuid4().hex[:12]}",
                    "kind": "image",
                    "mimeType": img.get("mimeType") or img.get("mime_type") or "image/png",
                    "url": img.get("url"),
                    "filename": img.get("filename") or "",
                    "name": img.get("filename") or "",
                    "status": "ready",
                    "meta": {},
                })
        msg = self.messages.create_message(
            session_id=session_id,
            role="assistant",
            text=strip_stage_directives(str(reply or "")),
            raw_text=str(raw_reply or ""),
            attachments=assistant_attachments,
            source=str(source or "chat"),
            meta=str(meta or ""),
        )

        return msg

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
