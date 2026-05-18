from __future__ import annotations

import json
import time

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


class RecoveryStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)

    def get(self, recovery_key: str) -> dict | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT * FROM message_recoveries WHERE recovery_key=? LIMIT 1",
                (str(recovery_key),),
            ).fetchone()
            if row is None:
                return None
            return dict(row)

    def mark(
        self,
        *,
        recovery_key: str,
        session_id: str,
        client_message_id: str,
        user_message_id: str = '',
        request_id: str = '',
        source: str,
        status: str,
        reason: str = '',
        message_id: str = '',
        meta: dict | None = None,
    ) -> None:
        self.ensure_schema()
        now = _now()
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO message_recoveries(
                    recovery_key, session_id, client_message_id, user_message_id, request_id,
                    source, status, reason, message_id, meta_json, created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(recovery_key) DO UPDATE SET
                    session_id=excluded.session_id,
                    client_message_id=excluded.client_message_id,
                    user_message_id=excluded.user_message_id,
                    request_id=excluded.request_id,
                    source=excluded.source,
                    status=excluded.status,
                    reason=excluded.reason,
                    message_id=excluded.message_id,
                    meta_json=excluded.meta_json,
                    updated_at=excluded.updated_at
                """,
                (
                    str(recovery_key),
                    str(session_id),
                    str(client_message_id),
                    str(user_message_id),
                    str(request_id),
                    str(source),
                    str(status),
                    str(reason),
                    str(message_id),
                    json.dumps(meta or {}, ensure_ascii=False),
                    now,
                    now,
                ),
            )
            conn.commit()
