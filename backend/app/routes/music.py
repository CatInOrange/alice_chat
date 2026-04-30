from __future__ import annotations

from fastapi import APIRouter, Depends

from ..app_context import AppContext
from ..auth import verify_app_password


def create_music_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/music/state')
    async def get_music_state() -> dict:
        result = context.music_service.load_state()
        payload = dict(result.payload or {})
        payload.setdefault('ok', True)
        return payload

    @router.post('/api/music/state')
    async def save_music_state(body: dict) -> dict:
        result = context.music_service.save_state(body)
        payload = dict(result.payload or {})
        await context.events_bus.publish(
            'music.state_changed',
            {
                'state': payload,
            },
        )
        return {
            'ok': True,
            **payload,
        }

    @router.post('/api/music/commands')
    async def issue_music_command(body: dict) -> dict:
        event = await context.events_bus.publish(
            'music.command',
            dict(body or {}),
        )
        return {
            'ok': True,
            'seq': event.seq,
            'type': event.type,
        }

    return router
