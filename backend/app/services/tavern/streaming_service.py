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

    def _run_summary_postprocess_async(
        self,
        *,
        chat_id: str,
        provider_config: dict[str, Any],
    ) -> None:
        def worker() -> None:
            try:
                self.tavern_service.maybe_generate_summary(
                    chat_id=chat_id,
                    provider_config=provider_config,
                )
            except Exception as exc:
                logger.warning(
                    'Tavern summary post-processing failed for chat %s: %s',
                    chat_id,
                    exc,
                    exc_info=True,
                )

        threading.Thread(
            target=worker,
            name=f'tavern-summary-{chat_id[:8]}',
            daemon=True,
        ).start()

    def send(
        self,
        chat_id: str,
        *,
        text: str,
        preset_id: str = '',
        provider_id: str = '',
        instruction_mode: str = '',
        hidden_instruction: str = '',
        suppress_user_message: bool = False,
    ) -> dict[str, Any]:
        hidden_instruction = self.tavern_service.resolve_hidden_instruction(
            mode=instruction_mode,
            hidden_instruction=hidden_instruction,
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
                    'matchedWorldbookEntries': prepared['promptDebug'].matched_worldbook_entries,
                    'rejectedWorldbookEntries': prepared['promptDebug'].rejected_worldbook_entries,
                    'characterLoreBindings': prepared['promptDebug'].character_lore_bindings,
                    'blocks': prepared['promptDebug'].blocks,
                    'messages': prepared['promptDebug'].messages,
                    'renderedStoryString': prepared['promptDebug'].rendered_story_string,
                    'renderedExamples': prepared['promptDebug'].rendered_examples,
                    'runtimeContext': prepared['promptDebug'].runtime_context,
                    'contextUsage': prepared['promptDebug'].context_usage,
                    'depthInserts': prepared['promptDebug'].depth_inserts,
                    'macroEffects': prepared['promptDebug'].macro_effects,
                    'unknownMacros': prepared['promptDebug'].unknown_macros,
                    'resolvedPersona': prepared.get('persona') or {},
                    'worldbookRuntime': dict((prepared.get('chat') or {}).get('metadata', {}).get('worldbookRuntime') or {}) if isinstance((prepared.get('chat') or {}).get('metadata'), dict) else {},
                    'summary': {
                        'matchedWorldbookCount': len(
                            prepared['promptDebug'].matched_worldbook_entries,
                        ),
                        'rejectedWorldbookCount': len(
                            prepared['promptDebug'].rejected_worldbook_entries,
                        ),
                        'blockCount': len(prepared['promptDebug'].blocks),
                        'messageCount': len(prepared['promptDebug'].messages),
                        'source': 'last_real_request',
                        'previewOnly': False,
                        'instructionMode': instruction_mode,
                        'suppressedUserMessage': suppress_user_message,
                    },
                },
            },
        )
        warnings: list[str] = []
        try:
            self.tavern_service.variable_service.apply_effects(
                chat_id=chat_id,
                effects=prepared['promptDebug'].macro_effects,
                request_id=request_id,
            )
        except Exception as exc:
            logger.warning(
                'Tavern macro effect post-processing failed for chat %s: %s',
                chat_id,
                exc,
                exc_info=True,
            )
            warnings.append(f'macro_effects_failed: {exc}')
        chat_after_runtime = None
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
        self._run_summary_postprocess_async(
            chat_id=chat_id,
            provider_config=client.provider_config,
        )
        return {
            'requestId': request_id,
            'userMessage': user_message,
            'assistantMessage': assistant_message,
            'promptDebug': prepared['promptDebug'],
            'summary': None,
            'chat': chat_after_runtime,
            'warnings': warnings,
        }

    def stream(
        self,
        chat_id: str,
        *,
        text: str,
        preset_id: str = '',
        provider_id: str = '',
        instruction_mode: str = '',
        hidden_instruction: str = '',
        suppress_user_message: bool = False,
    ):
        hidden_instruction = self.tavern_service.resolve_hidden_instruction(
            mode=instruction_mode,
            hidden_instruction=hidden_instruction,
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
                'matchedWorldbookEntries': prepared['promptDebug'].matched_worldbook_entries,
                'rejectedWorldbookEntries': prepared['promptDebug'].rejected_worldbook_entries,
                'characterLoreBindings': prepared['promptDebug'].character_lore_bindings,
                'blocks': prepared['promptDebug'].blocks,
                'messages': prepared['promptDebug'].messages,
                'renderedStoryString': prepared['promptDebug'].rendered_story_string,
                'renderedExamples': prepared['promptDebug'].rendered_examples,
                'runtimeContext': prepared['promptDebug'].runtime_context,
                'contextUsage': prepared['promptDebug'].context_usage,
                'depthInserts': prepared['promptDebug'].depth_inserts,
                'macroEffects': prepared['promptDebug'].macro_effects,
                'unknownMacros': prepared['promptDebug'].unknown_macros,
                'resolvedPersona': prepared.get('persona') or {},
                'worldbookRuntime': dict((prepared.get('chat') or {}).get('metadata', {}).get('worldbookRuntime') or {}) if isinstance((prepared.get('chat') or {}).get('metadata'), dict) else {},
                'summary': {
                    'matchedWorldbookCount': len(
                        prepared['promptDebug'].matched_worldbook_entries,
                    ),
                    'rejectedWorldbookCount': len(
                        prepared['promptDebug'].rejected_worldbook_entries,
                    ),
                    'blockCount': len(prepared['promptDebug'].blocks),
                    'messageCount': len(prepared['promptDebug'].messages),
                    'source': 'last_real_request',
                    'previewOnly': False,
                    'instructionMode': instruction_mode,
                    'suppressedUserMessage': suppress_user_message,
                },
            },
        }

        def finalize(
            *,
            emit: Callable[[dict[str, Any]], None] | None = None,
        ) -> dict[str, Any]:
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
            try:
                self.tavern_service.variable_service.apply_effects(
                    chat_id=chat_id,
                    effects=prepared['promptDebug'].macro_effects,
                    request_id=request_id,
                )
            except Exception as exc:
                logger.warning(
                    'Tavern macro effect post-processing failed for chat %s: %s',
                    chat_id,
                    exc,
                    exc_info=True,
                )
                warnings.append(f'macro_effects_failed: {exc}')
            chat_after_runtime = None
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
            self._run_summary_postprocess_async(
                chat_id=chat_id,
                provider_config=client.provider_config,
            )
            return {
                'requestId': request_id,
                'userMessage': user_message,
                'assistantMessage': assistant_message,
                'assistantMessageId': assistant_message_id,
                'text': result.text,
                'promptDebug': prepared['promptDebug'],
                'summary': None,
                'chat': chat_after_runtime,
                'warnings': warnings,
            }

        return {
            'requestId': request_id,
            'userMessage': user_message,
            'assistantMessageId': assistant_message_id,
            'prepared': prepared,
            'provider': provider,
            'finalize': finalize,
        }
