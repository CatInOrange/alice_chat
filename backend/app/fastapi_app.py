from __future__ import annotations

from contextlib import asynccontextmanager

import asyncio
import json
import mimetypes
import re
import shutil
import time
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
from .routes.habits import create_habits_router
from .routes.push import create_push_router
from .routes.media import create_media_router
from .routes.music import create_music_router
from .routes.runtime import create_runtime_router
from .routes.sessions import create_sessions_router
from .routes.tavern import create_tavern_router
from .routes.todo import create_todo_router
from .web.helpers import build_allowed_origins, build_protected_media_url, build_push_route_key, build_session_label


_SAFE_ATTACHMENT_NAME_RE = re.compile(r'[^A-Za-z0-9._-]+')


def _safe_attachment_stem(path: Path) -> str:
    value = _SAFE_ATTACHMENT_NAME_RE.sub('_', path.stem).strip('._')
    return value or 'attachment'


def _infer_push_attachment_kind(*, explicit_kind: str, mime_type: str) -> str:
    kind = str(explicit_kind or '').strip().lower()
    normalized_mime = str(mime_type or '').strip().lower()
    inferred = 'file'
    if normalized_mime.startswith('image/'):
        inferred = 'image'
    elif normalized_mime.startswith('audio/'):
        inferred = 'audio'
    elif normalized_mime.startswith('video/'):
        inferred = 'video'
    if kind == 'document':
        return 'file'
    if kind in {'image', 'audio', 'video'}:
        # Some upstream channel/media APIs use "type=image" as a generic media
        # envelope. Do not let that override a concrete non-image MIME type.
        return kind if inferred == kind else inferred
    if kind == 'file':
        return inferred if inferred != 'file' else 'file'
    return inferred


def _copy_push_attachment_to_uploads(context, *, raw_path: str, kind: str) -> tuple[str, int | None] | None:
    source = Path(raw_path).expanduser().resolve()
    if not source.is_file():
        return None
    bucket = 'media' if kind in {'image', 'audio', 'video'} else 'files'
    year_month = time.strftime('%Y/%m')
    target_dir = context.uploads_dir / bucket / year_month
    target_dir.mkdir(parents=True, exist_ok=True)
    suffix = source.suffix
    stored_name = f'{_safe_attachment_stem(source)[:48]}_{uuid.uuid4().hex[:8]}{suffix}'
    target = target_dir / stored_name
    shutil.copyfile(source, target)
    return f'/uploads/{bucket}/{year_month}/{stored_name}', source.stat().st_size


def _push_attachment_to_payload(context, item: object) -> dict | None:
    if not isinstance(item, dict):
        return None
    explicit_kind = str(item.get('kind') or item.get('type') or '').strip().lower()
    raw_path = str(item.get('path') or '').strip()
    raw_url = str(item.get('url') or item.get('mediaUrl') or '').strip()
    guessed_mime_type, _ = mimetypes.guess_type(raw_path or raw_url)
    explicit_mime_type = str(item.get('mimeType') or item.get('mime_type') or '').strip()
    mime_type = (
        guessed_mime_type
        if not explicit_mime_type or explicit_mime_type == 'application/octet-stream'
        else explicit_mime_type
    ) or 'application/octet-stream'
    kind = _infer_push_attachment_kind(
        explicit_kind=explicit_kind,
        mime_type=mime_type,
    )
    raw_content = str(item.get('content') or item.get('data') or '').strip()
    url = raw_url
    copied_size: int | None = None
    if raw_content:
        if raw_content.startswith('data:'):
            url = raw_content
        else:
            url = f'data:{mime_type};base64,{raw_content}'
    elif raw_path:
        try:
            copied = _copy_push_attachment_to_uploads(context, raw_path=raw_path, kind=kind)
        except Exception as exc:  # noqa: BLE001
            print(f'[push attachment] failed to copy {raw_path!r} into uploads: {exc}')
            copied = None
        if copied is not None:
            url, copied_size = copied
        else:
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
    filename = str(item.get('name') or item.get('filename') or '').strip()
    if not filename and raw_path:
        filename = Path(raw_path).name
    if not filename and raw_url and not raw_url.startswith('data:'):
        filename = Path(raw_url.split('?', 1)[0]).name
    if filename:
        payload['name'] = filename
        payload['filename'] = filename
    size = item.get('size')
    if isinstance(size, int) and size >= 0:
        payload['size'] = size
    elif copied_size is not None:
        payload['size'] = copied_size
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
            _push_attachment_to_payload(context, item)
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
        diary_scheduler_task: asyncio.Task | None = None
        habits_scheduler_task: asyncio.Task | None = None
        context.session_store.ensure_schema()
        context.message_store.ensure_schema()
        context.music_store.ensure_schema()
        context.music_history_store.ensure_schema()
        context.diary_store.ensure_schema()
        context.recovery_store.ensure_schema()
        context.events_bus.store.ensure_schema()
        context.push_device_store.ensure_schema()
        context.todo_store.ensure_schema()
        context.habits_store.ensure_schema()
        context.tavern_store.ensure_schema()
        context.recovery_service.ensure_schema()
        context.events_bus.bind_loop(asyncio.get_running_loop())
        set_push_callback(lambda frame: _persist_push_message(context, frame))
        recovery_task = asyncio.create_task(context.recovery_service.run_loop())
        diary_scheduler_task = asyncio.create_task(context.diary_service.run_daily_scheduler())
        habits_scheduler_task = asyncio.create_task(context.habits_service.run_daily_scheduler())
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
            if diary_scheduler_task is not None:
                diary_scheduler_task.cancel()
                try:
                    await diary_scheduler_task
                except asyncio.CancelledError:
                    pass
            if habits_scheduler_task is not None:
                habits_scheduler_task.cancel()
                try:
                    await habits_scheduler_task
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
    app.include_router(create_habits_router(context))
    app.include_router(create_diary_router(context))
    app.include_router(create_tavern_router(context))
    app.include_router(create_debug_router(context))

    app.mount('/uploads', StaticFiles(directory=str(context.uploads_dir), html=False), name='uploads')
    return app
