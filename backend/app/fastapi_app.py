from __future__ import annotations

from contextlib import asynccontextmanager

import asyncio
import json
import mimetypes
import uuid
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .agents.openclaw_channel import ensure_bridge_listener, set_push_callback, stop_bridge_listener
from .app_context import create_app_context
from .config import UPLOADS_DIR, get_chat_providers
from .routes.chat import create_chat_router
from .routes.debug import create_debug_router
from .routes.diary import create_diary_router
from .routes.events import create_events_router
from .routes.push import create_push_router
from .routes.media import create_media_router
from .routes.music import create_music_router
from .routes.runtime import create_runtime_router
from .routes.sessions import create_sessions_router
from .routes.tavern import create_tavern_router
from .routes.todo import create_todo_router
from .web.helpers import build_allowed_origins, build_protected_media_url, build_push_route_key, build_session_label


def _push_attachment_to_payload(item: object) -> dict | None:
    if not isinstance(item, dict):
        return None
    kind = str(item.get('type') or item.get('kind') or 'file').strip().lower() or 'file'
    raw_path = str(item.get('path') or '').strip()
    raw_url = str(item.get('url') or item.get('mediaUrl') or '').strip()
    guessed_mime_type, _ = mimetypes.guess_type(raw_path or raw_url)
    mime_type = str(item.get('mimeType') or item.get('mime_type') or guessed_mime_type or 'application/octet-stream').strip() or 'application/octet-stream'
    raw_content = str(item.get('content') or item.get('data') or '').strip()
    url = raw_url
    if raw_content:
        if raw_content.startswith('data:'):
            url = raw_content
        else:
            url = f'data:{mime_type};base64,{raw_content}'
    elif raw_path:
        url = build_protected_media_url(str(Path(raw_path).expanduser()))
    if not url:
        return None
    payload = {
        'id': f'att_push_{uuid.uuid4().hex[:12]}',
        'kind': kind,
        'mimeType': mime_type,
        'url': url,
        'status': 'ready',
        'meta': {
            **({'sourcePath': raw_path} if raw_path else {}),
        },
    }
    if item.get('audioAsVoice') is not None:
        payload['meta']['audioAsVoice'] = bool(item.get('audioAsVoice'))
    return payload


def _resolve_push_session_id(context, frame: dict) -> str:
    has_route_identity = any(
        str(frame.get(key) or '').strip()
        for key in ('sessionKey', 'agent', 'session', 'conversationLabel')
    )
    if has_route_identity:
        route_key = build_push_route_key(frame)
        session = context.session_store.find_or_create_by_route(
            route_key,
            name=build_session_label(frame),
        )
        return session.id
    current_session_id = context.session_store.get_current_session_id()
    if current_session_id and context.session_store.exists(current_session_id):
        return current_session_id
    return context.session_store.get_or_create_default().id


def _persist_push_message(context, frame: dict) -> None:
    text = str(frame.get('text') or '').strip()
    attachments = [
        payload
        for payload in (
            _push_attachment_to_payload(item)
            for item in (frame.get('attachments') or [])
        )
        if payload is not None
    ]
    if not text and not attachments:
        return
    session_id = _resolve_push_session_id(context, frame)
    created_at_raw = frame.get('ts')
    created_at = (
        float(created_at_raw) / 1000.0
        if isinstance(created_at_raw, (int, float)) and float(created_at_raw) > 10_000_000_000
        else float(created_at_raw)
        if isinstance(created_at_raw, (int, float))
        else None
    )
    meta = json.dumps(
        {
            'delivery': 'push',
            'outOfBand': True,
            'providerId': str(frame.get('providerId') or frame.get('provider') or 'openclaw-channel').strip(),
            'senderRole': str(frame.get('from') or 'assistant').strip() or 'assistant',
        },
        ensure_ascii=False,
    )
    message = context.message_store.create_message(
        session_id=session_id,
        role='assistant',
        text=text,
        raw_text=text,
        attachments=attachments,
        source='push',
        meta=meta,
        message_id=f'msg_push_{uuid.uuid4().hex[:12]}',
        created_at=created_at,
    )
    context.events_bus.publish_threadsafe(
        'assistant.message.completed',
        {
            'sessionId': session_id,
            'clientMessageId': '',
            'requestId': '',
            'messageId': message.get('id') or '',
            'message': message,
        },
    )


def create_app() -> FastAPI:
    context = create_app_context(uploads_dir=UPLOADS_DIR)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        recovery_task: asyncio.Task | None = None
        context.session_store.ensure_schema()
        context.message_store.ensure_schema()
        context.music_store.ensure_schema()
        context.music_history_store.ensure_schema()
        context.diary_store.ensure_schema()
        context.recovery_store.ensure_schema()
        context.events_bus.store.ensure_schema()
        context.push_device_store.ensure_schema()
        context.todo_store.ensure_schema()
        context.tavern_store.ensure_schema()
        context.recovery_service.ensure_schema()
        context.events_bus.bind_loop(asyncio.get_running_loop())
        set_push_callback(lambda frame: _persist_push_message(context, frame))
        recovery_task = asyncio.create_task(context.recovery_service.run_loop())
        try:
            for provider in get_chat_providers():
                if str(provider.get('type') or '').strip() == 'openclaw-channel':
                    ensure_bridge_listener(provider)
        except Exception as exc:  # noqa: BLE001
            print(f'[OpenClawChannel] listener not started: {exc}')

        try:
            yield
        finally:
            if recovery_task is not None:
                recovery_task.cancel()
                try:
                    await recovery_task
                except asyncio.CancelledError:
                    pass
            set_push_callback(None)
            stop_bridge_listener()

    app = FastAPI(
        title='AliceChat Backend',
        version='0.1',
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )

    allowed_origins, allow_origin_regex = build_allowed_origins()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,
        allow_origin_regex=allow_origin_regex,
        allow_credentials=False,
        allow_methods=['*'],
        allow_headers=['*'],
        max_age=86400,
    )

    app.include_router(create_runtime_router(context))
    app.include_router(create_sessions_router(context))
    app.include_router(create_events_router(context))
    app.include_router(create_chat_router(context))
    app.include_router(create_push_router(context))
    app.include_router(create_media_router(context))
    app.include_router(create_music_router(context))
    app.include_router(create_todo_router(context))
    app.include_router(create_diary_router(context))
    app.include_router(create_tavern_router(context))
    app.include_router(create_debug_router(context))

    app.mount('/uploads', StaticFiles(directory=str(context.uploads_dir), html=False), name='uploads')
    return app
