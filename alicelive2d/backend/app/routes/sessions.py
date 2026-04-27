from __future__ import annotations

from fastapi import APIRouter, HTTPException

from ..api_models import CreateSessionBody, CreateSessionMessageBody
from ..app_context import AppContext
from ..web.helpers import require_existing_session, session_to_api


def create_sessions_router(context: AppContext) -> APIRouter:
    router = APIRouter()

    @router.get('/api/sessions')
    async def sessions() -> dict:
        context.session_store.get_or_create_default()
        items, current_id = context.session_store.list_sessions()
        return {'sessions': [session_to_api(s) for s in items], 'currentId': current_id}

    @router.post('/api/sessions')
    async def sessions_create(body: CreateSessionBody) -> dict:
        sess = context.session_store.create_session(body.name)
        return {'ok': True, 'session': session_to_api(sess)}

    @router.post('/api/sessions/{session_id}/select')
    async def sessions_select(session_id: str) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        context.session_store.set_current_session_id(session_id)
        return {'ok': True, 'currentId': session_id}

    @router.delete('/api/sessions/{session_id}')
    async def sessions_delete(session_id: str) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        context.session_store.delete_session(session_id)
        return {'ok': True, 'deletedId': session_id}

    @router.get('/api/sessions/{session_id}/messages')
    async def session_messages(session_id: str, includeRaw: int = 0) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        messages = context.message_store.list_session_messages(session_id)
        if not includeRaw:
            for item in messages:
                item.pop('rawText', None)
        return {'sessionId': session_id, 'messages': messages}

    @router.post('/api/sessions/{session_id}/messages')
    async def session_messages_create(session_id: str, body: CreateSessionMessageBody) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        role = (body.role or 'assistant').strip() or 'assistant'
        text = (body.text or body.reply or '').strip()
        meta = (body.meta or 'OpenClaw Agent').strip()
        source = (body.source or 'api').strip() or 'api'
        attachments = body.attachments or []
        if not text and not attachments:
            raise HTTPException(status_code=400, detail='message must contain text or attachments')
        message = context.message_store.create_message(
            session_id=session_id,
            role=role,
            text=text,
            attachments=attachments,
            source=source,
            meta=meta,
        )
        return {'ok': True, 'message': message}

    return router
