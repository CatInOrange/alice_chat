from __future__ import annotations

import logging
from dataclasses import dataclass
from time import sleep, time

from ..music_api_models import (
    MusicAiPlaylistDraftDto,
    MusicCommandRequest,
    MusicIntelligenceRequestDto,
    MusicProviderDto,
    MusicStateDto,
    MusicStatePatchDto,
)
from ..store import MusicStore
from .netease_openapi_service import NeteaseOpenApiError, NeteaseOpenApiResult, NeteaseOpenApiService

_LOG = logging.getLogger(__name__)


@dataclass(slots=True)
class MusicStateResult:
    payload: MusicStateDto


@dataclass(slots=True)
class MusicAiPlaylistResult:
    payload: MusicAiPlaylistDraftDto | None


@dataclass(slots=True)
class MusicAiPlaylistHistoryResult:
    payload: list[MusicAiPlaylistDraftDto]


class MusicService:
    def __init__(self, *, store: MusicStore | None = None, config: dict | None = None):
        self.store = store or MusicStore()
        self.netease_openapi = NeteaseOpenApiService(config or {})

    def load_state(self) -> MusicStateResult:
        return MusicStateResult(payload=MusicStateDto.model_validate(self.store.load_state()))

    def save_state(self, patch: MusicStatePatchDto) -> MusicStateResult:
        return MusicStateResult(payload=MusicStateDto.model_validate(self.store.save_state(patch.model_dump(exclude_none=True))))

    def load_latest_ai_playlist(self) -> MusicAiPlaylistResult:
        state = self.store.load_state()
        payload = state.get('latestAiPlaylist')
        if not isinstance(payload, dict):
            return MusicAiPlaylistResult(payload=None)
        return MusicAiPlaylistResult(
            payload=MusicAiPlaylistDraftDto.model_validate(payload)
        )

    def load_ai_playlist_history(self) -> MusicAiPlaylistHistoryResult:
        state = self.store.load_state()
        raw_items = state.get('aiPlaylistHistory')
        if not isinstance(raw_items, list):
            return MusicAiPlaylistHistoryResult(payload=[])
        items = [
            MusicAiPlaylistDraftDto.model_validate(item)
            for item in raw_items
            if isinstance(item, dict)
        ]
        items.sort(
            key=lambda item: item.updatedAt or item.createdAt or 0,
            reverse=True,
        )
        return MusicAiPlaylistHistoryResult(payload=items)

    def save_latest_ai_playlist(self, playlist: MusicAiPlaylistDraftDto) -> MusicAiPlaylistResult:
        now = time()
        state = self.store.load_state()
        latest_payload = state.get('latestAiPlaylist')
        latest_existing = (
            MusicAiPlaylistDraftDto.model_validate(latest_payload)
            if isinstance(latest_payload, dict)
            else None
        )
        history = self.load_ai_playlist_history().payload
        canonical_latest = playlist.model_copy(
            update={
                'id': 'ai-playlist:latest',
                'createdAt': latest_existing.createdAt if latest_existing else (playlist.createdAt or now),
                'updatedAt': playlist.updatedAt or now,
            }
        )
        raw_history_id = (playlist.id or '').strip()
        deduped_history = history[:50]
        if raw_history_id != 'ai-playlist:latest':
            history_id = raw_history_id or f'ai-playlist:{int(now * 1000)}'
            history_created_at = playlist.createdAt or canonical_latest.updatedAt or now
            history_entry = canonical_latest.model_copy(
                update={
                    'id': history_id,
                    'createdAt': history_created_at,
                    'updatedAt': canonical_latest.updatedAt or now,
                }
            )
            deduped_history = [
                history_entry,
                *[
                    item
                    for item in history
                    if item.id != history_entry.id
                ],
            ][:50]
        saved = self.store.save_state(
            {
                'latestAiPlaylist': canonical_latest.model_dump(exclude_none=True),
                'aiPlaylistHistory': [
                    item.model_dump(exclude_none=True) for item in deduped_history
                ],
            }
        )
        payload = saved.get('latestAiPlaylist')
        if not isinstance(payload, dict):
            return MusicAiPlaylistResult(payload=None)
        return MusicAiPlaylistResult(
            payload=MusicAiPlaylistDraftDto.model_validate(payload)
        )

    def build_command_event(self, command: MusicCommandRequest) -> dict:
        return command.model_dump(exclude_none=True)

    def load_netease_intelligence(self, request: MusicIntelligenceRequestDto) -> NeteaseOpenApiResult:
        state = self.store.load_state()
        fallback_playlist_id = str(state.get('neteaseLikedPlaylistEncryptedId') or '').strip()
        song_payload = request.song.model_dump(exclude_none=True)
        playlist_payload = None if request.playlist is None else request.playlist.model_dump(exclude_none=True)
        last_error: Exception | None = None
        retry_delays = [1, 2, 3, 4, 5]
        max_attempts = len(retry_delays) + 1
        for attempt in range(1, max_attempts + 1):
            try:
                _LOG.info(
                    '[music.intelligence.request] attempt=%s/%s song=%s sourceTrackId=%s encryptedSongId=%s playlistId=%s fallbackPlaylistId=%s mode=%s count=%s',
                    attempt,
                    max_attempts,
                    song_payload.get('trackId') or song_payload.get('id'),
                    song_payload.get('sourceTrackId'),
                    song_payload.get('encryptedSourceTrackId') or song_payload.get('encryptedTrackId'),
                    None if playlist_payload is None else playlist_payload.get('playlistId'),
                    fallback_playlist_id or None,
                    request.mode,
                    request.count,
                )
                result = self.netease_openapi.get_intelligence_tracks(
                    song=song_payload,
                    playlist=playlist_payload,
                    fallback_playlist_id=fallback_playlist_id or None,
                    count=request.count,
                    mode=request.mode,
                )
                _LOG.info(
                    '[music.intelligence.success] attempt=%s/%s trackCount=%s playlistEncryptedId=%s songEncryptedId=%s fallbackUsed=%s',
                    attempt,
                    max_attempts,
                    len(result.tracks),
                    result.playlist_encrypted_id,
                    result.song_encrypted_id,
                    result.fallback_used,
                )
                patch: dict[str, object] = {}
                if result.playlist_encrypted_id and result.playlist_encrypted_id != fallback_playlist_id:
                    patch['neteaseLikedPlaylistEncryptedId'] = result.playlist_encrypted_id
                if patch:
                    self.store.save_state(patch)
                return result
            except NeteaseOpenApiError as exc:
                last_error = exc
                will_retry = attempt < max_attempts
                next_delay = retry_delays[attempt - 1] if will_retry else None
                _LOG.warning(
                    '[music.intelligence.failure] attempt=%s/%s willRetry=%s nextDelaySeconds=%s song=%s sourceTrackId=%s encryptedSongId=%s playlistId=%s fallbackPlaylistId=%s error=%s',
                    attempt,
                    max_attempts,
                    will_retry,
                    next_delay,
                    song_payload.get('trackId') or song_payload.get('id'),
                    song_payload.get('sourceTrackId'),
                    song_payload.get('encryptedSourceTrackId') or song_payload.get('encryptedTrackId'),
                    None if playlist_payload is None else playlist_payload.get('playlistId'),
                    fallback_playlist_id or None,
                    str(exc),
                )
                if not will_retry:
                    break
                sleep(next_delay)
        assert last_error is not None
        raise last_error

    def sync_netease_favorite_playlist(self) -> dict:
        playlist = self.netease_openapi.get_favorite_playlist()
        encrypted_id = str(playlist.get('id') or '').strip()
        original_id = str(playlist.get('originalId') or '').strip()
        patch = {}
        if encrypted_id:
            patch['neteaseLikedPlaylistEncryptedId'] = encrypted_id
        if original_id:
            patch['neteaseLikedPlaylistOriginalId'] = original_id
        if patch:
            self.store.save_state(patch)
        return playlist

    def load_netease_fm(self, *, limit: int = 3) -> list:
        return self.netease_openapi.get_fm_tracks(limit=limit)

    def list_providers(self) -> list[MusicProviderDto]:
        return [
            MusicProviderDto(
                providerId='netease',
                displayName='网易云音乐',
                authMode='client',
                supportedAuthMethods=['cookieImport', 'qrCode'],
                supportsSearch=True,
                supportsLyrics=True,
                supportsResolve=True,
                supportsPlaylistLookup=True,
                supportsUserLibrary=True,
                notes='优先平台；已接搜索、播放解析、歌单读取与 Cookie/二维码登录。',
            ),
            MusicProviderDto(
                providerId='migu',
                displayName='咪咕音乐',
                authMode='client',
                supportedAuthMethods=['cookieImport'],
                supportsSearch=True,
                supportsLyrics=False,
                supportsResolve=True,
                supportsPlaylistLookup=False,
                supportsUserLibrary=False,
                notes='当前先接搜索与播放解析；Cookie 导入为后续账号能力预留。',
            ),
        ]
