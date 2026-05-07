from __future__ import annotations

import asyncio
import base64
import binascii
import contextlib
import time

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse, StreamingResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from ..config import get_tavern_providers
from ..services.tavern import TavernService
from ..web.sse import format_sse


def create_tavern_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])
    service = context.tavern_service or TavernService()
    streaming_service = context.tavern_streaming_service

    @router.get('/api/tavern/characters')
    async def list_tavern_characters():
        return {'ok': True, 'characters': service.list_characters()}

    @router.post('/api/tavern/characters/import-json')
    async def import_tavern_character_json(body: dict):
        filename = str(body.get('filename') or 'character.json').strip() or 'character.json'
        payload = body.get('content')
        if not isinstance(payload, dict):
            return JSONResponse(status_code=400, content={'ok': False, 'error': 'content must be a JSON object'})
        result = service.import_character_json(filename=filename, payload=payload)
        return {'ok': True, 'character': result.character, 'warnings': result.warnings}

    @router.post('/api/tavern/characters/import-png')
    async def import_tavern_character_png(body: dict):
        filename = str(body.get('filename') or 'character.png').strip() or 'character.png'
        content = body.get('content')
        if not isinstance(content, str) or not content.strip():
            return JSONResponse(status_code=400, content={'ok': False, 'error': 'content must be a base64 string'})
        raw = content.strip()
        if ',' in raw and raw.lower().startswith('data:'):
            raw = raw.split(',', 1)[1]
        try:
            png_bytes = base64.b64decode(raw)
        except binascii.Error:
            return JSONResponse(status_code=400, content={'ok': False, 'error': 'content is not valid base64'})
        try:
            result = service.import_character_png(filename=filename, png_bytes=png_bytes)
        except ValueError as exc:
            return JSONResponse(status_code=400, content={'ok': False, 'error': str(exc)})
        return {'ok': True, 'character': result.character, 'warnings': result.warnings}

    @router.post('/api/tavern/characters/import-charx')
    async def import_tavern_character_charx(body: dict):
        filename = str(body.get('filename') or 'character.charx').strip() or 'character.charx'
        content = body.get('content')
        if not isinstance(content, str) or not content.strip():
            return JSONResponse(status_code=400, content={'ok': False, 'error': 'content must be a base64 string'})
        raw = content.strip()
        if ',' in raw and raw.lower().startswith('data:'):
            raw = raw.split(',', 1)[1]
        try:
            charx_bytes = base64.b64decode(raw)
        except binascii.Error:
            return JSONResponse(status_code=400, content={'ok': False, 'error': 'content is not valid base64'})
        try:
            result = service.import_character_charx(filename=filename, charx_bytes=charx_bytes)
        except ValueError as exc:
            return JSONResponse(status_code=400, content={'ok': False, 'error': str(exc)})
        return {'ok': True, 'character': result.character, 'warnings': result.warnings}

    @router.get('/api/tavern/characters/{character_id}')
    async def get_tavern_character(character_id: str):
        character = service.get_character(character_id)
        if character is None:
            return JSONResponse(status_code=404, content={'ok': False, 'error': 'character not found'})
        return {'ok': True, 'character': character}

    def _delete_tavern_character_impl(character_id: str):
        deleted = service.delete_character(character_id)
        if not deleted:
            return JSONResponse(status_code=404, content={'ok': False, 'error': 'character not found'})
        return {'ok': True}

    @router.delete('/api/tavern/characters/{character_id}')
    async def delete_tavern_character(character_id: str):
        return _delete_tavern_character_impl(character_id)

    @router.post('/api/tavern/characters/{character_id}/delete')
    async def delete_tavern_character_post(character_id: str):
        return _delete_tavern_character_impl(character_id)

    @router.get('/api/tavern/worldbooks')
    async def list_worldbooks():
        return {'ok': True, 'worldbooks': service.list_worldbooks()}

    @router.post('/api/tavern/worldbooks')
    async def create_worldbook(body: dict):
        return {'ok': True, 'worldbook': service.create_worldbook(body)}

    @router.get('/api/tavern/worldbooks/{worldbook_id}')
    async def get_worldbook(worldbook_id: str):
        worldbook = service.get_worldbook(worldbook_id)
        if worldbook is None:
            raise HTTPException(status_code=404, detail='worldbook not found')
        return {'ok': True, 'worldbook': worldbook}

    @router.put('/api/tavern/worldbooks/{worldbook_id}')
    async def update_worldbook(worldbook_id: str, body: dict):
        worldbook = service.update_worldbook(worldbook_id, body)
        if worldbook is None:
            raise HTTPException(status_code=404, detail='worldbook not found')
        return {'ok': True, 'worldbook': worldbook}

    def _delete_worldbook_impl(worldbook_id: str):
        deleted = service.delete_worldbook(worldbook_id)
        if not deleted:
            raise HTTPException(status_code=404, detail='worldbook not found')
        return {'ok': True}

    @router.delete('/api/tavern/worldbooks/{worldbook_id}')
    async def delete_worldbook(worldbook_id: str):
        return _delete_worldbook_impl(worldbook_id)

    @router.post('/api/tavern/worldbooks/{worldbook_id}/delete')
    async def delete_worldbook_post(worldbook_id: str):
        return _delete_worldbook_impl(worldbook_id)

    @router.get('/api/tavern/worldbooks/{worldbook_id}/entries')
    async def list_worldbook_entries(worldbook_id: str):
        return {'ok': True, 'entries': service.list_worldbook_entries(worldbook_id)}

    @router.post('/api/tavern/worldbooks/{worldbook_id}/entries')
    async def create_worldbook_entry(worldbook_id: str, body: dict):
        return {'ok': True, 'entry': service.create_worldbook_entry(worldbook_id, body)}

    @router.put('/api/tavern/worldbooks/{worldbook_id}/entries/{entry_id}')
    async def update_worldbook_entry(worldbook_id: str, entry_id: str, body: dict):
        _ = worldbook_id
        entry = service.update_worldbook_entry(entry_id, body)
        if entry is None:
            raise HTTPException(status_code=404, detail='entry not found')
        return {'ok': True, 'entry': entry}

    @router.get('/api/tavern/prompt-blocks')
    async def list_prompt_blocks():
        return {'ok': True, 'promptBlocks': service.list_prompt_blocks()}

    @router.post('/api/tavern/prompt-blocks')
    async def create_prompt_block(body: dict):
        return {'ok': True, 'promptBlock': service.create_prompt_block(body)}

    @router.put('/api/tavern/prompt-blocks/{block_id}')
    async def update_prompt_block(block_id: str, body: dict):
        block = service.update_prompt_block(block_id, body)
        if block is None:
            raise HTTPException(status_code=404, detail='prompt block not found')
        return {'ok': True, 'promptBlock': block}

    def _delete_prompt_block_impl(block_id: str):
        deleted = service.delete_prompt_block(block_id)
        if not deleted:
            raise HTTPException(status_code=404, detail='prompt block not found')
        return {'ok': True}

    @router.delete('/api/tavern/prompt-blocks/{block_id}')
    async def delete_prompt_block(block_id: str):
        return _delete_prompt_block_impl(block_id)

    @router.post('/api/tavern/prompt-blocks/{block_id}/delete')
    async def delete_prompt_block_post(block_id: str):
        return _delete_prompt_block_impl(block_id)

    @router.get('/api/tavern/prompt-orders')
    async def list_prompt_orders():
        return {'ok': True, 'promptOrders': service.list_prompt_orders()}

    @router.post('/api/tavern/prompt-orders')
    async def create_prompt_order(body: dict):
        return {'ok': True, 'promptOrder': service.create_prompt_order(body)}

    @router.put('/api/tavern/prompt-orders/{prompt_order_id}')
    async def update_prompt_order(prompt_order_id: str, body: dict):
        prompt_order = service.update_prompt_order(prompt_order_id, body)
        if prompt_order is None:
            raise HTTPException(status_code=404, detail='prompt order not found')
        return {'ok': True, 'promptOrder': prompt_order}

    @router.get('/api/tavern/presets')
    async def list_presets():
        return {'ok': True, 'presets': service.list_presets()}

    @router.post('/api/tavern/presets')
    async def create_preset(body: dict):
        return {'ok': True, 'preset': service.create_preset(body)}

    @router.put('/api/tavern/presets/{preset_id}')
    async def update_preset(preset_id: str, body: dict):
        preset = service.update_preset(preset_id, body)
        if preset is None:
            raise HTTPException(status_code=404, detail='preset not found')
        return {'ok': True, 'preset': preset}

    @router.get('/api/tavern/config/options')
    async def get_tavern_config_options():
        return {
            'ok': True,
            'providers': get_tavern_providers(),
            'presets': service.list_presets(),
            'promptOrders': service.list_prompt_orders(),
            'promptBlocks': service.list_prompt_blocks(),
            'worldbooks': service.list_worldbooks(),
        }

    @router.get('/api/tavern/chats')
    async def list_chats():
        return {'ok': True, 'chats': service.list_chats()}

    @router.post('/api/tavern/chats')
    async def create_chat(body: dict):
        return {'ok': True, 'chat': service.create_chat(body)}

    @router.get('/api/tavern/chats/{chat_id}')
    async def get_chat(chat_id: str):
        chat = service.get_chat(chat_id)
        if chat is None:
            raise HTTPException(status_code=404, detail='chat not found')
        return {'ok': True, 'chat': chat}

    def _delete_chat_impl(chat_id: str):
        deleted = service.delete_chat(chat_id)
        if not deleted:
            raise HTTPException(status_code=404, detail='chat not found')
        return {'ok': True}

    @router.delete('/api/tavern/chats/{chat_id}')
    async def delete_chat(chat_id: str):
        return _delete_chat_impl(chat_id)

    @router.post('/api/tavern/chats/{chat_id}/delete')
    async def delete_chat_post(chat_id: str):
        return _delete_chat_impl(chat_id)

    @router.put('/api/tavern/chats/{chat_id}')
    async def update_chat(chat_id: str, body: dict):
        chat = service.update_chat(chat_id, body)
        if chat is None:
            raise HTTPException(status_code=404, detail='chat not found')
        return {'ok': True, 'chat': chat}

    @router.get('/api/tavern/chats/{chat_id}/messages')
    async def list_chat_messages(chat_id: str):
        return {'ok': True, 'messages': service.list_chat_messages(chat_id)}

    @router.post('/api/tavern/chats/{chat_id}/send')
    async def send_chat_message(chat_id: str, body: dict):
        text = str(body.get('text') or '').strip()
        if not text:
            raise HTTPException(status_code=400, detail='text is required')
        try:
            result = streaming_service.send(
                chat_id,
                text=text,
                preset_id=str(body.get('presetId') or '').strip(),
                provider_id=str(body.get('providerId') or '').strip(),
                instruction_mode=str(body.get('instructionMode') or '').strip(),
                suppress_user_message=body.get('suppressUserMessage') is True,
            )
        except FileNotFoundError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f'tavern generation failed: {exc}') from exc
        return {
            'ok': True,
            'chatId': chat_id,
            'requestId': result['requestId'],
            'userMessage': result['userMessage'],
            'assistantMessage': result['assistantMessage'],
            'promptDebug': {
                'presetId': result['promptDebug'].preset_id,
                'promptOrderId': result['promptDebug'].prompt_order_id,
                'matchedWorldbookEntries': result['promptDebug'].matched_worldbook_entries,
                'rejectedWorldbookEntries': result['promptDebug'].rejected_worldbook_entries,
                'characterLoreBindings': result['promptDebug'].character_lore_bindings,
                'blocks': result['promptDebug'].blocks,
                'messages': result['promptDebug'].messages,
                'renderedStoryString': result['promptDebug'].rendered_story_string,
                'renderedExamples': result['promptDebug'].rendered_examples,
                'runtimeContext': result['promptDebug'].runtime_context,
                'depthInserts': result['promptDebug'].depth_inserts,
                'contextUsage': result['promptDebug'].context_usage,
                'summary': {
                    'matchedWorldbookCount': len(result['promptDebug'].matched_worldbook_entries),
                    'rejectedWorldbookCount': len(result['promptDebug'].rejected_worldbook_entries),
                    'blockCount': len(result['promptDebug'].blocks),
                    'messageCount': len(result['promptDebug'].messages),
                    'totalTokens': (result['promptDebug'].context_usage.get('totalTokens') if isinstance(result['promptDebug'].context_usage, dict) else None),
                    'maxContext': (result['promptDebug'].context_usage.get('maxContext') if isinstance(result['promptDebug'].context_usage, dict) else None),
                },
            },
        }

    @router.post('/api/tavern/chats/{chat_id}/stream')
    async def stream_chat(chat_id: str, body: dict):
        text = str(body.get('text') or '').strip()
        if not text:
            raise HTTPException(status_code=400, detail='text is required')
        try:
            state = streaming_service.stream(
                chat_id,
                text=text,
                preset_id=str(body.get('presetId') or '').strip(),
                provider_id=str(body.get('providerId') or '').strip(),
                instruction_mode=str(body.get('instructionMode') or '').strip(),
                suppress_user_message=body.get('suppressUserMessage') is True,
            )
        except FileNotFoundError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

        async def event_stream():
            request_id = state['requestId']
            assistant_message_id = state['assistantMessageId']
            start_payload = {'requestId': request_id}
            if state.get('userMessage') is not None:
                start_payload['messageId'] = state['userMessage']['id']
                start_payload['userMessage'] = state['userMessage']
            yield format_sse(start_payload, event_name='start', include_id=False)
            queue: asyncio.Queue[str] = asyncio.Queue()
            loop = asyncio.get_running_loop()

            def emit_delta(frame: dict[str, object]) -> None:
                delta = str(frame.get('delta') or '')
                if not delta:
                    return
                loop.call_soon_threadsafe(queue.put_nowait, delta)

            final_task = asyncio.create_task(
                asyncio.to_thread(state['finalize'], emit=emit_delta),
            )
            last_keepalive = time.monotonic()
            try:
                while True:
                    try:
                        delta = await asyncio.wait_for(queue.get(), timeout=1.0)
                        yield format_sse({'requestId': request_id, 'messageId': assistant_message_id, 'delta': delta}, event_name='delta', include_id=False)
                        last_keepalive = time.monotonic()
                    except asyncio.TimeoutError:
                        if final_task.done() and queue.empty():
                            break
                        now = time.monotonic()
                        if now - last_keepalive >= 10:
                            yield ': keep-alive\n\n'
                            last_keepalive = now
                final = await final_task
                yield format_sse({
                    'requestId': request_id,
                    'messageId': final['assistantMessage']['id'],
                    'text': final['text'],
                    'assistantMessage': final['assistantMessage'],
                    'promptDebug': {
                        'presetId': final['promptDebug'].preset_id,
                        'promptOrderId': final['promptDebug'].prompt_order_id,
                        'matchedWorldbookEntries': final['promptDebug'].matched_worldbook_entries,
                        'rejectedWorldbookEntries': final['promptDebug'].rejected_worldbook_entries,
                        'characterLoreBindings': final['promptDebug'].character_lore_bindings,
                        'blocks': final['promptDebug'].blocks,
                        'messages': final['promptDebug'].messages,
                        'renderedStoryString': final['promptDebug'].rendered_story_string,
                        'renderedExamples': final['promptDebug'].rendered_examples,
                        'runtimeContext': final['promptDebug'].runtime_context,
                        'depthInserts': final['promptDebug'].depth_inserts,
                        'contextUsage': final['promptDebug'].context_usage,
                        'summary': {
                            'matchedWorldbookCount': len(final['promptDebug'].matched_worldbook_entries),
                            'rejectedWorldbookCount': len(final['promptDebug'].rejected_worldbook_entries),
                            'blockCount': len(final['promptDebug'].blocks),
                            'messageCount': len(final['promptDebug'].messages),
                            'totalTokens': (final['promptDebug'].context_usage.get('totalTokens') if isinstance(final['promptDebug'].context_usage, dict) else None),
                            'maxContext': (final['promptDebug'].context_usage.get('maxContext') if isinstance(final['promptDebug'].context_usage, dict) else None),
                        },
                    },
                }, event_name='final', include_id=False)
            except Exception as exc:
                if not final_task.done():
                    final_task.cancel()
                    with contextlib.suppress(Exception):
                        await final_task
                yield format_sse({'requestId': request_id, 'error': str(exc)}, event_name='error', include_id=False)

        return StreamingResponse(event_stream(), media_type='text/event-stream')

    @router.get('/api/tavern/chats/{chat_id}/prompt-debug')
    async def get_prompt_debug(chat_id: str):
        try:
            debug = service.build_prompt_debug(chat_id)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return {'ok': True, 'debug': debug}

    return router
