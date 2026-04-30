from __future__ import annotations

from dataclasses import dataclass

from ..music_api_models import MusicCommandRequest, MusicProviderDto, MusicStateDto, MusicStatePatchDto
from ..store import MusicStore


@dataclass(slots=True)
class MusicStateResult:
    payload: MusicStateDto


class MusicService:
    def __init__(self, *, store: MusicStore | None = None):
        self.store = store or MusicStore()

    def load_state(self) -> MusicStateResult:
        return MusicStateResult(payload=MusicStateDto.model_validate(self.store.load_state()))

    def save_state(self, patch: MusicStatePatchDto) -> MusicStateResult:
        return MusicStateResult(payload=MusicStateDto.model_validate(self.store.save_state(patch.model_dump(exclude_none=True))))

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
                supportsPlaylistLookup=False,
                supportsUserLibrary=False,
                notes='当前阶段只收口协议；真实登录态与播放源解析计划放在 App 端实现。',
            )
        ]
