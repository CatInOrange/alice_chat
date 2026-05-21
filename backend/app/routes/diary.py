from __future__ import annotations

from fastapi import APIRouter, Depends

from ..app_context import AppContext
from ..auth import verify_app_password


def create_diary_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/diary/entries')
    async def diary_entries(agentId: str = 'alice', limit: int = 30) -> dict:
        return {
            'ok': True,
            'entries': context.diary_service.list_entries(
                agent_id=agentId,
                limit=limit,
            ),
        }

    @router.get('/api/diary/entries/{date}')
    async def diary_entry(date: str, agentId: str = 'alice') -> dict:
        entry = context.diary_service.get_entry(agent_id=agentId, date=date)
        return {
            'ok': True,
            'exists': entry is not None,
            'entry': entry,
        }

    @router.post('/api/diary/entries/{date}/generate')
    async def diary_generate(date: str, body: dict | None = None) -> dict:
        payload = body or {}
        entry = await context.diary_service.generate_entry(
            agent_id=str(payload.get('agentId') or 'alice'),
            date=date,
            source=str(payload.get('source') or 'manual'),
            force=payload.get('force') is True,
        )
        return {
            'ok': entry.get('status') != 'failed',
            'entry': entry,
        }

    return router
