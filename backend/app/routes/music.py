from __future__ import annotations

from fastapi import APIRouter, Depends

from ..app_context import AppContext
from ..auth import verify_app_password
from fastapi import HTTPException

from ..music_api_models import (
    MusicAiPlaylistDraftDto,
    MusicCommandRequest,
    MusicIntelligenceRequestDto,
    MusicStatePatchDto,
)
from ..services.netease_openapi_service import NeteaseOpenApiError


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

    @router.get('/api/music/ai-playlists/latest')
    async def get_latest_ai_playlist() -> dict:
        playlist = context.music_service.load_latest_ai_playlist().payload
        return {
            'ok': True,
            'playlist': None if playlist is None else playlist.model_dump(exclude_none=True),
        }

    @router.get('/api/music/ai-playlists/history')
    async def get_ai_playlist_history() -> dict:
        items = context.music_service.load_ai_playlist_history().payload
        return {
            'ok': True,
            'playlists': [item.model_dump(exclude_none=True) for item in items],
        }

    @router.post('/api/music/ai-playlists/latest')
    async def save_latest_ai_playlist(body: MusicAiPlaylistDraftDto) -> dict:
        playlist = context.music_service.save_latest_ai_playlist(body).payload
        payload = playlist.model_dump(exclude_none=True)
        await context.events_bus.publish(
            'music.ai_playlist_updated',
            {
                'playlist': payload,
            },
        )
        return {
            'ok': True,
            'playlist': payload,
        }

    @router.post('/api/music/netease/intelligence')
    async def get_netease_intelligence(body: MusicIntelligenceRequestDto) -> dict:
        try:
            result = context.music_service.load_netease_intelligence(body)
        except NeteaseOpenApiError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            'ok': True,
            'tracks': [item.model_dump(exclude_none=True) for item in result.tracks],
            'context': {
                'playlistEncryptedId': result.playlist_encrypted_id,
                'songEncryptedId': result.song_encrypted_id,
                'fallbackUsed': result.fallback_used,
            },
        }

    @router.post('/api/music/netease/favorite/sync')
    async def sync_netease_favorite_playlist() -> dict:
        try:
            playlist = context.music_service.sync_netease_favorite_playlist()
        except NeteaseOpenApiError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            'ok': True,
            'playlist': playlist,
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
