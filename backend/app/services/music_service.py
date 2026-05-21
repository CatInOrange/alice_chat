from __future__ import annotations

import logging
from dataclasses import dataclass
from time import sleep, time

from ..music_api_models import (
    MusicAiPlaylistDraftDto,
    MusicActionRequest,
    MusicCliLoginSessionDto,
    MusicCommandRequest,
    MusicFmTrashRequestDto,
    MusicHomeDto,
    MusicIntelligenceRequestDto,
    MusicProviderDto,
    MusicStateDto,
    MusicStatePatchDto,
)
from ..store import MusicHistoryStore, MusicStore
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


@dataclass(slots=True)
class MusicHomeResult:
    payload: MusicHomeDto


class MusicService:
    def __init__(
        self,
        *,
        store: MusicStore | None = None,
        history_store: MusicHistoryStore | None = None,
        config: dict | None = None,
    ):
        self.store = store or MusicStore()
        self.history_store = history_store or MusicHistoryStore()
        self.netease_openapi = NeteaseOpenApiService(config or {})

    def load_state(self) -> MusicStateResult:
        return MusicStateResult(payload=MusicStateDto.model_validate(self.store.load_state()))

    def save_state(self, patch: MusicStatePatchDto) -> MusicStateResult:
        raw_patch = patch.model_dump(exclude_unset=True)
        saved = self.store.save_state(raw_patch)
        self._record_play_from_patch(raw_patch)
        return MusicStateResult(
            payload=MusicStateDto.model_validate(saved)
        )

    def record_play(self, payload: dict) -> dict | None:
        track = payload.get('track') if isinstance(payload.get('track'), dict) else None
        if not track:
            return None
        played_at_raw = payload.get('playedAt')
        played_at = float(played_at_raw) if isinstance(played_at_raw, (int, float)) else None
        return self.history_store.record_play(
            track=track,
            played_at=played_at,
            playlist_id=str(payload.get('playlistId') or ''),
            source=str(payload.get('source') or 'client'),
            meta={'positionMs': payload.get('positionMs')},
        )

    def list_play_history_day(self, *, date: str, limit: int = 200) -> list[dict]:
        return self.history_store.list_day(date=date, limit=limit)

    def _record_play_from_patch(self, patch: dict) -> None:
        track = patch.get('currentTrack') if isinstance(patch.get('currentTrack'), dict) else None
        if not track or patch.get('isPlaying') is not True:
            return
        self.history_store.record_play(
            track=track,
            playlist_id=str(patch.get('currentPlaylistId') or ''),
            source='state',
            meta={'positionMs': patch.get('positionMs')},
        )

    def load_latest_ai_playlist(self) -> MusicAiPlaylistResult:
        state = self.store.load_state()
        payload = state.get('latestAiPlaylist')
        if not isinstance(payload, dict):
            return MusicAiPlaylistResult(payload=None)
        return MusicAiPlaylistResult(
            payload=MusicAiPlaylistDraftDto.model_validate(payload)
        )

    def load_home(self) -> MusicHomeResult:
        state = self.store.load_state()
        latest_payload = state.get('latestAiPlaylist')
        ai_history_payload = state.get('aiPlaylistHistory')
        recent_tracks_payload = state.get('recentTracks')
        recent_playlists_payload = state.get('recentPlaylists')
        liked_tracks_payload = state.get('likedTracks')
        custom_playlists_payload = state.get('customPlaylists')
        return MusicHomeResult(
            payload=MusicHomeDto.model_validate(
                {
                    'latestAiPlaylist': latest_payload if isinstance(latest_payload, dict) else None,
                    'aiPlaylistHistory': ai_history_payload if isinstance(ai_history_payload, list) else [],
                    'recentTracks': recent_tracks_payload if isinstance(recent_tracks_payload, list) else [],
                    'recentPlaylists': recent_playlists_payload if isinstance(recent_playlists_payload, list) else [],
                    'likedTracks': liked_tracks_payload if isinstance(liked_tracks_payload, list) else [],
                    'customPlaylists': custom_playlists_payload if isinstance(custom_playlists_payload, list) else [],
                    'neteaseLikedPlaylistId': state.get('neteaseLikedPlaylistId'),
                    'neteaseLikedPlaylistOpaqueId': state.get('neteaseLikedPlaylistOpaqueId') or state.get('neteaseLikedPlaylistEncryptedId'),
                    'localRevision': state.get('localRevision'),
                    'updatedAt': state.get('updatedAt'),
                }
            )
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

    def build_action_event(self, action: MusicActionRequest) -> dict:
        return action.model_dump(exclude_none=True)

    def build_action_state_patch(self, action: MusicActionRequest) -> dict:
        payload = action.payload if isinstance(action.payload, dict) else {}
        current = self.store.load_state()
        queue = list(current.get('queue') or [])
        current_track = current.get('currentTrack')
        current_playlist_id = current.get('currentPlaylistId')
        is_playing = bool(current.get('isPlaying') is True)
        position_ms = int(current.get('positionMs') or 0)

        def _queue_item(track: dict) -> dict:
            return {'track': track, 'requestedBy': action.source}

        def _playlist_id() -> str | None:
            playlist = payload.get('playlist') if isinstance(payload.get('playlist'), dict) else None
            playlist_draft = payload.get('playlistDraft') if isinstance(payload.get('playlistDraft'), dict) else None
            raw = (
                (playlist or {}).get('id')
                or (playlist_draft or {}).get('id')
                or None
            )
            value = str(raw or '').strip()
            return value or None

        if action.type == 'play_track':
            track = payload.get('track') if isinstance(payload.get('track'), dict) else None
            if not track:
                return {}
            return {
                'currentTrack': track,
                'queue': [_queue_item(track)],
                'currentPlaylistId': _playlist_id(),
                'isPlaying': True,
                'positionMs': 0,
            }

        if action.type == 'play_playlist':
            playlist_draft = payload.get('playlistDraft') if isinstance(payload.get('playlistDraft'), dict) else None
            tracks = playlist_draft.get('tracks') if isinstance(playlist_draft, dict) else None
            start_index_raw = payload.get('startIndex')
            start_index = int(start_index_raw) if isinstance(start_index_raw, (int, float)) else 0
            track_items = [item for item in (tracks or []) if isinstance(item, dict)]
            if not track_items:
                return {
                    'currentPlaylistId': _playlist_id(),
                    'positionMs': 0,
                }
            start_index = max(0, min(start_index, len(track_items) - 1))
            ordered_tracks = track_items[start_index:] + track_items[:start_index]
            return {
                'currentTrack': ordered_tracks[0],
                'queue': [_queue_item(track) for track in ordered_tracks],
                'currentPlaylistId': _playlist_id(),
                'isPlaying': True,
                'positionMs': 0,
            }

        if action.type in {'queue_next', 'queue_append'}:
            tracks = [item for item in (payload.get('tracks') or []) if isinstance(item, dict)]
            if not tracks:
                return {}
            incoming = [_queue_item(track) for track in tracks]
            playlist_id = _playlist_id()
            if action.type == 'queue_next':
                if queue:
                    queue = [queue[0], *incoming, *queue[1:]]
                else:
                    queue = incoming
                    current_track = tracks[0]
            else:
                queue = [*queue, *incoming]
                if not current_track and tracks:
                    current_track = tracks[0]
            return {
                'currentTrack': current_track,
                'queue': queue,
                'currentPlaylistId': (
                    current_playlist_id if current_track and current.get('queue') else playlist_id
                ),
                'isPlaying': is_playing,
                'positionMs': position_ms,
            }

        if action.type == 'pause_resume':
            mode = str(payload.get('mode') or '').strip().lower()
            if mode == 'pause':
                is_playing = False
            elif mode == 'resume':
                is_playing = True
            else:
                is_playing = not is_playing
            return {
                'currentTrack': current_track,
                'queue': queue,
                'currentPlaylistId': current_playlist_id,
                'isPlaying': is_playing,
                'positionMs': position_ms,
            }

        if action.type == 'skip':
            if len(queue) > 1:
                next_queue = queue[1:]
                next_track = next_queue[0].get('track') if isinstance(next_queue[0], dict) else None
                return {
                    'currentTrack': next_track,
                    'queue': next_queue,
                    'currentPlaylistId': current_playlist_id,
                    'isPlaying': True,
                    'positionMs': 0,
                }
            return {
                'currentTrack': None,
                'queue': [],
                'currentPlaylistId': None,
                'isPlaying': False,
                'positionMs': 0,
            }

        return {}

    def load_netease_intelligence(self, request: MusicIntelligenceRequestDto) -> NeteaseOpenApiResult:
        state = self.store.load_state()
        fallback_playlist_id = str(state.get('neteaseLikedPlaylistOpaqueId') or state.get('neteaseLikedPlaylistEncryptedId') or '').strip()
        song_payload = request.song.model_dump(exclude_none=True)
        playlist_payload = None if request.playlist is None else request.playlist.model_dump(exclude_none=True)
        last_error: Exception | None = None
        retry_delays = [1, 2, 3, 4, 5]
        max_attempts = len(retry_delays) + 1
        for attempt in range(1, max_attempts + 1):
            try:
                _LOG.info(
                    '[music.intelligence.request] attempt=%s/%s song=%s sourceTrackId=%s opaqueTrackId=%s playlistId=%s fallbackPlaylistId=%s mode=%s count=%s',
                    attempt,
                    max_attempts,
                    song_payload.get('trackId') or song_payload.get('id'),
                    song_payload.get('sourceTrackId'),
                    song_payload.get('opaqueTrackId'),
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
                    '[music.intelligence.success] attempt=%s/%s trackCount=%s rawTrackCount=%s dedupTrackCount=%s playlistEncryptedId=%s songEncryptedId=%s fallbackUsed=%s source=%s',
                    attempt,
                    max_attempts,
                    len(result.tracks),
                    result.raw_track_count,
                    result.dedup_track_count,
                    result.playlist_encrypted_id,
                    result.song_encrypted_id,
                    result.fallback_used,
                    result.source,
                )
                patch: dict[str, object] = {}
                if result.playlist_encrypted_id and result.playlist_encrypted_id != fallback_playlist_id:
                    patch['neteaseLikedPlaylistOpaqueId'] = result.playlist_encrypted_id
                if patch:
                    self.store.save_state(patch)
                return result
            except NeteaseOpenApiError as exc:
                last_error = exc
                will_retry = attempt < max_attempts
                next_delay = retry_delays[attempt - 1] if will_retry else None
                _LOG.warning(
                    '[music.intelligence.failure] attempt=%s/%s willRetry=%s nextDelaySeconds=%s song=%s sourceTrackId=%s opaqueTrackId=%s playlistId=%s fallbackPlaylistId=%s error=%s',
                    attempt,
                    max_attempts,
                    will_retry,
                    next_delay,
                    song_payload.get('trackId') or song_payload.get('id'),
                    song_payload.get('sourceTrackId'),
                    song_payload.get('opaqueTrackId'),
                    None if playlist_payload is None else playlist_payload.get('playlistId'),
                    fallback_playlist_id or None,
                    str(exc),
                )
                if not will_retry:
                    break
                sleep(next_delay)
        assert last_error is not None
        raise last_error

    def start_netease_cli_login(self) -> MusicCliLoginSessionDto:
        return self.netease_openapi.start_cli_login()

    def get_netease_cli_login_status(self) -> MusicCliLoginSessionDto:
        return self.netease_openapi.get_cli_login_status()

    def sync_netease_favorite_playlist(self) -> dict:
        playlist = self.netease_openapi.get_favorite_playlist()
        encrypted_id = str(playlist.get('id') or '').strip()
        original_id = str(playlist.get('originalId') or '').strip()
        patch = {}
        if encrypted_id:
            patch['neteaseLikedPlaylistOpaqueId'] = encrypted_id
        if original_id:
            patch['neteaseLikedPlaylistOriginalId'] = original_id
        if patch:
            self.store.save_state(patch)
        return playlist

    def load_netease_fm(self, *, limit: int = 3) -> list:
        return self.netease_openapi.get_fm_tracks(limit=limit)

    def load_netease_daily(self) -> list:
        return self.netease_openapi.get_daily_tracks()

    def trash_netease_fm_track(self, request: MusicFmTrashRequestDto) -> None:
        self.netease_openapi.trash_fm_track(
            source_track_id=request.sourceTrackId,
            play_time_seconds=request.playTimeSeconds,
        )

    def list_providers(self) -> list[MusicProviderDto]:
        return [
            MusicProviderDto(
                providerId='netease',
                displayName='网易云音乐',
                authMode='client',
                supportedAuthMethods=['cookieImport', 'qrCode', 'cliLogin'],
                supportsSearch=True,
                supportsLyrics=True,
                supportsResolve=True,
                supportsPlaylistLookup=True,
                supportsUserLibrary=True,
                notes='优先平台；已接搜索、播放解析、歌单读取与 Cookie / 二维码登录 / 官方 CLI 登录。',
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
