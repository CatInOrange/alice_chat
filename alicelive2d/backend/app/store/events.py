from __future__ import annotations

import json
import time

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


class EventStore:
    """Event log persistence for SSE resume.

    We store events in SQLite so clients can reconnect with `since` even after
    backend restart.

    Note: We still keep payload JSON, not relational schema.
    """

    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)

    def append(self, event_type: str, payload: dict) -> dict:
        self.ensure_schema()
        ts = _now()
        with connect(self.db) as conn:
            cur = conn.execute(
                "INSERT INTO events(type, ts, payload_json) VALUES(?,?,?)",
                (str(event_type), float(ts), json.dumps(payload, ensure_ascii=False)),
            )
            seq = int(cur.lastrowid)
            conn.commit()
        return {"seq": seq, "type": str(event_type), "ts": float(ts), "payload": payload}

    def list_since(self, since: int, limit: int = 1000) -> list[dict]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT seq, type, ts, payload_json FROM events WHERE seq > ? ORDER BY seq ASC LIMIT ?",
                (int(since), int(limit)),
            ).fetchall()
        return [
            {"seq": int(r["seq"]), "type": r["type"], "ts": float(r["ts"]), "payload": json.loads(r["payload_json"] or "{}")}
            for r in rows
        ]
