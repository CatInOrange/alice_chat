from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..music_api_models import MusicTrackDto


class NeteaseOpenApiError(RuntimeError):
    pass


@dataclass(slots=True)
class NeteaseOpenApiResult:
    tracks: list[MusicTrackDto]
    playlist_encrypted_id: str
    song_encrypted_id: str
    fallback_used: bool = False


class NeteaseOpenApiService:
    DEFAULT_CLI_HOME = Path('/root/.openclaw/AliceChat/data/netease-openapi')
    DEFAULT_CLI_PACKAGE_DIR = Path('/root/.openclaw/AliceChat/tools/ncm-cli/package')

    def __init__(self, config: dict):
        self._config = config or {}
        self._cli_home = Path(
            os.environ.get('ALICECHAT_NETEASE_OPENAPI_HOME') or self.DEFAULT_CLI_HOME
        ).expanduser()
        self._cli_package_dir = Path(
            os.environ.get('ALICECHAT_NETEASE_OPENAPI_CLI_DIR') or self.DEFAULT_CLI_PACKAGE_DIR
        ).expanduser()
        self._cli_entry = self._cli_package_dir / 'dist' / 'index.js'

    def get_intelligence_tracks(
        self,
        *,
        song: dict[str, Any],
        playlist: dict[str, Any] | None,
        fallback_playlist_id: str | None,
        count: int,
        mode: str,
    ) -> NeteaseOpenApiResult:
        self._ensure_ready()
        encrypted_playlist_id, fallback_used = self._resolve_effective_playlist_encrypted_id(
            playlist,
            fallback_playlist_id,
        )
        encrypted_song_id = self._resolve_song_encrypted_id(song, encrypted_playlist_id)
        if not encrypted_song_id:
            raise NeteaseOpenApiError('当前歌曲缺少网易云官方加密ID')
        if not encrypted_playlist_id:
            raise NeteaseOpenApiError('缺少可用的网易云推荐歌单上下文')
        payload = self._run_json(
            'recommend',
            'heartbeat',
            '--playlistId',
            encrypted_playlist_id,
            '--songId',
            encrypted_song_id,
            '--count',
            str(max(1, min(count, 150))),
            '--type',
            mode or 'fromPlayAll',
        )
        data = payload.get('data')
        if not isinstance(data, list):
            raise NeteaseOpenApiError('网易云心动模式返回为空')
        tracks = [self._track_from_openapi_item(item) for item in data if isinstance(item, dict)]
        tracks = [item for item in tracks if item is not None]
        if not tracks:
            raise NeteaseOpenApiError('网易云心动模式暂时没有返回可播放歌曲')
        return NeteaseOpenApiResult(
            tracks=tracks,
            playlist_encrypted_id=encrypted_playlist_id,
            song_encrypted_id=encrypted_song_id,
            fallback_used=fallback_used,
        )

    def get_favorite_playlist(self) -> dict[str, Any]:
        self._ensure_ready()
        payload = self._run_json('user', 'favorite')
        data = payload.get('data')
        if not isinstance(data, dict):
            raise NeteaseOpenApiError('未获取到网易云喜欢歌单')
        return data

    def get_fm_tracks(self, *, limit: int = 3) -> list[MusicTrackDto]:
        self._ensure_ready()
        payload = self._run_json(
            'recommend',
            'fm',
            '--limit',
            str(max(1, min(limit, 20))),
        )
        data = payload.get('data')
        if not isinstance(data, list):
            raise NeteaseOpenApiError('网易云私人 FM 返回为空')
        tracks = [self._track_from_fm_item(item) for item in data if isinstance(item, dict)]
        tracks = [item for item in tracks if item is not None]
        if not tracks:
            raise NeteaseOpenApiError('网易云私人 FM 暂时没有返回可播放歌曲')
        return tracks

    def _resolve_song_encrypted_id(self, song: dict[str, Any], playlist_encrypted_id: str) -> str:
        encrypted = self._normalize_encrypted_id(
            self._first_non_empty(
                song.get('encryptedSourceTrackId'),
                song.get('encryptedTrackId'),
                song.get('sourceEncryptedId'),
            )
        )
        if encrypted:
            return encrypted
        provider = str(song.get('providerId') or '').strip()
        if provider and provider != 'netease':
            raise NeteaseOpenApiError('当前歌曲不是网易云来源，无法开启官方心动模式')
        source_track_id = self._first_non_empty(
            song.get('sourceTrackId'),
            song.get('trackId'),
            song.get('id'),
        )
        if source_track_id and playlist_encrypted_id:
            encrypted = self._lookup_song_encrypted_id(
                playlist_encrypted_id=playlist_encrypted_id,
                source_track_id=source_track_id,
            )
            if encrypted:
                return encrypted
        raise NeteaseOpenApiError('当前歌曲还没有网易云官方加密ID')

    def _resolve_effective_playlist_encrypted_id(
        self,
        playlist: dict[str, Any] | None,
        fallback_playlist_id: str | None,
    ) -> tuple[str, bool]:
        playlist_encrypted_id = self._resolve_playlist_encrypted_id(playlist)
        if playlist_encrypted_id:
            return playlist_encrypted_id, False
        fallback_encrypted_id = self._normalize_encrypted_id(fallback_playlist_id)
        if fallback_encrypted_id:
            return fallback_encrypted_id, True
        return '', False

    def _resolve_playlist_encrypted_id(self, playlist: dict[str, Any] | None) -> str:
        if not isinstance(playlist, dict):
            return ''
        encrypted = self._normalize_encrypted_id(
            self._first_non_empty(
                playlist.get('encryptedPlaylistId'),
                playlist.get('encryptedSourcePlaylistId'),
            )
        )
        if encrypted:
            return encrypted
        return ''

    def _lookup_song_encrypted_id(self, *, playlist_encrypted_id: str, source_track_id: str) -> str:
        offset = 0
        limit = 200
        normalized_source_track_id = str(source_track_id or '').strip()
        if not normalized_source_track_id:
            return ''
        for _ in range(5):
            payload = self._run_json(
                'playlist',
                'tracks',
                '--playlistId',
                playlist_encrypted_id,
                '--limit',
                str(limit),
                '--offset',
                str(offset),
            )
            data = payload.get('data')
            if not isinstance(data, list) or not data:
                return ''
            for item in data:
                if not isinstance(item, dict):
                    continue
                original_id = self._first_non_empty(item.get('originalId'))
                item_id = self._first_non_empty(item.get('id'))
                if original_id == normalized_source_track_id:
                    return self._normalize_encrypted_id(item_id)
                if item_id == normalized_source_track_id:
                    return self._normalize_encrypted_id(item_id)
            if len(data) < limit:
                return ''
            offset += limit
        return ''

    def _track_from_openapi_item(self, item: dict[str, Any]) -> MusicTrackDto | None:
        track_id = self._first_non_empty(item.get('id'))
        original_id = self._first_non_empty(item.get('originalId'))
        title = self._first_non_empty(item.get('name'))
        if not title:
            return None
        artists = item.get('artists') or item.get('fullArtists') or []
        artist_names = []
        if isinstance(artists, list):
            for entry in artists:
                if isinstance(entry, dict):
                    name = self._first_non_empty(entry.get('name'))
                    if name:
                        artist_names.append(name)
        album = item.get('album') if isinstance(item.get('album'), dict) else {}
        album_name = self._first_non_empty(album.get('name')) or '网易云音乐'
        cover = self._first_non_empty(item.get('coverImgUrl'))
        duration_ms = item.get('duration')
        if not isinstance(duration_ms, int):
            duration_ms = int(duration_ms or 0)
        source_track_id = original_id or ''
        return MusicTrackDto(
            id=f'netease:{source_track_id or track_id or title}',
            title=title,
            artist=' / '.join(artist_names) if artist_names else '未知歌手',
            album=album_name,
            durationMs=duration_ms,
            category='网易云音乐',
            description=f'官方心动模式推荐 · {album_name}',
            artworkTone='rose',
            artworkUrl=cover or None,
            preferredSourceId='netease',
            sourceTrackId=source_track_id or None,
            encryptedSourceTrackId=track_id or None,
            isFavorite=bool(item.get('liked') is True),
        )

    def _track_from_fm_item(self, item: dict[str, Any]) -> MusicTrackDto | None:
        track = self._track_from_openapi_item(item)
        if track is None:
            return None
        album_name = track.album or '网易云音乐'
        return track.model_copy(
            update={
                'description': f'私人 FM · {album_name}',
                'artworkTone': 'sunset',
            }
        )

    def _ensure_ready(self) -> None:
        if not self._cli_package_dir.exists():
            raise NeteaseOpenApiError(
                f'未找到 ncm-cli 运行目录：{self._cli_package_dir}。'
                f'当前约定 CLI 程序目录应为 {self.DEFAULT_CLI_PACKAGE_DIR}'
            )
        if not self._cli_entry.exists():
            raise NeteaseOpenApiError(
                f'ncm-cli 入口文件缺失：{self._cli_entry}。'
                '请确认 CLI 包已完整解压到约定目录'
            )
        if not self._cli_home.exists():
            raise NeteaseOpenApiError(
                f'未找到网易云官方数据目录：{self._cli_home}。'
                f'当前约定 HOME 目录应为 {self.DEFAULT_CLI_HOME}'
            )
        credentials_path = self._cli_home / '.config' / 'ncm-cli' / 'credentials.enc.json'
        tokens_path = self._cli_home / '.config' / 'ncm-cli' / 'tokens.enc.json'
        if not credentials_path.exists():
            raise NeteaseOpenApiError(
                f'网易云官方凭据未配置：{credentials_path} 不存在。'
                '请先在约定 HOME 目录完成 ncm-cli 配置'
            )
        if not tokens_path.exists():
            raise NeteaseOpenApiError(
                f'网易云官方登录态缺失：{tokens_path} 不存在。'
                '请先在约定 HOME 目录完成授权登录'
            )

    def _run_json(self, *args: str) -> dict[str, Any]:
        env = dict(os.environ)
        env['HOME'] = str(self._cli_home)
        process = subprocess.run(
            ['node', 'dist/index.js', *args, '--output', 'json'],
            cwd=str(self._cli_package_dir),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if process.returncode != 0:
            raise NeteaseOpenApiError(self._extract_error(process.stderr or process.stdout))
        text = (process.stdout or '').strip()
        if not text:
            raise NeteaseOpenApiError('网易云官方接口返回为空')
        start = text.find('{')
        if start < 0:
            raise NeteaseOpenApiError(self._extract_error(text))
        try:
            payload = json.loads(text[start:])
        except json.JSONDecodeError as exc:
            raise NeteaseOpenApiError(f'网易云官方响应解析失败: {exc}') from exc
        if payload.get('code') not in (None, 200):
            message = self._first_non_empty(payload.get('message'), payload.get('msg')) or '网易云官方接口调用失败'
            raise NeteaseOpenApiError(message)
        return payload

    def _extract_error(self, raw: str) -> str:
        text = (raw or '').strip()
        if not text:
            return '网易云官方接口调用失败'
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        return lines[-1] if lines else text

    def _normalize_encrypted_id(self, value: Any) -> str:
        text = str(value or '').strip()
        if not text:
            return ''
        if len(text) < 16:
            return ''
        if not all(ch.isdigit() or ('A' <= ch <= 'F') or ('a' <= ch <= 'f') for ch in text):
            return ''
        if text.isdigit():
            return ''
        return text.upper()

    def _first_non_empty(self, *values: Any) -> str:
        for value in values:
            text = str(value or '').strip()
            if text:
                return text
        return ''
