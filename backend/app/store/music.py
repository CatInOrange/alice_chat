from __future__ import annotations

import json
import time
from typing import Any

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


class MusicStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS music_state (
                    key TEXT PRIMARY KEY,
                    value_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
            )
            conn.commit()

    def load_state(self) -> dict[str, Any]:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT value_json FROM music_state WHERE key='global' LIMIT 1"
            ).fetchone()
            if row is None:
                return {}
            try:
                return json.loads(row["value_json"] or "{}")
            except Exception:
                return {}

    def save_state(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        current = self.load_state()
        merged = self._merge_dicts(current, payload or {})
        updated_at = _now()
        merged["updatedAt"] = updated_at
        value_json = json.dumps(merged, ensure_ascii=False)
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO music_state (key, value_json, updated_at)
                VALUES ('global', ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  value_json=excluded.value_json,
                  updated_at=excluded.updated_at
                """,
                (value_json, updated_at),
            )
            conn.commit()
        return merged

    def _merge_dicts(self, current: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
        result = dict(current)
        for key, value in patch.items():
            if isinstance(value, dict) and isinstance(result.get(key), dict):
                result[key] = self._merge_dicts(result[key], value)
            else:
                result[key] = value
        return result
