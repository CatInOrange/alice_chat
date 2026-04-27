from __future__ import annotations

"""Event bus for realtime updates (SSE).

We back the event stream with SQLite (`EventStore`) so clients can resume even
across backend restarts.

We also keep an in-memory subscriber list for efficient fan-out.
"""

import asyncio
from dataclasses import dataclass
from typing import Any

from ..store import EventStore


@dataclass(slots=True)
class EventEnvelope:
    seq: int
    type: str
    ts: float
    payload: dict


class EventsBus:
    def __init__(self, store: EventStore | None = None):
        self.store = store or EventStore()
        self._subscribers: set[asyncio.Queue[EventEnvelope]] = set()
        self._lock = asyncio.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None

    def bind_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        """Bind an event loop for threadsafe publishing.

        FastAPI runs on an asyncio loop, but push callbacks can arrive from
        background threads (e.g. OpenClaw channel listener). This allows
        publishing events with real-time fan-out from non-async threads.
        """

        self._loop = loop

    def publish_threadsafe(self, event_type: str, payload: dict) -> Any:
        """Publish from a non-async thread.

        Returns a concurrent.futures.Future.
        """

        if self._loop is None:
            raise RuntimeError("EventsBus loop not bound; call bind_loop() at startup")
        return asyncio.run_coroutine_threadsafe(self.publish(event_type, payload), self._loop)

    async def publish(self, event_type: str, payload: dict) -> EventEnvelope:
        record = self.store.append(event_type, payload)
        env = EventEnvelope(seq=int(record["seq"]), type=record["type"], ts=float(record["ts"]), payload=dict(record["payload"]))

        # Fan-out (best effort).
        async with self._lock:
            subs = list(self._subscribers)
        for q in subs:
            try:
                q.put_nowait(env)
            except Exception:
                # Drop slow/broken subscribers.
                try:
                    async with self._lock:
                        self._subscribers.discard(q)
                except Exception:
                    pass
        return env

    async def subscribe(self) -> asyncio.Queue[EventEnvelope]:
        q: asyncio.Queue[EventEnvelope] = asyncio.Queue(maxsize=200)
        async with self._lock:
            self._subscribers.add(q)
        return q

    async def unsubscribe(self, q: asyncio.Queue[EventEnvelope]) -> None:
        async with self._lock:
            self._subscribers.discard(q)

    def list_since(self, since: int) -> list[dict]:
        return self.store.list_since(int(since), limit=1000)
