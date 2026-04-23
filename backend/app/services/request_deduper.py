from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field


@dataclass(slots=True)
class RequestRecord:
    key: str
    session_id: str
    client_message_id: str
    created_at: float = field(default_factory=time.time)
    status: str = 'running'
    result: dict | None = None
    error: str | None = None
    event: asyncio.Event = field(default_factory=asyncio.Event)


class RequestDeduper:
    def __init__(self, ttl_seconds: float = 600.0):
        self.ttl_seconds = ttl_seconds
        self._records: dict[str, RequestRecord] = {}
        self._lock = asyncio.Lock()

    def _make_key(self, session_id: str, client_message_id: str) -> str:
        return f'{session_id}:{client_message_id}'

    async def get_or_create(self, session_id: str, client_message_id: str) -> tuple[RequestRecord, bool]:
        key = self._make_key(session_id, client_message_id)
        async with self._lock:
            self._prune_locked()
            existing = self._records.get(key)
            if existing is not None:
                return existing, False
            record = RequestRecord(key=key, session_id=session_id, client_message_id=client_message_id)
            self._records[key] = record
            return record, True

    async def mark_completed(self, session_id: str, client_message_id: str, result: dict) -> None:
        key = self._make_key(session_id, client_message_id)
        async with self._lock:
            record = self._records.get(key)
            if record is None:
                return
            record.status = 'completed'
            record.result = dict(result)
            record.error = None
            record.event.set()

    async def mark_failed(self, session_id: str, client_message_id: str, error: str) -> None:
        key = self._make_key(session_id, client_message_id)
        async with self._lock:
            record = self._records.get(key)
            if record is None:
                return
            record.status = 'failed'
            record.error = str(error)
            record.event.set()

    async def clear(self, session_id: str, client_message_id: str) -> None:
        key = self._make_key(session_id, client_message_id)
        async with self._lock:
            self._records.pop(key, None)

    def _prune_locked(self) -> None:
        now = time.time()
        stale = [
            key
            for key, record in self._records.items()
            if now - record.created_at > self.ttl_seconds
        ]
        for key in stale:
            self._records.pop(key, None)
