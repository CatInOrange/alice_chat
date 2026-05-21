from __future__ import annotations

import json
import time
import uuid
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from .db import DbConfig, connect, migrate

_TZ = ZoneInfo("Asia/Shanghai")


def _now() -> float:
    return time.time()


def _new_id() -> str:
    return f"music_play_{uuid.uuid4().hex[:12]}"


class MusicHistoryStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS music_play_history (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    played_at REAL NOT NULL,
                    track_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL DEFAULT '',
                    album TEXT NOT NULL DEFAULT '',
                    duration_ms INTEGER NOT NULL DEFAULT 0,
                    provider_id TEXT NOT NULL DEFAULT '',
                    source_track_id TEXT NOT NULL DEFAULT '',
                    playlist_id TEXT NOT NULL DEFAULT '',
                    source TEXT NOT NULL DEFAULT '',
                    meta_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_music_play_history_date_time
                ON music_play_history(date, played_at);

                CREATE INDEX IF NOT EXISTS idx_music_play_history_track_time
                ON music_play_history(track_id, played_at);
                """
            )
            conn.commit()

    def record_play(
        self,
        *,
        track: dict[str, Any],
        played_at: float | None = None,
        playlist_id: str = "",
        source: str = "",
        meta: dict[str, Any] | None = None,
    ) -> dict | None:
        self.ensure_schema()
        if not isinstance(track, dict):
            return None
        track_id = str(track.get("id") or "").strip()
        title = str(track.get("title") or "").strip()
        if not track_id and not title:
            return None
        ts = float(played_at or _now())
        date = datetime.fromtimestamp(ts, _TZ).date().isoformat()
        provider_id = str(
            track.get("preferredSourceId")
            or (track.get("cachedPlayback") or {}).get("providerId")
            or ""
        ).strip()
        source_track_id = str(
            track.get("sourceTrackId")
            or (track.get("cachedPlayback") or {}).get("sourceTrackId")
            or ""
        ).strip()
        with connect(self.db) as conn:
            recent = conn.execute(
                """
                SELECT *
                FROM music_play_history
                WHERE track_id=? AND ABS(played_at - ?) < 60
                ORDER BY played_at DESC
                LIMIT 1
                """,
                (track_id or title, ts),
            ).fetchone()
            if recent is not None:
                return self._row_to_item(recent)
            conn.execute(
                """
                INSERT INTO music_play_history(
                    id, date, played_at, track_id, title, artist, album,
                    duration_ms, provider_id, source_track_id, playlist_id,
                    source, meta_json, created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    _new_id(),
                    date,
                    ts,
                    track_id or title,
                    title,
                    str(track.get("artist") or ""),
                    str(track.get("album") or ""),
                    int(track.get("durationMs") or 0),
                    provider_id,
                    source_track_id,
                    str(playlist_id or ""),
                    str(source or ""),
                    json.dumps(meta or {}, ensure_ascii=False),
                    _now(),
                ),
            )
            conn.commit()
            row = conn.execute(
                """
                SELECT *
                FROM music_play_history
                WHERE track_id=? AND played_at=?
                LIMIT 1
                """,
                (track_id or title, ts),
            ).fetchone()
        return self._row_to_item(row) if row is not None else None

    def list_day(self, *, date: str, limit: int = 200) -> list[dict]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                """
                SELECT *
                FROM music_play_history
                WHERE date=?
                ORDER BY played_at ASC, id ASC
                LIMIT ?
                """,
                (str(date or ""), max(1, min(int(limit or 200), 500))),
            ).fetchall()
        return [self._row_to_item(row) for row in rows]

    def _row_to_item(self, row) -> dict:
        try:
            meta = json.loads(row["meta_json"] or "{}")
        except Exception:
            meta = {}
        if not isinstance(meta, dict):
            meta = {}
        return {
            "id": row["id"],
            "date": row["date"],
            "playedAt": row["played_at"],
            "trackId": row["track_id"],
            "title": row["title"],
            "artist": row["artist"],
            "album": row["album"],
            "durationMs": row["duration_ms"],
            "providerId": row["provider_id"],
            "sourceTrackId": row["source_track_id"],
            "playlistId": row["playlist_id"],
            "source": row["source"],
            "meta": meta,
            "createdAt": row["created_at"],
        }
