from __future__ import annotations

from dataclasses import dataclass

from ..music_api_models import MusicAiPlaylistDraftDto, MusicCommandRequest, MusicProviderDto, MusicStateDto, MusicStatePatchDto
from ..store import MusicStore


@dataclass(slots=True)
class MusicStateResult:
    payload: MusicStateDto


@dataclass(slots=True)
class MusicAiPlaylistResult:
    payload: MusicAiPlaylistDraftDto | None


class MusicService:
    def __init__(self, *, store: MusicStore | None = None):
        self.store = store or MusicStore()

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

    def save_latest_ai_playlist(self, playlist: MusicAiPlaylistDraftDto) -> MusicAiPlaylistResult:
        saved = self.store.save_state(
            {'latestAiPlaylist': playlist.model_dump(exclude_none=True)}
        )
        payload = saved.get('latestAiPlaylist')
        if not isinstance(payload, dict):
            return MusicAiPlaylistResult(payload=None)
        return MusicAiPlaylistResult(
            payload=MusicAiPlaylistDraftDto.model_validate(payload)
        )

    def build_command_event(self, command: MusicCommandRequest) -> dict:
        return command.model_dump(exclude_none=True)

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
