from __future__ import annotations

import uuid
from typing import Any, Callable

from ...config import get_tavern_provider
from .model_client import TavernModelClient
from .tavern_service import TavernService


class TavernStreamingService:
    """Tavern-only generation pipeline.

    Separate from main ChatService/OpenClaw path by design.
    """

    def __init__(self, tavern_service: TavernService):
        self.tavern_service = tavern_service

    def send(self, chat_id: str, *, text: str, preset_id: str = '', provider_id: str = '') -> dict[str, Any]:
        prepared = self.tavern_service.prepare_generation(chat_id, text=text, preset_id=preset_id)
        provider = get_tavern_provider(provider_id or prepared['providerId'])
        client = TavernModelClient(self.tavern_service.merge_generation_provider(provider, prepared['preset']))
        result = client.generate(messages=prepared['messages'])
        request_id = f'tav_req_{uuid.uuid4().hex[:12]}'
        user_message = self.tavern_service.store.append_message(chat_id, role='user', content=text)
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
                },
            },
        )
        summary_result = self.tavern_service.maybe_generate_summary(
            chat_id=chat_id,
            provider_config=client.provider_config,
        )
        chat_after_runtime = self.tavern_service.update_worldbook_runtime_after_turn(
            chat_id=chat_id,
            matched_worldbook_entries=prepared['promptDebug'].matched_worldbook_entries,
            rejected_worldbook_entries=prepared['promptDebug'].rejected_worldbook_entries,
        )
        return {
            'requestId': request_id,
            'userMessage': user_message,
            'assistantMessage': assistant_message,
            'promptDebug': prepared['promptDebug'],
            'summary': summary_result,
            'chat': chat_after_runtime,
        }

    def stream(self, chat_id: str, *, text: str, preset_id: str = '', provider_id: str = ''):
        prepared = self.tavern_service.prepare_generation(chat_id, text=text, preset_id=preset_id)
        provider = get_tavern_provider(provider_id or prepared['providerId'])
        client = TavernModelClient(self.tavern_service.merge_generation_provider(provider, prepared['preset']))
        request_id = f'tav_req_{uuid.uuid4().hex[:12]}'
        user_message = self.tavern_service.store.append_message(chat_id, role='user', content=text)
        assistant_message_id = f'tav_stream_{uuid.uuid4().hex[:12]}'
        assistant_metadata = {
            'requestId': request_id,
            'providerId': provider.get('id'),
            'model': client.provider_config.get('model'),
            'promptDebug': {
                'presetId': prepared['promptDebug'].preset_id,
                'promptOrderId': prepared['promptDebug'].prompt_order_id,
            },
        }

        def finalize(*, emit: Callable[[dict[str, Any]], None] | None = None) -> dict[str, Any]:
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
            summary_result = self.tavern_service.maybe_generate_summary(
                chat_id=chat_id,
                provider_config=client.provider_config,
            )
            chat_after_runtime = self.tavern_service.update_worldbook_runtime_after_turn(
                chat_id=chat_id,
                matched_worldbook_entries=prepared['promptDebug'].matched_worldbook_entries,
                rejected_worldbook_entries=prepared['promptDebug'].rejected_worldbook_entries,
            )
            return {
                'requestId': request_id,
                'userMessage': user_message,
                'assistantMessage': assistant_message,
                'assistantMessageId': assistant_message_id,
                'text': result.text,
                'promptDebug': prepared['promptDebug'],
                'summary': summary_result,
                'chat': chat_after_runtime,
            }

        return {
            'requestId': request_id,
            'userMessage': user_message,
            'assistantMessageId': assistant_message_id,
            'prepared': prepared,
            'provider': provider,
            'finalize': finalize,
        }
