from __future__ import annotations

import asyncio
import json
import logging
import re
import uuid
from dataclasses import replace

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from ..config import load_config
from ..services.chat_streaming import ChatStreamingService
from ..services.routing import resolve_routing
from ..utils.suspicious_reply import (
    build_suspicious_meta as _build_suspicious_meta,
    detect_suspicious_final as _detect_suspicious_final,
    mark_recovery_meta as _mark_recovery_meta,
    select_preview_recovery_text as _select_preview_recovery_text,
    strip_model_prefix as _strip_model_prefix,
)
from ..web.helpers import build_route_key, require_existing_session

_LOG = logging.getLogger(__name__)




def _normalize_notification_preview(text: str, *, max_length: int = 100) -> str:
    value = _strip_model_prefix(str(text or '').strip())
    if not value:
        return ''

    value = re.sub(r'```.+?```', ' [代码片段] ', value, flags=re.S)
    value = re.sub(r'`([^`]+)`', r'\1', value)
    value = re.sub(r'!\[([^\]]*)\]\([^\)]+\)', lambda m: (m.group(1) or '[图片]').strip(), value)
    value = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', value)
    value = re.sub(r'https?://\S+', '链接', value)
    value = re.sub(r'(?m)^\s{0,3}#{1,6}\s*', '', value)
    value = re.sub(r'(?m)^\s{0,3}>\s?', '', value)
    value = re.sub(r'(?m)^\s*[-*+]\s+', '• ', value)
    value = re.sub(r'(?m)^\s*\d+[.)]\s+', lambda m: f"{m.group(0).strip()} ", value)
    value = re.sub(r'(?<!\*)\*\*(?!\*)(.+?)(?<!\*)\*\*(?!\*)', r'\1', value)
    value = re.sub(r'(?<!_)__(?!_)(.+?)(?<!_)__(?!_)', r'\1', value)
    value = re.sub(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', r'\1', value)
    value = re.sub(r'(?<!_)_(?!_)(.+?)(?<!_)_(?!_)', r'\1', value)
    value = re.sub(r'~~(.+?)~~', r'\1', value)
    value = value.replace('|', ' ')
    value = re.sub(r'\s+', ' ', value).strip()
    value = value.strip('`*_~#> -')
    if len(value) > max_length:
        value = value[: max_length - 1].rstrip() + '…'
    return value


def _pick_notification_preview(*, visible_text: str, has_images: bool) -> str:
    preview = _normalize_notification_preview(visible_text)
    if preview:
        return preview
    if has_images:
        return '[图片]'
    return ''


def _resolve_contact_display_name(contact_id: str, fallback: str = 'AliceChat') -> str:
    normalized = str(contact_id or '').strip().lower()
    if not normalized:
        return fallback
    config = load_config() or {}
    routing = config.get('routing') or {}
    contacts = routing.get('contacts') or {}
    entry = contacts.get(normalized)
    if isinstance(entry, dict):
        display_name = str(entry.get('displayName') or entry.get('name') or '').strip()
        if display_name:
            return display_name
    defaults = {
        'alice': '晚秋',
        'yulinglong': '玲珑',
        'lisuxin': '素心',
    }
    return defaults.get(normalized) or fallback


def _build_notification_candidate_payload(
    *,
    session_id: str,
    request_id: str,
    client_message_id: str,
    message: dict,
    title: str,
    sender_id: str,
    sender_name: str,
    body_preview: str,
) -> dict:
    message_id = str(message.get('id') or '').strip()
    created_at = message.get('createdAt')
    return {
        'kind': 'notification.candidate',
        'eventId': f'notifcand_{uuid.uuid4().hex[:16]}',
        'sessionId': session_id,
        'requestId': request_id,
        'clientMessageId': client_message_id,
        'messageId': message_id,
        'messageKind': 'assistant_reply',
        'senderId': sender_id,
        'senderName': sender_name,
        'title': title,
        'bodyPreview': body_preview,
        'dedupeKey': f'{session_id}:{message_id}' if session_id and message_id else '',
        'createdAt': created_at,
        'routing': {
            'conversationType': 'direct',
        },
    }


def create_chat_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])
    service = ChatStreamingService(context)

    @router.post('/api/chat/stream')
    async def chat_stream(body: dict):
        return service.create_response(body)

    @router.post('/api/chat')
    async def chat_non_stream(body: dict):
        """非流式聊天端点，直接返回 JSON 结果。"""
        chunks = []
        async for chunk in service._stream(body):
            chunks.append(chunk)

        result = {"ok": False, "reply": "", "error": "No response"}

        for chunk in chunks:
            if not chunk:
                continue
            lines = chunk.strip().split('\n')
            event_name = None
            data_content = None
            for line in lines:
                if line.startswith('event:'):
                    event_name = line[6:].strip()
                elif line.startswith('data:'):
                    data_content = line[5:].strip()
            if event_name == 'final' and data_content:
                try:
                    result = json.loads(data_content)
                    break
                except json.JSONDecodeError:
                    continue

        return JSONResponse(content=result)

    @router.post('/api/messages')
    async def submit_message(body: dict):
        session_store = context.session_store
        chat_service = context.chat_service
        events_bus = context.events_bus
        request_deduper = context.request_deduper

        resolved = chat_service.resolve_request(body)
        session_id = require_existing_session(
            session_store,
            str(body.get('sessionId') or '').strip(),
        )
        routing = resolve_routing(
            contact_id=resolved.contact_id or resolved.session_name or 'assistant',
            user_id=resolved.user_id or session_id,
            session_id=session_id,
        )
        resolved = replace(
            resolved,
            agent=routing.agent_id,
            session_name=routing.session_name,
            session_key=routing.session_key,
            contact_id=routing.contact_id,
            user_id=resolved.user_id or session_id,
        )
        requested_route_key = build_route_key(
            provider_id=str(resolved.provider.get('id') or ''),
            session_key=resolved.session_key,
            agent=resolved.agent,
            session_name=resolved.session_name,
        )
        session_store.bind_route(session_id, requested_route_key)
        session_store.set_current_session_id(session_id)

        client_message_id = resolved.client_message_id or f'client_{uuid.uuid4().hex[:12]}'
        record, is_new_request = await request_deduper.get_or_create(session_id, client_message_id)
        if not is_new_request:
            _LOG.warning(
                '[alicechat.chat] duplicate_submit sessionId=%s clientMessageId=%s status=%s',
                session_id,
                client_message_id,
                record.status,
            )
            response: dict = {
                'ok': True,
                'status': 'duplicate',
                'sessionId': session_id,
                'clientMessageId': client_message_id,
            }
            if record.result is not None:
                response['result'] = record.result
            if record.error:
                response['error'] = record.error
            return JSONResponse(content=response)

        user_message_id = f'msg_user_{uuid.uuid4().hex[:12]}'
        user_message = chat_service.persist_user_message(
            session_id=session_id,
            history_text=resolved.history_text,
            attachments=resolved.attachments,
            source=resolved.message_source,
            message_id=user_message_id,
            meta=json.dumps({'clientMessageId': client_message_id}, ensure_ascii=False),
        )
        if user_message is not None:
            await events_bus.publish(
                'message.created',
                {
                    'sessionId': session_id,
                    'clientMessageId': client_message_id,
                    'message': user_message,
                },
            )
            await events_bus.publish(
                'message.status',
                {
                    'sessionId': session_id,
                    'clientMessageId': client_message_id,
                    'messageId': user_message['id'],
                    'status': 'sent',
                },
            )

        request_id = uuid.uuid4().hex

        async def run_job() -> None:
            assistant_message_id = f'msg_ai_{uuid.uuid4().hex[:12]}'
            assistant_raw_parts: list[str] = []
            latest_reply_preview = ''
            delta_seq = 0
            terminal_event_sent = False
            terminal_result_marked = False

            async def publish_failed(reason: str, error_text: str) -> None:
                nonlocal terminal_event_sent, terminal_result_marked
                if not terminal_result_marked:
                    await request_deduper.mark_failed(
                        session_id,
                        client_message_id,
                        error_text,
                    )
                    terminal_result_marked = True
                if not terminal_event_sent:
                    await events_bus.publish(
                        'assistant.message.failed',
                        {
                            'sessionId': session_id,
                            'clientMessageId': client_message_id,
                            'requestId': request_id,
                            'messageId': assistant_message_id,
                            'error': error_text,
                            'reason': reason,
                        },
                    )
                    terminal_event_sent = True

            try:
                _LOG.info(
                    '[alicechat.chat] request_started sessionId=%s clientMessageId=%s requestId=%s route=%s',
                    session_id,
                    client_message_id,
                    request_id,
                    requested_route_key,
                )
                await events_bus.publish(
                    'assistant.message.started',
                    {
                        'sessionId': session_id,
                        'clientMessageId': client_message_id,
                        'requestId': request_id,
                        'messageId': assistant_message_id,
                    },
                )

                def emit(payload: dict) -> None:
                    nonlocal delta_seq, latest_reply_preview
                    payload_type = str(payload.get('type') or 'delta').strip().lower()
                    delta_text = str(payload.get('delta') or '')
                    progress_text = str(payload.get('text') or '')
                    progress_stage = str(payload.get('stage') or 'working')
                    progress_kind = str(payload.get('kind') or progress_stage or 'progress')
                    progress_reply_preview = str(payload.get('replyPreview') or '').strip()
                    if progress_reply_preview:
                        latest_reply_preview = progress_reply_preview
                    progress_meta = {
                        'eventStream': str(payload.get('eventStream') or '').strip(),
                        'toolCallId': str(payload.get('toolCallId') or '').strip(),
                        'toolName': str(payload.get('toolName') or '').strip(),
                        'phase': str(payload.get('phase') or '').strip(),
                        'status': str(payload.get('status') or '').strip(),
                        'itemId': str(payload.get('itemId') or '').strip(),
                        'approvalId': str(payload.get('approvalId') or '').strip(),
                        'approvalSlug': str(payload.get('approvalSlug') or '').strip(),
                        'command': str(payload.get('command') or '').strip(),
                        'output': str(payload.get('output') or '').strip(),
                        'title': str(payload.get('title') or '').strip(),
                        'source': str(payload.get('source') or '').strip(),
                    }

                    if payload_type == 'progress':
                        if not progress_text and not progress_reply_preview and not any(progress_meta.values()):
                            return
                        delta_seq += 1
                        mode = 'progress'
                        if progress_kind == 'thinking' or progress_stage == 'thinking':
                            mode = 'thinking'
                        elif progress_kind == 'plan' or progress_stage == 'plan':
                            mode = 'plan'
                        events_bus.publish_threadsafe(
                            'assistant.progress',
                            {
                                'sessionId': session_id,
                                'clientMessageId': client_message_id,
                                'requestId': request_id,
                                'messageId': assistant_message_id,
                                'sequence': delta_seq,
                                'mode': mode,
                                'text': progress_text,
                                'stage': progress_stage,
                                'kind': progress_kind,
                                **({'replyPreview': progress_reply_preview} if progress_reply_preview else {}),
                                **{key: value for key, value in progress_meta.items() if value},
                            },
                        )
                        return

                    if not delta_text:
                        delta_text = progress_text
                    if not delta_text:
                        return

                    delta_seq += 1
                    assistant_raw_parts.append(delta_text)
                    preview_text = str(payload.get('replyPreview') or ''.join(assistant_raw_parts))
                    if preview_text.strip():
                        latest_reply_preview = preview_text.strip()
                    events_bus.publish_threadsafe(
                        'assistant.progress',
                        {
                            'sessionId': session_id,
                            'clientMessageId': client_message_id,
                            'requestId': request_id,
                            'messageId': assistant_message_id,
                            'sequence': delta_seq,
                            'mode': 'preview',
                            'text': delta_text,
                            'stage': 'assistant',
                            'kind': 'assistant',
                            'replyPreview': preview_text,
                        },
                    )

                result = await asyncio.to_thread(
                    chat_service.run_chat_stream,
                    resolved,
                    emit,
                    session_id=session_id,
                    route_key=requested_route_key,
                )
                reply_final_received = bool(result.get('replyFinalReceived'))
                assistant_raw = str(result.get('rawReply') or result.get('reply') or '')
                assistant_visible = str(result.get('reply') or '')
                suspicious_reason = _detect_suspicious_final(assistant_visible)
                if not reply_final_received:
                    raise RuntimeError('missing reply_final; refusing to persist non-final preview as assistant message')
                assistant_meta = resolved.assistant_meta
                if suspicious_reason:
                    assistant_meta = _build_suspicious_meta(
                        existing_meta=assistant_meta,
                        request_id=request_id,
                        reason=suspicious_reason,
                    )
                persisted_messages = chat_service.persist_assistant_message(
                    session_id=session_id,
                    reply=assistant_visible,
                    raw_reply=assistant_raw,
                    images=result.get('images') or [],
                    meta=assistant_meta,
                    source=resolved.message_source,
                )
                persisted = persisted_messages[-1] if persisted_messages else None
                if suspicious_reason and persisted is not None:
                    recovered_text = _select_preview_recovery_text(
                        final_text=assistant_visible,
                        preview_text=latest_reply_preview,
                    )
                    if recovered_text:
                        persisted = chat_service.update_message_content(
                            message_id=str(persisted.get('id') or ''),
                            text=recovered_text,
                            raw_text=recovered_text,
                            meta=_mark_recovery_meta(
                                existing_meta=persisted.get('meta'),
                                succeeded=True,
                                recovered_text=recovered_text,
                            ),
                        ) or persisted
                        persisted_messages[-1] = persisted
                        assistant_visible = recovered_text
                        assistant_raw = recovered_text
                        _LOG.warning(
                            '[alicechat.chat] suspicious_final_recovered sessionId=%s clientMessageId=%s requestId=%s reason=%s final=%r recovered=%r',
                            session_id,
                            client_message_id,
                            request_id,
                            suspicious_reason,
                            str(result.get('reply') or '')[:160],
                            recovered_text[:160],
                        )
                    else:
                        persisted = chat_service.update_message_content(
                            message_id=str(persisted.get('id') or ''),
                            meta=_mark_recovery_meta(
                                existing_meta=persisted.get('meta'),
                                succeeded=False,
                            ),
                        ) or persisted
                        persisted_messages[-1] = persisted
                        _LOG.warning(
                            '[alicechat.chat] suspicious_final_persisted sessionId=%s clientMessageId=%s requestId=%s reason=%s text=%r',
                            session_id,
                            client_message_id,
                            request_id,
                            suspicious_reason,
                            assistant_visible[:160],
                        )
                _LOG.info(
                    '[alicechat.chat] request_completed sessionId=%s clientMessageId=%s requestId=%s deltaCount=%s',
                    session_id,
                    client_message_id,
                    request_id,
                    delta_seq,
                )
                await request_deduper.mark_completed(
                    session_id,
                    client_message_id,
                    {
                        'messageId': persisted.get('id') if persisted else '',
                        'requestId': request_id,
                        'reply': assistant_visible,
                    },
                )
                terminal_result_marked = True
                for item in persisted_messages:
                    await events_bus.publish(
                        'assistant.message.completed',
                        {
                            'sessionId': session_id,
                            'clientMessageId': client_message_id,
                            'requestId': request_id,
                            'messageId': item.get('id') or assistant_message_id,
                            'message': item,
                        },
                    )
                display_name = _resolve_contact_display_name(
                    resolved.contact_id,
                    fallback=resolved.session_name or 'AliceChat',
                )
                if persisted:
                    notification_body = _pick_notification_preview(
                        visible_text=assistant_visible,
                        has_images=bool(result.get('images') or []),
                    )
                    await events_bus.publish(
                        'notification.candidate',
                        _build_notification_candidate_payload(
                            session_id=session_id,
                            request_id=request_id,
                            client_message_id=client_message_id,
                            message=persisted,
                            title=display_name,
                            sender_id=resolved.contact_id or resolved.agent or 'assistant',
                            sender_name=display_name,
                            body_preview=notification_body,
                        ),
                    )
                terminal_event_sent = True
                notification_body = _pick_notification_preview(
                    visible_text=assistant_visible,
                    has_images=bool(result.get('images') or []),
                )
                try:
                    context.push_service.notify_new_message(
                        user_id=resolved.user_id or 'alicechat-user',
                        session_id=session_id,
                        title=display_name,
                        body=notification_body,
                        message_id=str(persisted.get('id') or assistant_message_id),
                        sender_id=resolved.contact_id or resolved.agent or 'assistant',
                        sender_name=display_name,
                    )
                except Exception:
                    _LOG.exception(
                        '[alicechat.push] notify_failed sessionId=%s clientMessageId=%s requestId=%s',
                        session_id,
                        client_message_id,
                        request_id,
                    )
            except Exception as exc:  # noqa: BLE001
                _LOG.exception(
                    '[alicechat.chat] request_failed sessionId=%s clientMessageId=%s requestId=%s',
                    session_id,
                    client_message_id,
                    request_id,
                )
                await publish_failed('exception', str(exc))
            finally:
                if not terminal_event_sent:
                    fallback_error = (
                        'assistant request terminated without completed/failed terminal event '
                        f'(requestId={request_id})'
                    )
                    _LOG.error(
                        '[alicechat.chat] request_missing_terminal sessionId=%s clientMessageId=%s requestId=%s',
                        session_id,
                        client_message_id,
                        request_id,
                    )
                    await publish_failed('missing_terminal', fallback_error)

        asyncio.create_task(run_job())

        return JSONResponse(
            content={
                'ok': True,
                'status': 'accepted',
                'requestAccepted': True,
                'sessionId': session_id,
                'clientMessageId': client_message_id,
                'persistedUserMessageId': user_message['id'] if user_message else user_message_id,
                'messageId': user_message['id'] if user_message else user_message_id,
                'requestId': request_id,
            }
        )

    return router
