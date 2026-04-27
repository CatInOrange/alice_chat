from __future__ import annotations

import asyncio

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ..app_context import AppContext
from ..web.sse import format_sse


def create_events_router(context: AppContext) -> APIRouter:
    router = APIRouter()

    @router.get('/api/events/stream')
    async def events_stream(since: int = 0):
        async def gen():
            for event in context.events_bus.list_since(int(since)):
                yield format_sse(event)

            yield format_sse({'seq': 0, 'type': 'stream.ready', 'ts': 0, 'payload': {'ok': True}})

            q = await context.events_bus.subscribe()
            try:
                while True:
                    try:
                        env = await asyncio.wait_for(q.get(), timeout=15.0)
                        yield format_sse({'seq': env.seq, 'type': env.type, 'ts': env.ts, 'payload': env.payload})
                    except TimeoutError:
                        yield ': keepalive\n\n'
            finally:
                await context.events_bus.unsubscribe(q)

        return StreamingResponse(
            gen(),
            media_type='text/event-stream',
            headers={'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'},
        )

    return router
