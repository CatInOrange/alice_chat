from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from ..web.sse import format_sse
from ..utils.frame_audit import audit_frame


def create_events_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/events')
    async def events(sessionId: str | None = None, since: int | None = None) -> StreamingResponse:
        async def iterator():
            if since is not None:
                for event in context.events_bus.list_since(int(since)):
                    payload = event.get('payload') or {}
                    if sessionId and str(payload.get('sessionId') or '') != str(sessionId):
                        continue
                    audit_frame(
                        'backend_frontend_sse',
                        'backend->frontend',
                        event,
                        phase='events_route_replay',
                        sessionId=sessionId or '',
                        eventName=event.get('type') or 'message',
                    )
                    yield format_sse(event, event_name=event.get('type') or 'message', include_id=True)

            queue = await context.events_bus.subscribe()
            try:
                while True:
                    try:
                        event = await asyncio.wait_for(queue.get(), timeout=20)
                    except TimeoutError:
                        yield ': keepalive\n\n'
                        continue
                    payload = event.payload or {}
                    if sessionId and str(payload.get('sessionId') or '') != str(sessionId):
                        continue
                    audit_frame(
                        'backend_frontend_sse',
                        'backend->frontend',
                        {
                            'seq': event.seq,
                            'type': event.type,
                            'ts': event.ts,
                            'payload': payload,
                        },
                        phase='events_route_live',
                        sessionId=sessionId or '',
                        eventName=event.type or 'message',
                    )
                    yield format_sse(
                        {
                            'seq': event.seq,
                            'type': event.type,
                            'ts': event.ts,
                            'payload': payload,
                        },
                        event_name=event.type or 'message',
                        include_id=True,
                    )
            finally:
                await context.events_bus.unsubscribe(queue)

        return StreamingResponse(iterator(), media_type='text/event-stream')

    return router
