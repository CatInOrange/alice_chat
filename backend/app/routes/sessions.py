from __future__ import annotations

from fastapi import APIRouter, Depends

from ..api_models import CreateSessionBody, CreateSessionMessageBody
from ..app_context import AppContext
from ..auth import verify_app_password
from ..web.helpers import require_existing_session, session_to_api


def _message_to_event_payload(message: dict) -> dict:
    payload = dict(message)
    payload.pop('rawText', None)
    return payload


def create_sessions_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/sessions')
    async def sessions() -> dict:
        context.session_store.get_or_create_default()
        items, current_id = context.session_store.list_sessions()
        return {'sessions': [session_to_api(s) for s in items], 'currentId': current_id}

    @router.post('/api/sessions')
    async def sessions_create(body: CreateSessionBody) -> dict:
        requested_id = str(body.id or '').strip()
        if requested_id:
            sess = context.session_store.ensure_session(
                requested_id,
                name=body.name,
                select=True,
            )
        else:
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
    async def session_messages(
        session_id: str,
        includeRaw: int = 0,
        limit: int = 20,
        before: str = '',
        after: str = '',
    ) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        page = context.message_store.list_session_messages_page(
            session_id,
            limit=limit,
            before_message_id=str(before or '').strip() or None,
            after_message_id=str(after or '').strip() or None,
        )
        if str(before or '').strip() and page['paging'].get('hasMoreBefore') is False:
            recovered_after = 0
            imported = context.recovery_service.backfill_session_before(
                session_id,
                before_message_id=str(before or '').strip(),
                limit=limit,
            )
            if imported <= 0:
                recovered_after = context.recovery_service.recover_missing_after_latest_user(
                    session_id,
                    limit=limit,
                )
            if imported > 0 or recovered_after > 0:
                page = context.message_store.list_session_messages_page(
                    session_id,
                    limit=limit,
                    before_message_id=str(before or '').strip() or None,
                    after_message_id=str(after or '').strip() or None,
                )
        if str(after or '').strip() and not page['messages']:
            imported = context.recovery_service.recover_missing_after_latest_user(
                session_id,
                limit=limit,
            )
            if imported > 0:
                page = context.message_store.list_session_messages_page(
                    session_id,
                    limit=limit,
                    before_message_id=str(before or '').strip() or None,
                    after_message_id=str(after or '').strip() or None,
                )
            recovered = await context.recovery_service.recover_session_once(
                session_id,
                after_message_id=str(after or '').strip(),
                min_age_seconds=context.recovery_service.recovery_timeout_seconds,
            )
            if recovered:
                page = context.message_store.list_session_messages_page(
                    session_id,
                    limit=limit,
                    before_message_id=str(before or '').strip() or None,
                    after_message_id=str(after or '').strip() or None,
                )
        messages = page['messages']
        if not includeRaw:
            for message in messages:
                message.pop('rawText', None)
        return {
            'sessionId': session_id,
            'messages': messages,
            'paging': page['paging'],
        }

    @router.post('/api/sessions/{session_id}/reconcile-tail')
    async def session_reconcile_tail(session_id: str, body: dict | None = None) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        payload = body or {}
        limit = int(payload.get('limit') or 5)
        result = await context.recovery_service.reconcile_session_tail(
            session_id,
            tail_limit=limit,
        )
        page = context.message_store.list_session_messages_page(
            session_id,
            limit=limit,
        )
        messages = page['messages']
        for message in messages:
            message.pop('rawText', None)
        return {
            'ok': result.get('ok', True),
            'sessionId': session_id,
            'changed': bool(result.get('changed')),
            'reason': str(result.get('reason') or ''),
            'actions': list(result.get('actions') or []),
            'messages': messages,
            'paging': page['paging'],
        }

    @router.post('/api/sessions/{session_id}/messages')
    async def session_messages_create(session_id: str, body: CreateSessionMessageBody) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        msg = context.message_store.create_message(
            session_id=session_id,
            role=str(body.role or 'assistant'),
            text=str(body.text or body.reply or ''),
            meta=str(body.meta or ''),
            source=str(body.source or 'manual'),
            attachments=list(body.attachments or []),
        )
        return {'ok': True, 'message': msg}

    @router.delete('/api/sessions/{session_id}/messages/{message_id}')
    async def session_message_delete(session_id: str, message_id: str) -> dict:
        session_id = require_existing_session(context.session_store, session_id)
        message = context.message_store.get_message(message_id)
        if message is None or str(message.get('sessionId') or '') != session_id:
            return {'ok': False, 'error': 'message not found'}
        deleted = context.message_store.soft_delete_message(
            message_id,
            deleted_by='user',
        )
        if deleted is None:
            return {'ok': False, 'error': 'message not found'}
        await context.events_bus.publish(
            'message.deleted',
            {
                'sessionId': session_id,
                'messageId': message_id,
                'message': _message_to_event_payload(deleted),
            },
        )
        return {
            'ok': True,
            'sessionId': session_id,
            'messageId': message_id,
            'deleted': True,
            'deletedAt': deleted.get('deletedAt'),
        }

    return router
