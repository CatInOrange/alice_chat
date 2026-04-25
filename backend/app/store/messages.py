from __future__ import annotations

import json
import time
import uuid

from .db import DbConfig, connect, migrate
from .models import Message


def _now() -> float:
    return time.time()


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


class MessageStore:
    """Message persistence (SQLite)."""

    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def _row_to_message(self, r) -> dict:
        return {
            "id": r["id"],
            "sessionId": r["session_id"],
            "role": r["role"],
            "text": r["text"],
            "rawText": r["raw_text"],
            "attachments": json.loads(r["attachments_json"] or "[]"),
            "source": r["source"],
            "meta": r["meta"],
            "createdAt": r["created_at"],
        }

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)

    def list_recent_messages(self, limit: int = 500) -> list[dict]:
        """Returns recent messages across sessions."""

        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM messages ORDER BY created_at DESC LIMIT ?",
                (int(limit),),
            ).fetchall()
            items = []
            for r in reversed(rows):
                items.append(
                    {
                        "id": r["id"],
                        "sessionId": r["session_id"],
                        "role": r["role"],
                        "text": r["text"],
                        "rawText": r["raw_text"],
                        "attachments": json.loads(r["attachments_json"] or "[]"),
                        "source": r["source"],
                        "meta": r["meta"],
                        "createdAt": r["created_at"],
                    }
                )
            return items

    def list_session_messages(self, session_id: str, limit: int = 2000) -> list[dict]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM messages WHERE session_id=? ORDER BY created_at ASC LIMIT ?",
                (session_id, int(limit)),
            ).fetchall()
            return [self._row_to_message(r) for r in rows]

    def list_session_messages_page(
        self,
        session_id: str,
        *,
        limit: int = 20,
        before_message_id: str | None = None,
        after_message_id: str | None = None,
    ) -> dict:
        self.ensure_schema()
        page_limit = max(1, min(int(limit or 20), 100))

        with connect(self.db) as conn:
            anchor = None
            anchor_id = str(before_message_id or after_message_id or "").strip()
            if anchor_id:
                anchor = conn.execute(
                    "SELECT id, created_at FROM messages WHERE session_id=? AND id=? LIMIT 1",
                    (session_id, anchor_id),
                ).fetchone()

            if before_message_id and anchor is not None:
                rows = conn.execute(
                    """
                    SELECT *
                    FROM messages
                    WHERE session_id=?
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    (
                        session_id,
                        float(anchor["created_at"]),
                        float(anchor["created_at"]),
                        str(anchor["id"]),
                        page_limit + 1,
                    ),
                ).fetchall()
                has_more_before = len(rows) > page_limit
                selected = list(reversed(rows[:page_limit]))
            elif after_message_id and anchor is not None:
                rows = conn.execute(
                    """
                    SELECT *
                    FROM messages
                    WHERE session_id=?
                      AND (created_at > ? OR (created_at = ? AND id > ?))
                    ORDER BY created_at ASC, id ASC
                    LIMIT ?
                    """,
                    (
                        session_id,
                        float(anchor["created_at"]),
                        float(anchor["created_at"]),
                        str(anchor["id"]),
                        page_limit + 1,
                    ),
                ).fetchall()
                has_more_before = False
                selected = list(rows[:page_limit])
            else:
                rows = conn.execute(
                    """
                    SELECT *
                    FROM messages
                    WHERE session_id=?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    (session_id, page_limit + 1),
                ).fetchall()
                has_more_before = len(rows) > page_limit
                selected = list(reversed(rows[:page_limit]))

        items = [self._row_to_message(r) for r in selected]
        return {
            "messages": items,
            "paging": {
                "limit": page_limit,
                "hasMoreBefore": has_more_before,
                "hasMoreAfter": False,
                "oldestMessageId": items[0]["id"] if items else None,
                "newestMessageId": items[-1]["id"] if items else None,
            },
        }

    def create_message(
        self,
        *,
        session_id: str,
        role: str,
        text: str,
        raw_text: str | None = None,
        attachments: list[dict] | None = None,
        source: str = "api",
        meta: str = "",
        message_id: str | None = None,
        created_at: float | None = None,
    ) -> dict:
        self.ensure_schema()
        msg_id = message_id or _new_id("msg")
        created = float(created_at or _now())
        payload = {
            "id": msg_id,
            "sessionId": session_id,
            "role": role or "assistant",
            "text": text or "",
            "rawText": str(raw_text or ""),
            "attachments": attachments or [],
            "source": source,
            "meta": meta or "",
            "createdAt": created,
        }

        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO messages(id, session_id, role, text, raw_text, meta, source, attachments_json, created_at) VALUES(?,?,?,?,?,?,?,?,?)",
                (
                    payload["id"],
                    session_id,
                    payload["role"],
                    payload["text"],
                    payload["rawText"],
                    payload["meta"],
                    payload["source"],
                    json.dumps(payload["attachments"], ensure_ascii=False),
                    payload["createdAt"],
                ),
            )
            conn.execute("UPDATE sessions SET updated_at=? WHERE id=?", (payload["createdAt"], session_id))
            conn.commit()

        return payload
