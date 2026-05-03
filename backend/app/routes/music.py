from __future__ import annotations

import logging
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from fastapi import HTTPException, Query

from ..music_api_models import (
    MusicAiPlaylistDraftDto,
    MusicCommandRequest,
    MusicIntelligenceRequestDto,
    MusicStatePatchDto,
)
from ..services.netease_openapi_service import NeteaseOpenApiError

_LOG = logging.getLogger(__name__)
_ARTWORK_PROXY_ALLOWED_HOSTS = {
    'p1.music.126.net',
    'p2.music.126.net',
    'p3.music.126.net',
    'p4.music.126.net',
}


def _is_allowed_artwork_url(raw_url: str) -> bool:
    try:
        parsed = urlparse(raw_url)
    except Exception:
        return False
    if parsed.scheme.lower() != 'https':
        return False
    host = (parsed.hostname or '').lower()
    return host in _ARTWORK_PROXY_ALLOWED_HOSTS


def create_music_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/music/state')
    async def get_music_state() -> dict:
        state = context.music_service.load_state().payload
        payload = state.model_dump(exclude_none=True)
        payload.setdefault('ok', True)
        return payload

    @router.get('/api/music/home')
    async def get_music_home() -> dict:
        state = context.music_service.load_home().payload
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

    @router.get('/api/music/artwork')
    async def proxy_music_artwork(url: str = Query(..., min_length=1)):
        raw_url = url.strip()
        if not _is_allowed_artwork_url(raw_url):
            raise HTTPException(status_code=400, detail='unsupported artwork url')

        request = Request(
            raw_url,
            headers={
                'User-Agent': 'AliceChatBackend/1.0',
                'Accept': 'image/*,*/*;q=0.8',
                'Referer': 'https://music.163.com/',
            },
        )
        try:
            upstream = urlopen(request, timeout=15)
        except HTTPError as exc:
            _LOG.warning('[music.artwork.proxy.error] status=%s url=%s', exc.code, raw_url)
            raise HTTPException(status_code=exc.code or 502, detail='upstream artwork request failed') from exc
        except URLError as exc:
            _LOG.warning('[music.artwork.proxy.error] reason=%s url=%s', exc.reason, raw_url)
            raise HTTPException(status_code=502, detail='upstream artwork request failed') from exc
        except Exception as exc:  # noqa: BLE001
            _LOG.warning('[music.artwork.proxy.error] unexpected=%s url=%s', exc, raw_url)
            raise HTTPException(status_code=502, detail='upstream artwork request failed') from exc

        status = getattr(upstream, 'status', 200) or 200
        if status >= 400:
            raise HTTPException(status_code=status, detail='upstream artwork request failed')

        content_type = upstream.headers.get('Content-Type', 'image/*')
        cache_control = upstream.headers.get('Cache-Control', 'public, max-age=86400')
        content_length = upstream.headers.get('Content-Length')
        etag = upstream.headers.get('ETag')
        last_modified = upstream.headers.get('Last-Modified')

        _LOG.info(
            '[music.artwork.proxy.ok] status=%s content_type=%s content_length=%s url=%s',
            status,
            content_type,
            content_length,
            raw_url,
        )

        def iter_chunks():
            try:
                while True:
                    chunk = upstream.read(64 * 1024)
                    if not chunk:
                        break
                    yield chunk
            finally:
                upstream.close()

        headers = {
            'Cache-Control': cache_control,
            'X-AliceChat-Artwork-Proxy': '1',
        }
        if content_length:
            headers['Content-Length'] = content_length
        if etag:
            headers['ETag'] = etag
        if last_modified:
            headers['Last-Modified'] = last_modified

        return StreamingResponse(
            iter_chunks(),
            media_type=content_type,
            headers=headers,
            status_code=status,
        )

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

    @router.post('/api/music/netease/cli-login/start')
    async def start_netease_cli_login() -> dict:
        try:
            session = context.music_service.start_netease_cli_login()
        except NeteaseOpenApiError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            'ok': True,
            'session': session.model_dump(exclude_none=True),
        }

    @router.get('/api/music/netease/cli-login/status')
    async def get_netease_cli_login_status() -> dict:
        try:
            session = context.music_service.get_netease_cli_login_status()
        except NeteaseOpenApiError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            'ok': True,
            'session': session.model_dump(exclude_none=True),
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
                'rawTrackCount': result.raw_track_count,
                'dedupTrackCount': result.dedup_track_count,
                'source': result.source,
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

    @router.get('/api/music/netease/fm')
    async def get_netease_fm(limit: int = 3) -> dict:
        try:
            tracks = context.music_service.load_netease_fm(limit=limit)
        except NeteaseOpenApiError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            'ok': True,
            'tracks': [item.model_dump(exclude_none=True) for item in tracks],
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
