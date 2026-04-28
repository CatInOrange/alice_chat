from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from ..web.sse import format_sse
from ..utils.frame_audit import audit_frame


def _build_sse_payload(*, seq: int, event_type: str, ts: float, payload: dict, delivery_phase: str) -> dict:
    return {
        'seq': seq,
        'ts': ts,
        'type': event_type,
        'deliveryPhase': delivery_phase,
        **dict(payload or {}),
    }


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
                    sse_payload = _build_sse_payload(
                        seq=int(event.get('seq') or 0),
                        event_type=str(event.get('type') or 'message'),
                        ts=float(event.get('ts') or 0),
                        payload=payload,
                        delivery_phase='replay',
                    )
                    audit_frame(
                        'backend_frontend_sse',
                        'backend->frontend',
                        {
                            'seq': int(event.get('seq') or 0),
                            'type': str(event.get('type') or 'message'),
                            'ts': float(event.get('ts') or 0),
                            'payload': sse_payload,
                        },
                        phase='events_route_replay',
                        sessionId=sessionId or '',
                        eventName=event.get('type') or 'message',
                    )
                    yield format_sse(
                        {
                            'seq': int(event.get('seq') or 0),
                            'type': str(event.get('type') or 'message'),
                            'ts': float(event.get('ts') or 0),
                            'payload': sse_payload,
                        },
                        event_name=event.get('type') or 'message',
                        include_id=True,
                    )

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
                    sse_payload = _build_sse_payload(
                        seq=int(event.seq),
                        event_type=str(event.type or 'message'),
                        ts=float(event.ts),
                        payload=payload,
                        delivery_phase='live',
                    )
                    audit_frame(
                        'backend_frontend_sse',
                        'backend->frontend',
                        {
                            'seq': event.seq,
                            'type': event.type,
                            'ts': event.ts,
                            'payload': sse_payload,
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
                            'payload': sse_payload,
                        },
                        event_name=event.type or 'message',
                        include_id=True,
                    )
            finally:
                await context.events_bus.unsubscribe(queue)

        return StreamingResponse(iterator(), media_type='text/event-stream')

    return router
