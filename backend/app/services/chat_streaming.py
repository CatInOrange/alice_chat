from __future__ import annotations

import asyncio
import contextlib

from fastapi.responses import StreamingResponse

from dataclasses import replace

from ..app_context import AppContext
from ..services.routing import resolve_routing
from ..utils import strip_stage_directives
from ..web.helpers import build_route_key, require_existing_session
from ..web.sse import format_sse
from ..utils.frame_audit import audit_frame


class ChatStreamingService:
    def __init__(self, context: AppContext):
        self.context = context

    def create_response(self, body: dict) -> StreamingResponse:
        return StreamingResponse(
            self._stream(body),
            media_type='text/event-stream',
            headers={
                'Cache-Control': 'no-store',
                'X-Accel-Buffering': 'no',
            },
        )

    async def _stream(self, body: dict):
        session_store = self.context.session_store
        chat_service = self.context.chat_service
        events_bus = self.context.events_bus

        resolved = chat_service.resolve_request(body)
        session_id = require_existing_session(session_store, str(body.get('sessionId') or '').strip())
        routing = resolve_routing(
            contact_id=resolved.contact_id or resolved.session_name or 'assistant',
            user_id=resolved.user_id or session_id,
            session_id=session_id,
        )
        # DEBUG: Log routing decision
        print(f"[ROUTING DEBUG] contact_id={resolved.contact_id}, routing.agent_id={routing.agent_id}, routing.contact_id={routing.contact_id}")
        resolved = replace(
            resolved,
            agent=routing.agent_id,
            session_name=routing.session_name,
            session_key=routing.session_key,
            contact_id=routing.contact_id,
            user_id=resolved.user_id or session_id,
        )
        requested_route_key = build_route_key(
            provider_id=str(resolved.provider.get('id') or ''),
            session_key=resolved.session_key,
            agent=resolved.agent,
            session_name=resolved.session_name,
        )
        session_store.bind_route(session_id, requested_route_key)
        session_store.set_current_session_id(session_id)

        start_event = {
            'seq': 0,
            'type': 'start',
            'ts': 0,
            'payload': {
                'ok': True,
                'provider': resolved.provider.get('id'),
                'providerLabel': resolved.provider.get('name'),
                'agent': resolved.agent,
                'session': resolved.session_name,
            },
        }
        audit_frame(
            'backend_frontend_sse',
            'backend->frontend',
            start_event,
            phase='chat_stream_yield',
            sessionId=session_id,
            eventName='start',
        )
        yield format_sse(start_event, event_name='start', include_id=False)

        loop = asyncio.get_running_loop()
        delta_q: asyncio.Queue[dict] = asyncio.Queue(maxsize=200)
        result_fut: asyncio.Future[dict] = loop.create_future()

        def put_delta(payload: dict) -> None:
            with contextlib.suppress(Exception):
                delta_q.put_nowait(payload)

        def set_result(result: dict) -> None:
            with contextlib.suppress(Exception):
                if not result_fut.done():
                    result_fut.set_result(result)

        def set_exception(exc: BaseException) -> None:
            with contextlib.suppress(Exception):
                if not result_fut.done():
                    result_fut.set_exception(exc)

        def emit(payload: dict) -> None:
            try:
                loop.call_soon_threadsafe(put_delta, payload)
            except Exception:
                pass

        def run_provider_blocking() -> None:
            try:
                result = chat_service.run_chat_stream(resolved, emit, session_id=session_id, route_key=requested_route_key)
                loop.call_soon_threadsafe(set_result, result)
            except Exception as exc:  # noqa: BLE001
                loop.call_soon_threadsafe(set_exception, exc)

        loop.run_in_executor(None, run_provider_blocking)

        assistant_raw = ''
        try:
            while True:
                if result_fut.done() and delta_q.empty():
                    break

                delta_task = asyncio.create_task(delta_q.get())
                done, pending = await asyncio.wait({delta_task}, timeout=0.25, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
                for task in pending:
                    with contextlib.suppress(asyncio.CancelledError):
                        await task
                if not done:
                    continue

                payload = delta_task.result()
                delta_text = str(payload.get('text') or payload.get('delta') or '')
                if not delta_text:
                    continue
                assistant_raw += delta_text
                chunk_event = {
                    'seq': 0,
                    'type': 'chunk',
                    'ts': 0,
                    'payload': {
                        'kind': 'text',
                        'visibleText': strip_stage_directives(assistant_raw),
                        'rawText': assistant_raw,
                    },
                }
                audit_frame(
                    'backend_frontend_sse',
                    'backend->frontend',
                    chunk_event,
                    phase='chat_stream_yield',
                    sessionId=session_id,
                    eventName='chunk',
                )
                yield format_sse(chunk_event, event_name='chunk', include_id=False)

            result = await result_fut
        except Exception as exc:  # noqa: BLE001
            error_event = {'seq': 0, 'type': 'error', 'ts': 0, 'payload': {'error': str(exc)}}
            audit_frame(
                'backend_frontend_sse',
                'backend->frontend',
                error_event,
                phase='chat_stream_yield',
                sessionId=session_id,
                eventName='error',
            )
            yield format_sse(error_event, event_name='error', include_id=False)
            return

        if not bool(result.get('replyFinalReceived')):
            error_event = {'seq': 0, 'type': 'error', 'ts': 0, 'payload': {'error': 'missing reply_final; refusing to persist non-final preview as assistant message'}}
            audit_frame(
                'backend_frontend_sse',
                'backend->frontend',
                error_event,
                phase='chat_stream_yield',
                sessionId=session_id,
                eventName='error',
            )
            yield format_sse(error_event, event_name='error', include_id=False)
            return

        assistant_raw = str(result.get('rawReply') or result.get('reply') or '')
        assistant_visible = strip_stage_directives(str(result.get('reply') or ''))

        chat_service.persist_user_message(
            session_id=session_id,
            history_text=resolved.history_text,
            attachments=resolved.attachments,
            source=resolved.message_source,
        )

        persisted_messages = chat_service.persist_assistant_message(
            session_id=session_id,
            reply=assistant_visible,
            raw_reply=assistant_raw,
            images=result.get('images') or [],
            meta=resolved.assistant_meta,
            source=resolved.message_source,
        )
        for item in persisted_messages:
            await events_bus.publish('message.created', {'message': item})

        final_event = {
            'seq': 0,
            'type': 'final',
            'ts': 0,
            'payload': {
                'ok': True,
                'messageId': (persisted_messages[-1].get('id', '') if persisted_messages else ''),
                'userText': resolved.history_text,
                'reply': assistant_visible,
                'rawReply': assistant_raw,
                'provider': resolved.provider.get('id') or '',
                'providerLabel': resolved.provider.get('name') or resolved.provider.get('id') or '',
                'images': result.get('images') or [],
            },
        }
        audit_frame(
            'backend_frontend_sse',
            'backend->frontend',
            final_event,
            phase='chat_stream_yield',
            sessionId=session_id,
            eventName='final',
        )
        yield format_sse(final_event, event_name='final', include_id=False)
