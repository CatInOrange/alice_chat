from __future__ import annotations

import time
import uuid

from .db import DbConfig, connect, migrate
from .models import Session


def _now() -> float:
    return time.time()


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _normalize_session_id(value: str) -> str:
    return str(value or '').strip()


CURRENT_SESSION_KEY = "current_session_id"


class SessionStore:
    """Session store backed by SQLite."""

    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)

    def list_sessions(self) -> tuple[list[Session], str]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM sessions ORDER BY updated_at ASC").fetchall()
            sessions = [
                Session(
                    id=r["id"],
                    name=r["name"],
                    route_key=r["route_key"],
                    created_at=r["created_at"],
                    updated_at=r["updated_at"],
                )
                for r in rows
            ]
            current_id = self.get_current_session_id()
            return sessions, current_id

    def get_or_create_default(self) -> Session:
        self.ensure_schema()
        current_id = self.get_current_session_id()
        if current_id:
            current = self.get_session(current_id)
            if current:
                return current
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT 1").fetchone()
            if row:
                session = Session(id=row["id"], name=row["name"], route_key=row["route_key"], created_at=row["created_at"], updated_at=row["updated_at"])
                self.set_current_session_id(session.id)
                return session

            now = _now()
            sess = Session(id=_new_id("sess"), name="最近会话", route_key="", created_at=now, updated_at=now)
            conn.execute(
                "INSERT INTO sessions(id, name, route_key, created_at, updated_at) VALUES(?,?,?,?,?)",
                (sess.id, sess.name, sess.route_key, sess.created_at, sess.updated_at),
            )
            conn.commit()
            self.set_current_session_id(sess.id)
            return sess

    def create_session(self, name: str | None = None, *, route_key: str = "", select: bool = True) -> Session:
        return self.create_session_with_id(
            session_id='',
            name=name,
            route_key=route_key,
            select=select,
        )

    def create_session_with_id(
        self,
        *,
        session_id: str,
        name: str | None = None,
        route_key: str = "",
        select: bool = True,
    ) -> Session:
        self.ensure_schema()
        now = _now()
        resolved_id = _normalize_session_id(session_id) or _new_id("sess")
        sess = Session(id=resolved_id, name=(name or "").strip() or resolved_id or f"会话 {int(now)}", route_key=str(route_key or "").strip(), created_at=now, updated_at=now)
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO sessions(id, name, route_key, created_at, updated_at) VALUES(?,?,?,?,?)",
                (sess.id, sess.name, sess.route_key, sess.created_at, sess.updated_at),
            )
            conn.commit()
        if select:
            self.set_current_session_id(sess.id)
        return sess

    def ensure_session(
        self,
        session_id: str,
        *,
        name: str | None = None,
        route_key: str = "",
        select: bool = False,
    ) -> Session:
        self.ensure_schema()
        resolved_id = _normalize_session_id(session_id)
        if not resolved_id:
            return self.create_session_with_id(
                session_id='',
                name=name,
                route_key=route_key,
                select=select,
            )

        desired_name = (name or '').strip() or resolved_id
        desired_route_key = str(route_key or '').strip()
        now = _now()

        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id=?", (resolved_id,)).fetchone()
            if row:
                current_name = str(row['name'] or '').strip()
                current_route_key = str(row['route_key'] or '').strip()
                next_name = desired_name or current_name or resolved_id
                next_route_key = desired_route_key or current_route_key
                conn.execute(
                    "UPDATE sessions SET name=?, route_key=?, updated_at=? WHERE id=?",
                    (next_name, next_route_key, now, resolved_id),
                )
                conn.commit()
                session = Session(
                    id=resolved_id,
                    name=next_name,
                    route_key=next_route_key,
                    created_at=row['created_at'],
                    updated_at=now,
                )
                if select:
                    self.set_current_session_id(resolved_id)
                return session

            legacy = conn.execute(
                "SELECT * FROM sessions WHERE name=? ORDER BY updated_at DESC LIMIT 1",
                (desired_name,),
            ).fetchone()
            if legacy and str(legacy['id'] or '').strip() != resolved_id:
                legacy_id = str(legacy['id'] or '').strip()
                legacy_route_key = str(legacy['route_key'] or '').strip()
                created_at = float(legacy['created_at'])
                next_route_key = desired_route_key or legacy_route_key

                conn.execute(
                    "INSERT INTO sessions(id, name, route_key, created_at, updated_at) VALUES(?,?,?,?,?)",
                    (resolved_id, desired_name, '', created_at, now),
                )
                conn.execute(
                    "UPDATE messages SET session_id=? WHERE session_id=?",
                    (resolved_id, legacy_id),
                )
                conn.execute(
                    "UPDATE push_devices SET active_session_id=? WHERE active_session_id=?",
                    (resolved_id, legacy_id),
                )
                conn.execute(
                    "UPDATE app_state SET value=? WHERE key=? AND value=?",
                    (resolved_id, CURRENT_SESSION_KEY, legacy_id),
                )
                conn.execute("DELETE FROM sessions WHERE id=?", (legacy_id,))
                conn.execute(
                    "UPDATE sessions SET route_key=?, updated_at=? WHERE id=?",
                    (next_route_key, now, resolved_id),
                )
                conn.commit()
                if select:
                    self.set_current_session_id(resolved_id)
                return Session(
                    id=resolved_id,
                    name=desired_name,
                    route_key=next_route_key,
                    created_at=created_at,
                    updated_at=now,
                )

        return self.create_session_with_id(
            session_id=resolved_id,
            name=desired_name,
            route_key=desired_route_key,
            select=select,
        )

    def touch(self, session_id: str) -> None:
        self.ensure_schema()
        with connect(self.db) as conn:
            conn.execute("UPDATE sessions SET updated_at=? WHERE id=?", (_now(), session_id))
            conn.commit()

    def exists(self, session_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone()
            return bool(row)

    def get_session(self, session_id: str) -> Session | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
            if not row:
                return None
            return Session(id=row["id"], name=row["name"], route_key=row["route_key"], created_at=row["created_at"], updated_at=row["updated_at"])

    def set_current_session_id(self, session_id: str) -> None:
        self.ensure_schema()
        resolved = str(session_id or "").strip()
        if not resolved:
            return
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO app_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (CURRENT_SESSION_KEY, resolved),
            )
            conn.commit()

    def get_current_session_id(self) -> str:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT value FROM app_state WHERE key=?", (CURRENT_SESSION_KEY,)).fetchone()
            return str(row["value"]) if row and row["value"] else ""

    def bind_route(self, session_id: str, route_key: str) -> None:
        self.ensure_schema()
        resolved_session_id = str(session_id or "").strip()
        resolved_route_key = str(route_key or "").strip()
        if not resolved_session_id or not resolved_route_key:
            return
        with connect(self.db) as conn:
            conn.execute(
                "UPDATE sessions SET route_key='' WHERE route_key=? AND id<>?",
                (resolved_route_key, resolved_session_id),
            )
            conn.execute("UPDATE sessions SET route_key=? WHERE id=?", (resolved_route_key, resolved_session_id))
            conn.commit()

    def find_by_route(self, route_key: str) -> Session | None:
        self.ensure_schema()
        resolved_route_key = str(route_key or "").strip()
        if not resolved_route_key:
            return None
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM sessions WHERE route_key=?", (resolved_route_key,)).fetchone()
            if not row:
                return None
            return Session(id=row["id"], name=row["name"], route_key=row["route_key"], created_at=row["created_at"], updated_at=row["updated_at"])

    def find_or_create_by_route(self, route_key: str, *, name: str | None = None) -> Session:
        existing = self.find_by_route(route_key)
        if existing:
            return existing
        return self.create_session(name=name, route_key=route_key, select=False)

    def delete_session(self, session_id: str) -> bool:
        self.ensure_schema()
        resolved = str(session_id or "").strip()
        if not resolved:
            return False

        deleted = False
        with connect(self.db) as conn:
            row = conn.execute("SELECT 1 FROM sessions WHERE id=?", (resolved,)).fetchone()
            if not row:
                return False

            conn.execute("DELETE FROM messages WHERE session_id=?", (resolved,))
            conn.execute("DELETE FROM sessions WHERE id=?", (resolved,))
            deleted = True

            current_id = self.get_current_session_id()
            if current_id == resolved:
                latest = conn.execute("SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1").fetchone()
                if latest and latest["id"]:
                    conn.execute(
                        "INSERT INTO app_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (CURRENT_SESSION_KEY, str(latest["id"])),
                    )
                else:
                    conn.execute("DELETE FROM app_state WHERE key=?", (CURRENT_SESSION_KEY,))

            conn.commit()

        return deleted
