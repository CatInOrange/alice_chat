from __future__ import annotations

"""SQLite database helpers.

We intentionally use the stdlib `sqlite3` module (no external ORM) to keep the
runtime footprint small and predictable inside nix-shell.

Concurrency model:
- FastAPI/Uvicorn runs request handlers concurrently.
- We create short-lived sqlite3 connections per operation (or per request) and
  enable WAL to improve read/write concurrency.

This module will be used by stores (sessions/messages/files/events).
"""

import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from ..config import ROOT


DEFAULT_DB_PATH = ROOT / "data" / "lunaria.sqlite3"


@dataclass(frozen=True, slots=True)
class DbConfig:
    path: Path = DEFAULT_DB_PATH


@contextmanager
def connect(db: DbConfig) -> Iterator[sqlite3.Connection]:
    db.path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db.path), check_same_thread=False)
    conn.row_factory = sqlite3.Row

    # Pragmas: reasonable defaults for an embedded app.
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    try:
        yield conn
    finally:
        conn.close()


def migrate(conn: sqlite3.Connection) -> None:
    """Create tables if they don't exist.

    Keep migrations idempotent so fresh users and existing users can both start.
    """

    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            route_key TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            raw_text TEXT NOT NULL DEFAULT '',
            meta TEXT NOT NULL,
            source TEXT NOT NULL,
            attachments_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_messages_session_created ON messages(session_id, created_at);

        CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            url TEXT NOT NULL,
            size INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            ts REAL NOT NULL,
            payload_json TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_events_seq ON events(seq);

        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
    conn.commit()

    # Backfill: older DBs created before `raw_text` existed.
    # SQLite supports adding columns via ALTER TABLE.
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(messages)").fetchall()}
        if "raw_text" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN raw_text TEXT NOT NULL DEFAULT ''")
            conn.commit()
    except Exception:
        # Best-effort: keep startup resilient.
        pass

    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(sessions)").fetchall()}
        if "route_key" not in cols:
            conn.execute("ALTER TABLE sessions ADD COLUMN route_key TEXT NOT NULL DEFAULT ''")
            conn.commit()
    except Exception:
        pass

    # Older databases may have created `sessions` before `route_key` existed.
    # Only create the partial index after the column is guaranteed to be present.
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(sessions)").fetchall()}
        if "route_key" in cols:
            conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_route_key ON sessions(route_key) WHERE route_key <> ''")
            conn.commit()
    except Exception:
        pass
