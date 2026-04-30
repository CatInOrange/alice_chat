from __future__ import annotations

from contextlib import asynccontextmanager

import asyncio

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .agents.openclaw_channel import ensure_bridge_listener, stop_bridge_listener
from .app_context import create_app_context
from .config import UPLOADS_DIR, get_chat_providers
from .routes.chat import create_chat_router
from .routes.debug import create_debug_router
from .routes.events import create_events_router
from .routes.push import create_push_router
from .routes.media import create_media_router
from .routes.music import create_music_router
from .routes.runtime import create_runtime_router
from .routes.sessions import create_sessions_router
from .web.helpers import build_allowed_origins


def create_app() -> FastAPI:
    context = create_app_context(uploads_dir=UPLOADS_DIR)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        context.session_store.ensure_schema()
        context.message_store.ensure_schema()
        context.music_store.ensure_schema()
        context.events_bus.store.ensure_schema()
        context.push_device_store.ensure_schema()
        context.events_bus.bind_loop(asyncio.get_running_loop())
        try:
            for provider in get_chat_providers():
                if str(provider.get('type') or '').strip() == 'openclaw-channel':
                    ensure_bridge_listener(provider)
        except Exception as exc:  # noqa: BLE001
            print(f'[OpenClawChannel] listener not started: {exc}')

        try:
            yield
        finally:
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
    app.include_router(create_debug_router(context))

    app.mount('/uploads', StaticFiles(directory=str(context.uploads_dir), html=False), name='uploads')
    return app
