from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

from ..music_api_models import MusicCliLoginSessionDto, MusicTrackDto


class NeteaseOpenApiError(RuntimeError):
    pass


@dataclass(slots=True)
class NeteaseOpenApiResult:
    tracks: list[MusicTrackDto]
    playlist_encrypted_id: str
    song_encrypted_id: str
    fallback_used: bool = False
    raw_track_count: int = 0
    dedup_track_count: int = 0
    source: str = 'unknown'


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
        playlist_encrypted_id, fallback_used = self._resolve_effective_playlist_encrypted_id(
            playlist,
            fallback_playlist_id,
        )
        playlist_original_id = self._resolve_effective_playlist_original_id(playlist)
        encrypted_song_id = self._resolve_song_encrypted_id(song, playlist_encrypted_id)
        if not encrypted_song_id:
            raise NeteaseOpenApiError('当前歌曲缺少网易云官方加密ID')
        if not playlist_encrypted_id and not playlist_original_id:
            raise NeteaseOpenApiError('缺少可用的网易云推荐歌单上下文')

        count_value = max(1, min(count, 150))
        cli_error: NeteaseOpenApiError | None = None
        payload: dict[str, Any] | None = None
        source = 'http-api'
        try:
            payload = self._run_intelligence_via_cli(
                encrypted_playlist_id=playlist_encrypted_id,
                encrypted_song_id=encrypted_song_id,
                count=count_value,
                mode=mode,
            )
            source = 'ncm-cli'
        except NeteaseOpenApiError as exc:
            cli_error = exc
            if not self._is_cli_command_missing(exc):
                raise
            payload = self._run_intelligence_via_http_api(
                playlist_original_id=playlist_original_id,
                source_track_id=self._first_non_empty(
                    song.get('sourceTrackId'),
                    song.get('trackId'),
                    song.get('id'),
                ),
                start_track_id=self._first_non_empty(song.get('sourceTrackId')),
            )

        data = payload.get('data') if isinstance(payload, dict) else None
        if not isinstance(data, list):
            raise NeteaseOpenApiError('网易云心动模式返回为空')
        raw_track_count = len([item for item in data if isinstance(item, dict)])
        tracks = [self._track_from_openapi_item(item) for item in data if isinstance(item, dict)]
        tracks = [item for item in tracks if item is not None]
        deduped: list[MusicTrackDto] = []
        seen: set[str] = set()
        for track in tracks:
            key = str(track.sourceTrackId or track.id or '').strip()
            if key and key in seen:
                continue
            if key:
                seen.add(key)
            deduped.append(track)
        if not deduped:
            if cli_error is not None and source == 'http-api':
                raise NeteaseOpenApiError(
                    f'网易云心动模式暂时没有返回可播放歌曲（CLI回退原因: {cli_error}）'
                )
            raise NeteaseOpenApiError('网易云心动模式暂时没有返回可播放歌曲')
        return NeteaseOpenApiResult(
            tracks=deduped,
            playlist_encrypted_id=playlist_encrypted_id,
            song_encrypted_id=encrypted_song_id,
            fallback_used=fallback_used,
            raw_track_count=raw_track_count,
            dedup_track_count=len(deduped),
            source=source,
        )

    def start_cli_login(self) -> MusicCliLoginSessionDto:
        self._ensure_cli_runtime()
        payload = self._run_json_allow_missing_login('login')
        if payload.get('success') is not True:
            message = self._first_non_empty(payload.get('message'), payload.get('msg')) or '网易云 CLI 登录启动失败'
            raise NeteaseOpenApiError(message)
        login_url = self._first_non_empty(payload.get('clickableUrl'), payload.get('qrCodeUrl'))
        return MusicCliLoginSessionDto(
            providerId='netease',
            loginUrl=login_url or None,
            clickableUrl=login_url or None,
            message=self._first_non_empty(payload.get('message')) or '请打开链接完成网易云官方授权登录',
            loginValid=False,
        )

    def get_cli_login_status(self) -> MusicCliLoginSessionDto:
        self._ensure_cli_runtime()
        payload = self._run_json_allow_missing_login('login', '--check')
        success = payload.get('success') is True
        return MusicCliLoginSessionDto(
            providerId='netease',
            message=self._first_non_empty(payload.get('message'), payload.get('msg')) or ('CLI 登录有效' if success else 'CLI 未登录'),
            loginValid=success,
        )

    def get_favorite_playlist(self) -> dict[str, Any]:
        self._ensure_ready()
        payload = self._run_json('user', 'favorite')
        data = payload.get('data')
        if not isinstance(data, dict):
            raise NeteaseOpenApiError('未获取到网易云喜欢歌单')
        return data

    def get_fm_tracks(self, *, limit: int = 3) -> list[MusicTrackDto]:
        payload = self._run_cookie_json_request(
            'https://music.163.com/api/radio/get',
            data={
                'limit': str(max(1, min(limit, 20))),
            },
            error_prefix='加载网易云私人 FM 失败',
        )
        data = payload.get('data')
        if not isinstance(data, list):
            raise NeteaseOpenApiError('网易云私人 FM 返回为空')
        tracks = [self._track_from_fm_item(item) for item in data if isinstance(item, dict)]
        tracks = [item for item in tracks if item is not None]
        if not tracks:
            raise NeteaseOpenApiError('网易云私人 FM 暂时没有返回可播放歌曲')
        return tracks

    def get_daily_tracks(self) -> list[MusicTrackDto]:
        payload = self._run_cookie_json_request(
            'https://music.163.com/api/discovery/recommend/songs',
            error_prefix='加载网易云每日推荐失败',
        )
        data = payload.get('recommend')
        if not isinstance(data, list):
            raise NeteaseOpenApiError('网易云每日推荐返回为空')
        tracks = [self._track_from_daily_item(item) for item in data if isinstance(item, dict)]
        tracks = [item for item in tracks if item is not None]
        if not tracks:
            raise NeteaseOpenApiError('网易云每日推荐暂时没有返回可播放歌曲')
        return tracks

    def _resolve_song_encrypted_id(self, song: dict[str, Any], playlist_encrypted_id: str) -> str:
        encrypted = self._normalize_encrypted_id(
            self._first_non_empty(
                song.get('opaqueTrackId'),
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

    def _resolve_effective_playlist_original_id(self, playlist: dict[str, Any] | None) -> str:
        if not isinstance(playlist, dict):
            return ''
        return self._first_non_empty(
            playlist.get('sourcePlaylistId'),
            playlist.get('originalPlaylistId'),
            playlist.get('playlistId'),
        )

    def _resolve_playlist_encrypted_id(self, playlist: dict[str, Any] | None) -> str:
        if not isinstance(playlist, dict):
            return ''
        encrypted = self._normalize_encrypted_id(
            self._first_non_empty(
                playlist.get('opaquePlaylistId'),
                playlist.get('encryptedPlaylistId'),
            )
        )
        if encrypted:
            return encrypted
        return ''

    def _lookup_song_encrypted_id(self, *, playlist_encrypted_id: str, source_track_id: str) -> str:
        normalized_playlist_id = self._normalize_encrypted_id(playlist_encrypted_id)
        normalized_source_track_id = str(source_track_id or '').strip()
        if not normalized_playlist_id or not normalized_source_track_id:
            return ''
        payload = self._run_json(
            'playlist',
            'tracks',
            '--playlistId',
            normalized_playlist_id,
            '--limit',
            '500',
        )
        data = payload.get('data')
        if not isinstance(data, list):
            return ''
        for item in data:
            if not isinstance(item, dict):
                continue
            original_id = str(item.get('originalId') or '').strip()
            if original_id != normalized_source_track_id:
                continue
            return self._normalize_encrypted_id(self._first_non_empty(item.get('id')))
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
        source_track_id = original_id or track_id or ''
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

    def _track_from_daily_item(self, item: dict[str, Any]) -> MusicTrackDto | None:
        track = self._track_from_openapi_item(item)
        if track is None:
            return None
        album_name = track.album or '网易云音乐'
        return track.model_copy(
            update={
                'description': f'每日推荐 · {album_name}',
                'artworkTone': 'ocean',
            }
        )

    def _run_intelligence_via_cli(
        self,
        *,
        encrypted_playlist_id: str,
        encrypted_song_id: str,
        count: int,
        mode: str,
    ) -> dict[str, Any]:
        return self._run_json(
            'recommend',
            'heartbeat',
            '--playlistId',
            encrypted_playlist_id,
            '--songId',
            encrypted_song_id,
            '--count',
            str(count),
            '--type',
            mode or 'fromPlayAll',
        )

    def _run_intelligence_via_http_api(
        self,
        *,
        playlist_original_id: str,
        source_track_id: str,
        start_track_id: str,
    ) -> dict[str, Any]:
        normalized_playlist_id = str(playlist_original_id or '').strip()
        normalized_song_id = str(source_track_id or '').strip()
        normalized_start_track_id = str(start_track_id or '').strip()
        if not normalized_playlist_id:
            raise NeteaseOpenApiError('缺少可用的网易云原始歌单ID')
        if not normalized_song_id:
            raise NeteaseOpenApiError('缺少可用的网易云原始歌曲ID')
        query = {
            'pid': normalized_playlist_id,
            'id': normalized_song_id,
        }
        if normalized_start_track_id:
            query['sid'] = normalized_start_track_id
        url = f"https://music.163.com/api/playmode/intelligence/list?{urlencode(query)}"
        payload = self._run_cookie_json_request(
            url,
            error_prefix='加载网易云心动模式失败',
        )
        if not isinstance(payload, dict):
            raise NeteaseOpenApiError('网易云心动模式返回为空')
        return payload

    def _run_cookie_json_request(
        self,
        url: str,
        *,
        data: dict[str, str] | None = None,
        error_prefix: str,
    ) -> dict[str, Any]:
        cookie_header = self._load_cookie_header()
        body: bytes | None = None
        headers = {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14; AliceChat) AppleWebKit/537.36',
            'Accept': 'application/json, text/plain, */*',
            'Referer': 'https://music.163.com/',
            'Origin': 'https://music.163.com',
            'Cookie': cookie_header,
        }
        if data:
            body = urlencode(data).encode('utf-8')
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        request = Request(url, data=body, headers=headers)
        try:
            with urlopen(request, timeout=20) as resp:
                text = resp.read().decode('utf-8', 'ignore')
        except HTTPError as exc:
            detail = exc.read().decode('utf-8', 'ignore') if hasattr(exc, 'read') else str(exc)
            raise NeteaseOpenApiError(f'{error_prefix}: {detail or exc}') from exc
        except URLError as exc:
            raise NeteaseOpenApiError(f'{error_prefix}: {exc}') from exc
        except Exception as exc:
            raise NeteaseOpenApiError(f'{error_prefix}: {exc}') from exc
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise NeteaseOpenApiError(f'{error_prefix}，响应解析失败: {exc}') from exc
        if not isinstance(payload, dict):
            raise NeteaseOpenApiError(f'{error_prefix}，返回为空')
        code = payload.get('code')
        if code not in (None, 200):
            message = self._first_non_empty(payload.get('message'), payload.get('msg')) or error_prefix
            raise NeteaseOpenApiError(message)
        return payload

    def _load_cookie_header(self) -> str:
        cookie_path = self._cli_home / '.netease_cookie'
        if not cookie_path.exists():
            raise NeteaseOpenApiError(f'网易云 Cookie 缺失：{cookie_path}')
        text = cookie_path.read_text(encoding='utf-8', errors='ignore').strip()
        if not text:
            raise NeteaseOpenApiError('网易云 Cookie 为空')
        return text

    def _is_cli_command_missing(self, error: NeteaseOpenApiError) -> bool:
        message = str(error or '')
        return "unknown command 'recommend'" in message or "unknown command 'playlist'" in message or "unknown command 'user'" in message

    def _ensure_cli_runtime(self) -> None:
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

    def _ensure_ready(self) -> None:
        self._ensure_cli_runtime()
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

    def _run_json_allow_missing_login(self, *args: str) -> dict[str, Any]:
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
        text = (process.stdout or process.stderr or '').strip()
        if not text:
            raise NeteaseOpenApiError('网易云 CLI 没有返回结果')
        start = text.find('{')
        if start < 0:
            raise NeteaseOpenApiError(self._extract_error(text))
        try:
            payload = json.loads(text[start:])
        except json.JSONDecodeError as exc:
            raise NeteaseOpenApiError(f'网易云 CLI 响应解析失败: {exc}') from exc
        return payload if isinstance(payload, dict) else {}

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
