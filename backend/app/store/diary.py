from __future__ import annotations

import json
import time
import uuid
from typing import Any

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


def _new_id() -> str:
    return f"diary_{uuid.uuid4().hex[:12]}"


class DiaryStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS diary_entries (
                    id TEXT PRIMARY KEY,
                    agent_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    content TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT '',
                    summary_json TEXT NOT NULL DEFAULT '{}',
                    error TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    generated_at REAL
                );

                CREATE UNIQUE INDEX IF NOT EXISTS idx_diary_entries_agent_date
                ON diary_entries(agent_id, date);
                """
            )
            conn.commit()

    def _row_to_entry(self, row) -> dict:
        summary_raw = row["summary_json"] or "{}"
        try:
            summary = json.loads(summary_raw)
        except Exception:
            summary = {}
        if not isinstance(summary, dict):
            summary = {}
        return {
            "id": row["id"],
            "agentId": row["agent_id"],
            "date": row["date"],
            "title": row["title"],
            "content": row["content"],
            "status": row["status"],
            "source": row["source"],
            "summary": summary,
            "error": row["error"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "generatedAt": row["generated_at"],
        }

    def list_entries(self, *, agent_id: str = "alice", limit: int = 30) -> list[dict]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                """
                SELECT *
                FROM diary_entries
                WHERE agent_id=?
                ORDER BY date DESC
                LIMIT ?
                """,
                (str(agent_id or "alice"), max(1, min(int(limit or 30), 200))),
            ).fetchall()
            return [self._row_to_entry(row) for row in rows]

    def get_entry(self, *, agent_id: str, date: str) -> dict | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT * FROM diary_entries WHERE agent_id=? AND date=? LIMIT 1",
                (str(agent_id or "alice"), str(date or "")),
            ).fetchone()
            return self._row_to_entry(row) if row is not None else None

    def delete_entry(self, *, agent_id: str, date: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            cursor = conn.execute(
                "DELETE FROM diary_entries WHERE agent_id=? AND date=?",
                (str(agent_id or "alice"), str(date or "")),
            )
            conn.commit()
            return int(cursor.rowcount or 0) > 0

    def upsert_entry(
        self,
        *,
        agent_id: str,
        date: str,
        title: str = "",
        content: str = "",
        status: str,
        source: str = "",
        summary: dict[str, Any] | None = None,
        error: str = "",
        generated_at: float | None = None,
    ) -> dict:
        self.ensure_schema()
        now = _now()
        existing = self.get_entry(agent_id=agent_id, date=date)
        entry_id = str((existing or {}).get("id") or _new_id())
        created_at = float((existing or {}).get("createdAt") or now)
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO diary_entries(
                    id, agent_id, date, title, content, status, source,
                    summary_json, error, created_at, updated_at, generated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(agent_id, date) DO UPDATE SET
                    title=excluded.title,
                    content=excluded.content,
                    status=excluded.status,
                    source=excluded.source,
                    summary_json=excluded.summary_json,
                    error=excluded.error,
                    updated_at=excluded.updated_at,
                    generated_at=excluded.generated_at
                """,
                (
                    entry_id,
                    str(agent_id or "alice"),
                    str(date or ""),
                    str(title or ""),
                    str(content or ""),
                    str(status or "draft"),
                    str(source or ""),
                    json.dumps(summary or {}, ensure_ascii=False),
                    str(error or ""),
                    created_at,
                    now,
                    generated_at,
                ),
            )
            conn.commit()
        return self.get_entry(agent_id=agent_id, date=date) or {}
