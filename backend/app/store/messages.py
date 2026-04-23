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
            return [
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
                for r in rows
            ]

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
