from __future__ import annotations

import json
import time
from typing import Any

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


class TodoStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS todo_state (
                    key TEXT PRIMARY KEY,
                    snapshot_json TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
            )
            conn.commit()

    def load_snapshot(self) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT snapshot_json, revision, updated_at FROM todo_state WHERE key='global' LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        try:
            snapshot = json.loads(row["snapshot_json"] or "{}")
        except Exception:
            snapshot = {}
        if not isinstance(snapshot, dict):
            snapshot = {}
        return {
            "snapshot": snapshot,
            "revision": int(row["revision"] or 0),
            "updatedAt": float(row["updated_at"] or 0.0),
        }

    def save_snapshot(self, snapshot: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        current = self.load_snapshot()
        next_revision = int((current or {}).get("revision") or 0) + 1
        updated_at = _now()
        snapshot_json = json.dumps(snapshot or {}, ensure_ascii=False)
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO todo_state (key, snapshot_json, revision, updated_at)
                VALUES ('global', ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  snapshot_json=excluded.snapshot_json,
                  revision=excluded.revision,
                  updated_at=excluded.updated_at
                """,
                (snapshot_json, next_revision, updated_at),
            )
            conn.commit()
        return {
            "snapshot": snapshot,
            "revision": next_revision,
            "updatedAt": updated_at,
        }
