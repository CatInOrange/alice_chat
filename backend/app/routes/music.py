from __future__ import annotations

from fastapi import APIRouter, Depends

from ..app_context import AppContext
from ..auth import verify_app_password
from ..music_api_models import MusicCommandRequest, MusicStatePatchDto


def create_music_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/music/state')
    async def get_music_state() -> dict:
        state = context.music_service.load_state().payload
        payload = state.model_dump(exclude_none=True)
        payload.setdefault('ok', True)
        return payload

    @router.post('/api/music/state')
    async def save_music_state(body: MusicStatePatchDto) -> dict:
        state = context.music_service.save_state(body).payload
        payload = state.model_dump(exclude_none=True)
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

    @router.get('/api/music/providers')
    async def list_music_providers() -> dict:
        providers = [item.model_dump(exclude_none=True) for item in context.music_service.list_providers()]
        return {
            'ok': True,
            'providers': providers,
        }

    @router.post('/api/music/commands')
    async def issue_music_command(body: MusicCommandRequest) -> dict:
        event = await context.events_bus.publish(
            'music.command',
            context.music_service.build_command_event(body),
        )
        return {
            'ok': True,
            'seq': event.seq,
            'type': event.type,
        }

    return router
