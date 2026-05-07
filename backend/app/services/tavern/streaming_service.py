from __future__ import annotations

import logging
import threading
import uuid
from typing import Any, Callable

from ...config import get_tavern_provider
from .model_client import TavernModelClient
from .tavern_service import TavernService

logger = logging.getLogger(__name__)


class TavernStreamingService:
    """Tavern-only generation pipeline.

    Separate from main ChatService/OpenClaw path by design.
    """

    def __init__(self, tavern_service: TavernService):
        self.tavern_service = tavern_service
        self._chat_locks_guard = threading.Lock()
        self._chat_locks: dict[str, threading.Lock] = {}

    def _chat_lock(self, chat_id: str) -> threading.Lock:
        with self._chat_locks_guard:
            lock = self._chat_locks.get(chat_id)
            if lock is None:
                lock = threading.Lock()
                self._chat_locks[chat_id] = lock
            return lock

    def send(
        self,
        chat_id: str,
        *,
        text: str,
        preset_id: str = '',
        provider_id: str = '',
        instruction_mode: str = '',
        suppress_user_message: bool = False,
    ) -> dict[str, Any]:
        chat_lock = self._chat_lock(chat_id)
        chat_lock.acquire()
        try:
            hidden_instruction = self.tavern_service._hidden_instruction_text(
                instruction_mode,
            )
            prepared = self.tavern_service.prepare_generation(
                chat_id,
                text=text,
                preset_id=preset_id,
                hidden_instruction=hidden_instruction,
            )
            provider = get_tavern_provider(provider_id or prepared['providerId'])
            client = TavernModelClient(
                self.tavern_service.merge_generation_provider(
                    provider,
                    prepared['preset'],
                ),
            )
            result = client.generate(messages=prepared['messages'])
            request_id = f'tav_req_{uuid.uuid4().hex[:12]}'
            user_message = (
                None
                if suppress_user_message
                else self.tavern_service.store.append_message(
                    chat_id,
                    role='user',
                    content=text,
                )
            )
            assistant_message = self.tavern_service.store.append_message(
                chat_id,
                role='assistant',
                content=result.text,
                metadata={
                    'requestId': request_id,
                    'providerId': provider.get('id'),
                    'model': client.provider_config.get('model'),
                    'promptDebug': {
                        'presetId': prepared['promptDebug'].preset_id,
                        'promptOrderId': prepared['promptDebug'].prompt_order_id,
                        'contextUsage': prepared['promptDebug'].context_usage,
                        'summary': {
                            'matchedWorldbookCount': len(
                                prepared['promptDebug'].matched_worldbook_entries,
                            ),
                            'rejectedWorldbookCount': len(
                                prepared['promptDebug'].rejected_worldbook_entries,
                            ),
                            'blockCount': len(prepared['promptDebug'].blocks),
                            'messageCount': len(prepared['promptDebug'].messages),
                        },
                        'instructionMode': instruction_mode,
                        'suppressedUserMessage': suppress_user_message,
                    },
                },
            )
            warnings: list[str] = []
            summary_result = None
            chat_after_runtime = None
            try:
                summary_result = self.tavern_service.maybe_generate_summary(
                    chat_id=chat_id,
                    provider_config=client.provider_config,
                )
            except Exception as exc:
                logger.warning(
                    'Tavern summary post-processing failed for chat %s: %s',
                    chat_id,
                    exc,
                    exc_info=True,
                )
                warnings.append(f'summary_failed: {exc}')
            try:
                chat_after_runtime = (
                    self.tavern_service.update_worldbook_runtime_after_turn(
                        chat_id=chat_id,
                        matched_worldbook_entries=prepared[
                            'promptDebug'
                        ].matched_worldbook_entries,
                        rejected_worldbook_entries=prepared[
                            'promptDebug'
                        ].rejected_worldbook_entries,
                    )
                )
            except Exception as exc:
                logger.warning(
                    'Tavern worldbook runtime post-processing failed for chat %s: %s',
                    chat_id,
                    exc,
                    exc_info=True,
                )
                warnings.append(f'worldbook_runtime_failed: {exc}')
            return {
                'requestId': request_id,
                'userMessage': user_message,
                'assistantMessage': assistant_message,
                'promptDebug': prepared['promptDebug'],
                'summary': summary_result,
                'chat': chat_after_runtime,
                'warnings': warnings,
            }
        finally:
            chat_lock.release()

    def stream(
        self,
        chat_id: str,
        *,
        text: str,
        preset_id: str = '',
        provider_id: str = '',
        instruction_mode: str = '',
        suppress_user_message: bool = False,
    ):
        chat_lock = self._chat_lock(chat_id)
        chat_lock.acquire()
        lock_released = False

        def release_chat_lock() -> None:
            nonlocal lock_released
            if lock_released:
                return
            lock_released = True
            chat_lock.release()

        try:
            hidden_instruction = self.tavern_service._hidden_instruction_text(
                instruction_mode,
            )
            prepared = self.tavern_service.prepare_generation(
                chat_id,
                text=text,
                preset_id=preset_id,
                hidden_instruction=hidden_instruction,
            )
            provider = get_tavern_provider(provider_id or prepared['providerId'])
            client = TavernModelClient(
                self.tavern_service.merge_generation_provider(
                    provider,
                    prepared['preset'],
                ),
            )
            request_id = f'tav_req_{uuid.uuid4().hex[:12]}'
            user_message = (
                None
                if suppress_user_message
                else self.tavern_service.store.append_message(
                    chat_id,
                    role='user',
                    content=text,
                )
            )
            assistant_message_id = f'tav_stream_{uuid.uuid4().hex[:12]}'
            assistant_metadata = {
                'requestId': request_id,
                'providerId': provider.get('id'),
                'model': client.provider_config.get('model'),
                'promptDebug': {
                    'presetId': prepared['promptDebug'].preset_id,
                    'promptOrderId': prepared['promptDebug'].prompt_order_id,
                    'contextUsage': prepared['promptDebug'].context_usage,
                    'summary': {
                        'matchedWorldbookCount': len(
                            prepared['promptDebug'].matched_worldbook_entries,
                        ),
                        'rejectedWorldbookCount': len(
                            prepared['promptDebug'].rejected_worldbook_entries,
                        ),
                        'blockCount': len(prepared['promptDebug'].blocks),
                        'messageCount': len(prepared['promptDebug'].messages),
                    },
                    'instructionMode': instruction_mode,
                    'suppressedUserMessage': suppress_user_message,
                },
            }

            def finalize(
                *,
                emit: Callable[[dict[str, Any]], None] | None = None,
            ) -> dict[str, Any]:
                try:
                    result = client.stream_generate(
                        messages=prepared['messages'],
                        emit=emit or (lambda _frame: None),
                    )
                    assistant_message = self.tavern_service.store.append_message(
                        chat_id,
                        role='assistant',
                        content=result.text,
                        metadata=assistant_metadata,
                    )
                    warnings: list[str] = []
                    summary_result = None
                    chat_after_runtime = None
                    try:
                        summary_result = self.tavern_service.maybe_generate_summary(
                            chat_id=chat_id,
                            provider_config=client.provider_config,
                        )
                    except Exception as exc:
                        logger.warning(
                            'Tavern summary post-processing failed for chat %s: %s',
                            chat_id,
                            exc,
                            exc_info=True,
                        )
                        warnings.append(f'summary_failed: {exc}')
                    try:
                        chat_after_runtime = self.tavern_service.update_worldbook_runtime_after_turn(
                            chat_id=chat_id,
                            matched_worldbook_entries=prepared[
                                'promptDebug'
                            ].matched_worldbook_entries,
                            rejected_worldbook_entries=prepared[
                                'promptDebug'
                            ].rejected_worldbook_entries,
                        )
                    except Exception as exc:
                        logger.warning(
                            'Tavern worldbook runtime post-processing failed for chat %s: %s',
                            chat_id,
                            exc,
                            exc_info=True,
                        )
                        warnings.append(f'worldbook_runtime_failed: {exc}')
                    return {
                        'requestId': request_id,
                        'userMessage': user_message,
                        'assistantMessage': assistant_message,
                        'assistantMessageId': assistant_message_id,
                        'text': result.text,
                        'promptDebug': prepared['promptDebug'],
                        'summary': summary_result,
                        'chat': chat_after_runtime,
                        'warnings': warnings,
                    }
                finally:
                    release_chat_lock()

            return {
                'requestId': request_id,
                'userMessage': user_message,
                'assistantMessageId': assistant_message_id,
                'prepared': prepared,
                'provider': provider,
                'finalize': finalize,
                'release': release_chat_lock,
            }
        except Exception:
            release_chat_lock()
            raise
