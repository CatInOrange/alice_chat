from __future__ import annotations

import io
import json
import os
import shutil
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

from ...config import get_tavern_config, get_tavern_image_provider, get_tavern_provider
from ...store.tavern import TavernStore
from .chat_summarization_service import TavernChatSummarizationService
from .long_term_memory_service import TavernLongTermMemoryService
from .prompt_builder import PromptBuilder, PromptDebugResult
from .persona_service import TavernPersonaService
from .variable_service import TavernVariableService
from .macro_runtime import MacroEngine, build_macro_runtime_context, normalize_legacy_angle_bracket_placeholders
from .model_client import TavernModelClient
from .image_generation import (
    TavernImageGenerator,
    TavernImagePromptRefiner,
    build_scene_image_generation_prompt,
)


@dataclass(slots=True)
class CharacterImportResult:
    character: dict[str, Any]
    warnings: list[str]


@dataclass(slots=True)
class TavernSendResult:
    request_id: str
    user_message: dict[str, Any]
    assistant_message: dict[str, Any]
    prompt_debug: PromptDebugResult


class TavernService:
    def __init__(
        self,
        *,
        store: TavernStore | None = None,
        prompt_builder: PromptBuilder | None = None,
        uploads_dir: Path | None = None,
        summarization_service: TavernChatSummarizationService | None = None,
    ):
        self.store = store or TavernStore()
        self.prompt_builder = prompt_builder or PromptBuilder()
        self.uploads_dir = uploads_dir
        self.summarization_service = summarization_service or TavernChatSummarizationService()
        self.long_term_memory_service = TavernLongTermMemoryService()
        self.persona_service = TavernPersonaService(self.store)
        self.variable_service = TavernVariableService(self.store)
        self.macro_engine = MacroEngine()

    def ensure_schema(self) -> None:
        self.store.ensure_schema()

    # Character
    def import_character_json(self, *, filename: str, payload: dict[str, Any]) -> CharacterImportResult:
        character = self.store.import_character_json(filename=filename, payload=payload)
        warnings = self._build_character_import_warnings(character)
        return CharacterImportResult(character=character, warnings=warnings)

    def import_character_png(self, *, filename: str, png_bytes: bytes) -> CharacterImportResult:
        character = self.store.import_character_png(filename=filename, png_bytes=png_bytes)
        character = self._materialize_character_avatar(character, filename=filename, raw_bytes=png_bytes)
        warnings = self._build_character_import_warnings(character)
        return CharacterImportResult(character=character, warnings=warnings)

    def import_character_charx(self, *, filename: str, charx_bytes: bytes) -> CharacterImportResult:
        auxiliary_summary = {'sprites': 0, 'backgrounds': 0, 'misc': 0}
        with zipfile.ZipFile(io.BytesIO(charx_bytes)) as archive:
            card_member = self._find_zip_member(archive, 'card.json')
            if not card_member:
                raise ValueError('charx archive missing card.json')
            payload = json.loads(archive.read(card_member).decode('utf-8'))
            if not isinstance(payload, dict):
                raise ValueError('charx card.json must be a json object')
            icon_member = self._find_charx_icon_member(archive, payload)
            avatar_bytes = archive.read(icon_member) if icon_member else None
            character = self.store.import_character_json(filename=filename, payload=payload)
            auxiliary_summary = self._persist_charx_auxiliary_assets(archive, payload, character)
        if avatar_bytes:
            character = self._materialize_character_avatar(character, filename=filename, raw_bytes=avatar_bytes)
        merged_metadata = dict(character.get('metadata') or {})
        merged_metadata['charxAssets'] = auxiliary_summary
        updated = self.store.update_character_import_fields(
            character['id'],
            {
                'avatarPath': character.get('avatarPath') or '',
                'metadata': merged_metadata,
            },
        )
        character = updated or character
        warnings = self._build_character_import_warnings(character)
        if not avatar_bytes:
            warnings.append('CharX 中未找到可用 icon/avatar，已仅导入角色卡内容。')
        return CharacterImportResult(character=character, warnings=warnings)

    def list_characters(self) -> list[dict[str, Any]]:
        return self.store.list_characters()

    def get_character(self, character_id: str) -> dict[str, Any] | None:
        return self.store.get_character(character_id)

    def delete_character(self, character_id: str) -> bool:
        return self.store.delete_character(character_id)

    # Worldbook
    def create_worldbook(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_worldbook(payload)

    def list_worldbooks(self) -> list[dict[str, Any]]:
        return self.store.list_worldbooks()

    def get_worldbook(self, worldbook_id: str) -> dict[str, Any] | None:
        return self.store.get_worldbook(worldbook_id)

    def update_worldbook(self, worldbook_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_worldbook(worldbook_id, payload)

    def delete_worldbook(self, worldbook_id: str) -> bool:
        return self.store.delete_worldbook(worldbook_id)

    def create_worldbook_entry(self, worldbook_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_worldbook_entry(worldbook_id, payload)

    def list_worldbook_entries(self, worldbook_id: str) -> list[dict[str, Any]]:
        return self.store.list_worldbook_entries(worldbook_id)

    def update_worldbook_entry(self, entry_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_worldbook_entry(entry_id, payload)

    # Prompt
    def create_prompt_block(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_prompt_block(payload)

    def list_prompt_blocks(self) -> list[dict[str, Any]]:
        return self.store.list_prompt_blocks()

    def update_prompt_block(self, block_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_prompt_block(block_id, payload)

    def delete_prompt_block(self, block_id: str) -> bool:
        return self.store.delete_prompt_block(block_id)

    def create_prompt_order(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_prompt_order(payload)

    def list_prompt_orders(self) -> list[dict[str, Any]]:
        return self.store.list_prompt_orders()

    def get_prompt_order(self, prompt_order_id: str) -> dict[str, Any] | None:
        return self.store.get_prompt_order(prompt_order_id)

    def update_prompt_order(self, prompt_order_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_prompt_order(prompt_order_id, payload)

    # Preset
    def create_preset(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_preset(payload)

    def list_presets(self) -> list[dict[str, Any]]:
        return self.store.list_presets()

    def update_preset(self, preset_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_preset(preset_id, payload)

    # Persona
    def create_persona(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_persona(payload)

    def list_personas(self) -> list[dict[str, Any]]:
        return self.store.list_personas()

    def get_persona(self, persona_id: str) -> dict[str, Any] | None:
        return self.store.get_persona(persona_id)

    def update_persona(self, persona_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_persona(persona_id, payload)

    def delete_persona(self, persona_id: str) -> bool:
        return self.store.delete_persona(persona_id)

    # Variables
    def get_chat_variables(self, chat_id: str) -> dict[str, Any]:
        return self.variable_service.get_local_variables(chat_id)

    def set_chat_variables(self, chat_id: str, values: dict[str, Any]) -> dict[str, Any]:
        return self.variable_service.set_local_variables(chat_id, values)

    def get_global_variables(self) -> dict[str, Any]:
        return self.variable_service.get_global_variables()

    def set_global_variables(self, values: dict[str, Any]) -> dict[str, Any]:
        return self.variable_service.set_global_variables(values)

    # Chat
    def create_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        normalized_payload = dict(payload or {})
        character_id = str(normalized_payload.get('characterId') or '').strip()
        character = self.store.get_character(character_id) if character_id else None
        if character is not None:
            persona_stub = self.persona_service.resolve_for_chat({
                'personaId': str(normalized_payload.get('personaId') or '').strip(),
                'metadata': dict(normalized_payload.get('metadata') or {}) if isinstance(normalized_payload.get('metadata'), dict) else {},
            })
            variable_snapshot = self.variable_service.snapshot_for_chat({
                'metadata': dict(normalized_payload.get('metadata') or {}) if isinstance(normalized_payload.get('metadata'), dict) else {},
            })
            first_message = normalize_legacy_angle_bracket_placeholders(
                str(character.get('firstMessage') or '').strip()
            )
            if first_message:
                runtime_context = build_macro_runtime_context(
                    character={**character, 'firstMessage': first_message},
                    chat={
                        'id': '',
                        'personaId': str(normalized_payload.get('personaId') or '').strip(),
                        'metadata': dict(normalized_payload.get('metadata') or {}) if isinstance(normalized_payload.get('metadata'), dict) else {},
                    },
                    history=[],
                    user_text='',
                    persona=persona_stub,
                    local_variables=variable_snapshot.local,
                    global_variables=variable_snapshot.global_,
                    original_text='',
                )
                rendered = self.macro_engine.render(first_message, runtime_context, allow_side_effects=False)
                normalized_payload['seedFirstMessage'] = rendered.text
        return self.store.create_chat(normalized_payload)

    def list_chats(self) -> list[dict[str, Any]]:
        return self.store.list_chats()

    def get_chat(self, chat_id: str) -> dict[str, Any] | None:
        return self.store.get_chat(chat_id)

    def delete_chat(self, chat_id: str) -> bool:
        return self.store.delete_chat(chat_id)

    def update_chat(self, chat_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_chat(chat_id, payload)

    def list_chat_messages(self, chat_id: str, *, limit: int | None = None) -> list[dict[str, Any]]:
        return self.store.list_chat_messages(chat_id, limit=limit)

    def delete_messages_from(self, chat_id: str, message_id: str) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None
        deleted_messages = self.store.delete_messages_from(chat_id, message_id)
        if not deleted_messages:
            return None
        deleted_ids = {
            str(item.get('id') or '').strip()
            for item in deleted_messages
            if str(item.get('id') or '').strip()
        }
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        scene_image = metadata.get('sceneImage') if isinstance(metadata.get('sceneImage'), dict) else None
        source_message_id = str((scene_image or {}).get('sourceMessageId') or '').strip()
        if source_message_id and source_message_id in deleted_ids:
            metadata.pop('sceneImage', None)
            chat = self.store.update_chat(chat_id, {'metadata': metadata}) or chat
        self.rebuild_and_save_latest_prompt_debug(chat_id)
        refreshed_chat = self.store.get_chat(chat_id) or chat
        messages = self.store.list_chat_messages(chat_id)
        prompt_debug = self.build_prompt_debug(chat_id)
        return {
            'chat': refreshed_chat,
            'messages': messages,
            'promptDebug': prompt_debug,
            'deletedCount': len(deleted_messages),
            'deletedMessageIds': sorted(deleted_ids),
        }

    def get_scene_image(self, chat_id: str) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        scene = metadata.get('sceneImage') if isinstance(metadata.get('sceneImage'), dict) else {}
        return {
            'chatId': chat_id,
            'sceneImage': dict(scene or {}),
        }

    def generate_scene_image(self, chat_id: str) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        character = self.store.get_character(chat['characterId'])
        if character is None:
            raise ValueError('character not found')
        messages = self.store.list_chat_messages(chat_id)
        source_message = next(
            (
                message
                for message in reversed(messages)
                if str(message.get('role') or '').strip() == 'assistant'
                and str(message.get('content') or '').strip()
            ),
            None,
        )
        if source_message is None:
            raise ValueError('no assistant message available for image generation')

        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        metadata['sceneImage'] = {
            **(metadata.get('sceneImage') if isinstance(metadata.get('sceneImage'), dict) else {}),
            'status': 'generating',
            'sourceMessageId': str(source_message.get('id') or '').strip(),
            'updatedAt': self._iso_now(),
        }
        updated_chat = self.store.update_chat(chat_id, {'metadata': metadata}) or chat

        try:
            provider_id = str(updated_chat.get('presetId') or '').strip()
            prepared = self.prepare_generation(chat_id, text='[scene image generation]', preset_id=provider_id)
            text_provider = get_tavern_provider(prepared['providerId'])
            refiner = TavernImagePromptRefiner(
                text_provider_config=self.merge_generation_provider(text_provider, prepared['preset']),
                model_client_cls=TavernModelClient,
            )
            prompt = refiner.refine(
                character_name=str(character.get('name') or '').strip() or '角色',
                assistant_text=str(source_message.get('content') or ''),
            )
            final_generation_prompt = build_scene_image_generation_prompt(prompt)
            image_provider = get_tavern_image_provider()
            if not self.uploads_dir:
                raise ValueError('uploads_dir is not configured')
            reference_image = self._resolve_scene_reference_image(character)
            generator = TavernImageGenerator(
                provider_config=image_provider,
                uploads_dir=self.uploads_dir,
            )
            result = generator.generate(
                prompt=final_generation_prompt,
                reference_image=reference_image,
                chat_id=chat_id,
            )
            metadata = dict((self.store.get_chat(chat_id) or updated_chat).get('metadata') or {})
            metadata['sceneImage'] = {
                'status': 'ready',
                'sourceMessageId': str(source_message.get('id') or '').strip(),
                'prompt': str(source_message.get('content') or '').strip(),
                'displayPrompt': str(source_message.get('content') or '').strip(),
                'generationPrompt': final_generation_prompt,
                'refinedPrompt': prompt,
                'imageUrl': result.image_url,
                'provider': result.provider_meta,
                'updatedAt': self._iso_now(),
            }
            saved = self.store.update_chat(chat_id, {'metadata': metadata}) or updated_chat
            return {
                'chatId': chat_id,
                'sceneImage': dict(metadata['sceneImage']),
                'chat': saved,
            }
        except Exception as exc:
            metadata = dict((self.store.get_chat(chat_id) or updated_chat).get('metadata') or {})
            metadata['sceneImage'] = {
                'status': 'error',
                'sourceMessageId': str(source_message.get('id') or '').strip(),
                'error': str(exc),
                'updatedAt': self._iso_now(),
            }
            saved = self.store.update_chat(chat_id, {'metadata': metadata}) or updated_chat
            return {
                'chatId': chat_id,
                'sceneImage': dict(metadata['sceneImage']),
                'chat': saved,
            }

    def send_message(self, chat_id: str, *, text: str, preset_id: str = '') -> TavernSendResult:
        prepared = self.prepare_generation(chat_id, text=text, preset_id=preset_id)
        user_message = self.store.append_message(chat_id, role='user', content=text)
        assistant_text = self._build_placeholder_reply(prepared['character'], text)
        full_prompt_debug = self._trim_prompt_debug_payload({
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
                'matchedWorldbookCount': len(prepared['promptDebug'].matched_worldbook_entries),
                'rejectedWorldbookCount': len(prepared['promptDebug'].rejected_worldbook_entries),
                'blockCount': len(prepared['promptDebug'].blocks),
                'messageCount': len(prepared['promptDebug'].messages),
                'source': 'last_real_request',
                'previewOnly': False,
            },
        }, message_limit=3)
        assistant_message = self.store.append_message(
            chat_id,
            role='assistant',
            content=assistant_text,
            metadata={
                'requestId': user_message['id'],
                'promptDebug': self._build_prompt_debug_summary_payload(full_prompt_debug),
            },
        )
        self.save_latest_prompt_debug(chat_id, full_prompt_debug)
        return TavernSendResult(
            request_id=user_message['id'],
            user_message=user_message,
            assistant_message=assistant_message,
            prompt_debug=prepared['promptDebug'],
        )

    def _trim_prompt_debug_payload(self, payload: dict[str, Any], *, message_limit: int = 3) -> dict[str, Any]:
        trimmed = dict(payload)
        messages = trimmed.get('messages')
        if isinstance(messages, list):
            normalized = [item for item in messages if isinstance(item, dict)]
            if message_limit > 0 and len(normalized) > message_limit:
                normalized = normalized[-message_limit:]
            trimmed['messages'] = normalized
        if isinstance(trimmed.get('summary'), dict):
            trimmed['summary'] = {
                **trimmed['summary'],
                'messageCount': len(trimmed.get('messages') or []),
            }
        return trimmed

    def _build_prompt_debug_summary_payload(self, payload: dict[str, Any]) -> dict[str, Any]:
        summary = payload.get('summary') if isinstance(payload.get('summary'), dict) else {}
        context_usage = payload.get('contextUsage') if isinstance(payload.get('contextUsage'), dict) else {}
        return {
            'presetId': str(payload.get('presetId') or '').strip(),
            'promptOrderId': str(payload.get('promptOrderId') or '').strip(),
            'summary': {
                **summary,
                'totalTokens': context_usage.get('totalTokens', summary.get('totalTokens')),
                'maxContext': context_usage.get('maxContext', summary.get('maxContext')),
            },
        }

    def save_latest_prompt_debug(self, chat_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        metadata = self.long_term_memory_service.ensure_metadata_shape({'metadata': metadata})
        metadata['latestPromptDebug'] = dict(payload)
        return self.store.update_chat(chat_id, {'metadata': metadata})

    def rebuild_and_save_latest_prompt_debug(self, chat_id: str) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None
        character = self.store.get_character(chat['characterId'])
        if character is None:
            return None

        history = self.store.list_chat_messages(chat_id)
        preset, prompt_order = self._resolve_preset_and_prompt_order(chat=chat)
        character_lore_bindings = self.store.list_character_lore_bindings(character['id'])
        persona = self.persona_service.resolve_for_chat(chat)
        variables = self.variable_service.snapshot_for_chat(chat)
        debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=self.store.list_prompt_blocks(),
            worldbook_entries=self._collect_effective_worldbook_entries(character['id']),
            character_lore_bindings=character_lore_bindings,
            history=history,
            user_text='',
            chat=chat,
            persona=persona,
            local_variables=variables.local,
            global_variables=variables.global_,
            provider_id=str((preset or {}).get('provider') or ''),
            model_name=str((preset or {}).get('model') or ''),
            allow_side_effects=False,
        )
        payload = self._trim_prompt_debug_payload({
            'presetId': debug.preset_id,
            'promptOrderId': debug.prompt_order_id,
            'matchedWorldbookEntries': debug.matched_worldbook_entries,
            'rejectedWorldbookEntries': debug.rejected_worldbook_entries,
            'characterLoreBindings': debug.character_lore_bindings,
            'blocks': debug.blocks,
            'messages': debug.messages,
            'renderedStoryString': debug.rendered_story_string,
            'renderedExamples': debug.rendered_examples,
            'runtimeContext': debug.runtime_context,
            'macroEffects': debug.macro_effects,
            'unknownMacros': debug.unknown_macros,
            'resolvedPersona': persona,
            'depthInserts': debug.depth_inserts,
            'contextUsage': debug.context_usage,
            'worldbookRuntime': dict(chat.get('metadata', {}).get('worldbookRuntime') or {}) if isinstance(chat.get('metadata'), dict) else {},
            'summary': {
                'matchedWorldbookCount': len(debug.matched_worldbook_entries),
                'rejectedWorldbookCount': len(debug.rejected_worldbook_entries),
                'blockCount': len(debug.blocks),
                'messageCount': len(debug.messages),
                'totalTokens': (debug.context_usage.get('totalTokens') if isinstance(debug.context_usage, dict) else None),
                'maxContext': (debug.context_usage.get('maxContext') if isinstance(debug.context_usage, dict) else None),
                'overLimitTokens': (((debug.context_usage.get('meta') or {}).get('trimPlan') or {}).get('overLimitTokens') if isinstance(debug.context_usage, dict) else None),
                'suggestedCutCount': (len((((debug.context_usage.get('meta') or {}).get('trimPlan') or {}).get('suggestedCuts') or [])) if isinstance(debug.context_usage, dict) else 0),
                'source': 'rebuild_after_summary',
                'previewOnly': False,
                'longTermMemoryCount': len(self.long_term_memory_service.list_items(chat)),
            },
        }, message_limit=3)
        return self.save_latest_prompt_debug(chat_id, payload)

    def compact_prompt_debug_history(self, chat_id: str) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None

        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        history = self.store.list_chat_messages(chat_id)
        latest_debug = metadata.get('latestPromptDebug') if isinstance(metadata.get('latestPromptDebug'), dict) else None

        if latest_debug is None:
            for message in reversed(history):
                if message.get('role') != 'assistant':
                    continue
                msg_meta = message.get('metadata') if isinstance(message.get('metadata'), dict) else {}
                candidate = msg_meta.get('promptDebug') if isinstance(msg_meta.get('promptDebug'), dict) else None
                if candidate is not None:
                    latest_debug = candidate
                    break

        if latest_debug is not None:
            metadata['latestPromptDebug'] = self._trim_prompt_debug_payload(dict(latest_debug), message_limit=3)
            chat = self.store.update_chat(chat_id, {'metadata': metadata}) or chat

        updated_count = 0
        for message in history:
            if message.get('role') != 'assistant':
                continue
            msg_meta = dict(message.get('metadata') or {}) if isinstance(message.get('metadata'), dict) else {}
            prompt_debug = msg_meta.get('promptDebug') if isinstance(msg_meta.get('promptDebug'), dict) else None
            if prompt_debug is None:
                continue
            compacted = self._build_prompt_debug_summary_payload(
                self._trim_prompt_debug_payload(dict(prompt_debug), message_limit=3),
            )
            if compacted == prompt_debug:
                continue
            msg_meta['promptDebug'] = compacted
            self.store.replace_message_metadata(str(message.get('id') or '').strip(), msg_meta)
            updated_count += 1

        return {
            'chat': chat,
            'updatedCount': updated_count,
        }

    def build_prompt_debug(self, chat_id: str) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        character = self.store.get_character(chat['characterId'])
        if character is None:
            raise ValueError('character not found')

        history = self.store.list_chat_messages(chat_id)
        current_worldbook_runtime = dict(chat.get('metadata', {}).get('worldbookRuntime') or {}) if isinstance(chat.get('metadata'), dict) else {}
        latest_chat_debug = chat.get('metadata', {}).get('latestPromptDebug') if isinstance(chat.get('metadata'), dict) else None
        if isinstance(latest_chat_debug, dict):
            latest_chat_debug = dict(latest_chat_debug)
            latest_chat_debug['worldbookRuntime'] = current_worldbook_runtime
            latest_chat_debug['summary'] = {
                **(latest_chat_debug.get('summary') if isinstance(latest_chat_debug.get('summary'), dict) else {}),
                'source': 'last_real_request',
                'previewOnly': False,
            }
            return self._trim_prompt_debug_payload(latest_chat_debug, message_limit=3)

        worldbook_entries = self._collect_effective_worldbook_entries(character['id'])
        preset, prompt_order = self._resolve_preset_and_prompt_order(chat=chat)
        character_lore_bindings = self.store.list_character_lore_bindings(character['id'])
        persona = self.persona_service.resolve_for_chat(chat)
        variables = self.variable_service.snapshot_for_chat(chat)
        debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=self.store.list_prompt_blocks(),
            worldbook_entries=worldbook_entries,
            character_lore_bindings=character_lore_bindings,
            history=history,
            user_text='',
            chat=chat,
            persona=persona,
            local_variables=variables.local,
            global_variables=variables.global_,
            provider_id=str((preset or {}).get('provider') or ''),
            model_name=str((preset or {}).get('model') or ''),
            allow_side_effects=False,
        )
        return self._trim_prompt_debug_payload({
            'presetId': debug.preset_id,
            'promptOrderId': debug.prompt_order_id,
            'matchedWorldbookEntries': debug.matched_worldbook_entries,
            'rejectedWorldbookEntries': debug.rejected_worldbook_entries,
            'characterLoreBindings': debug.character_lore_bindings,
            'blocks': debug.blocks,
            'messages': debug.messages,
            'renderedStoryString': debug.rendered_story_string,
            'renderedExamples': debug.rendered_examples,
            'runtimeContext': debug.runtime_context,
            'macroEffects': debug.macro_effects,
            'unknownMacros': debug.unknown_macros,
            'resolvedPersona': persona,
            'depthInserts': debug.depth_inserts,
            'contextUsage': debug.context_usage,
            'worldbookRuntime': current_worldbook_runtime,
            'summary': {
                'matchedWorldbookCount': len(debug.matched_worldbook_entries),
                'rejectedWorldbookCount': len(debug.rejected_worldbook_entries),
                'blockCount': len(debug.blocks),
                'messageCount': len(debug.messages),
                'totalTokens': (debug.context_usage.get('totalTokens') if isinstance(debug.context_usage, dict) else None),
                'maxContext': (debug.context_usage.get('maxContext') if isinstance(debug.context_usage, dict) else None),
                'overLimitTokens': (((debug.context_usage.get('meta') or {}).get('trimPlan') or {}).get('overLimitTokens') if isinstance(debug.context_usage, dict) else None),
                'suggestedCutCount': (len((((debug.context_usage.get('meta') or {}).get('trimPlan') or {}).get('suggestedCuts') or [])) if isinstance(debug.context_usage, dict) else 0),
                'source': 'preview_rebuild',
                'previewOnly': True,
            },
        }, message_limit=3)

    def _hidden_instruction_text(self, mode: str) -> str:
        normalized = str(mode or '').strip().lower()
        if normalized == 'continue':
            return '请紧接当前剧情自然续写，优先承接最近的互动、情绪、动作与场景，不要生硬跳转；若无明显新事件，就顺着当前节奏继续推进。'
        if normalized == 'twist':
            return '请在保持当前剧情连续性的前提下，引入一个自然的新变化、事件、线索、来人或冲突，让剧情出现新的转折，但不要硬切或脱离当前语境。'
        if normalized == 'describe':
            return '请延续当前场景，放慢节奏，重点加强动作、神态、环境、触感、声音与氛围等细节描写，先细致展开当前内容，不急着推动重大新事件。'
        return ''

    def resolve_hidden_instruction(self, *, mode: str = '', hidden_instruction: str = '') -> str:
        direct = str(hidden_instruction or '').strip()
        if direct:
            return direct
        return self._hidden_instruction_text(mode)

    def prepare_generation(self, chat_id: str, *, text: str, preset_id: str = '', hidden_instruction: str = '') -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        character = self.store.get_character(chat['characterId'])
        if character is None:
            raise ValueError('character not found')

        preset, prompt_order = self._resolve_preset_and_prompt_order(chat=chat, preset_id=preset_id)

        history = self.store.list_chat_messages(chat_id)
        prompt_blocks = self.store.list_prompt_blocks()
        worldbook_entries = self._collect_effective_worldbook_entries(character['id'])

        effective_text = text
        if hidden_instruction.strip():
            effective_text = f"{text.rstrip()}\n\n[Hidden instruction: {hidden_instruction.strip()}]"

        character_lore_bindings = self.store.list_character_lore_bindings(character['id'])
        persona = self.persona_service.resolve_for_chat(chat)
        variables = self.variable_service.snapshot_for_chat(chat)
        prompt_debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=prompt_blocks,
            worldbook_entries=worldbook_entries,
            character_lore_bindings=character_lore_bindings,
            history=history,
            user_text=effective_text,
            chat=chat,
            persona=persona,
            local_variables=variables.local,
            global_variables=variables.global_,
            provider_id=str((preset or {}).get('provider') or ''),
            model_name=str((preset or {}).get('model') or ''),
            allow_side_effects=True,
        )
        provider_id = str((preset or {}).get('provider') or (get_tavern_config().get('defaultProviderId') or '')).strip()
        return {
            'chat': chat,
            'character': character,
            'preset': preset,
            'promptOrder': prompt_order,
            'history': history,
            'messages': prompt_debug.messages,
            'promptDebug': prompt_debug,
            'providerId': provider_id,
            'hiddenInstruction': hidden_instruction.strip(),
            'sourceText': text,
            'persona': persona,
        }

    def merge_generation_provider(self, provider: dict[str, Any], preset: dict[str, Any] | None) -> dict[str, Any]:
        merged = dict(provider or {})
        if preset:
            if str(preset.get('model') or '').strip():
                merged['model'] = str(preset.get('model') or '').strip()
            merged['temperature'] = preset.get('temperature', merged.get('temperature', 1.0))
            merged['topP'] = preset.get('topP', merged.get('topP', 1.0))
            merged['frequencyPenalty'] = preset.get('frequencyPenalty', merged.get('frequencyPenalty', 0.0))
            merged['presencePenalty'] = preset.get('presencePenalty', merged.get('presencePenalty', 0.0))
            merged['topK'] = preset.get('topK', merged.get('topK', 0))
            merged['topA'] = preset.get('topA', merged.get('topA', 0.0))
            merged['minP'] = preset.get('minP', merged.get('minP', 0.0))
            merged['typicalP'] = preset.get('typicalP', merged.get('typicalP', 1.0))
            merged['repetitionPenalty'] = preset.get('repetitionPenalty', merged.get('repetitionPenalty', 1.0))
            merged['maxTokens'] = preset.get('maxTokens', merged.get('maxTokens', 0))
            merged['stopSequences'] = list(preset.get('stopSequences') or merged.get('stopSequences') or [])
            merged['thinkingEnabled'] = preset.get('thinkingEnabled', merged.get('thinkingEnabled', False))
            merged['thinkingBudget'] = preset.get('thinkingBudget', merged.get('thinkingBudget', 0))
            merged['reasoningEffort'] = str(preset.get('reasoningEffort', merged.get('reasoningEffort', '')) or '').strip()
        return merged

    def maybe_generate_summary(
        self,
        *,
        chat_id: str,
        provider_config: dict[str, Any],
    ) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None
        character = self.store.get_character(chat['characterId'])
        if character is None:
            return None
        history = self.store.list_chat_messages(chat_id)
        preset, prompt_order = self._resolve_preset_and_prompt_order(chat=chat)
        persona = self.persona_service.resolve_for_chat(chat)
        variables = self.variable_service.snapshot_for_chat(chat)
        prompt_debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=self.store.list_prompt_blocks(),
            worldbook_entries=self._collect_effective_worldbook_entries(character['id']),
            character_lore_bindings=self.store.list_character_lore_bindings(character['id']),
            history=history,
            user_text='',
            chat=chat,
            persona=persona,
            local_variables=variables.local,
            global_variables=variables.global_,
            provider_id=str((preset or {}).get('provider') or ''),
            model_name=str((preset or {}).get('model') or ''),
            allow_side_effects=False,
        )
        summaries = self.summarization_service.list_summaries(chat)
        effective_context_usage = dict(prompt_debug.context_usage or {})
        if not self.summarization_service.should_summarize(
            context_usage=effective_context_usage,
            chat=chat,
            message_count=len(history),
            all_messages=history,
            existing_summaries=summaries,
        ):
            return None

        generated: list[dict[str, Any]] = []
        working_chat = chat
        working_summaries = list(summaries)
        trigger_ratio = self.summarization_service.trigger_ratio(working_chat)
        target_ratio = self.summarization_service.target_ratio(working_chat)
        max_context = int(effective_context_usage.get('maxContext') or 0)
        total_tokens = int(effective_context_usage.get('totalTokens') or 0)
        current_ratio = ((total_tokens / max_context) if max_context > 0 and total_tokens > 0 else 0.0)

        for _ in range(8):
            if current_ratio < trigger_ratio and generated:
                break
            if current_ratio <= target_ratio and generated:
                break
            summary = self.summarization_service.generate_summary(
                chat=working_chat,
                character=character,
                all_messages=history,
                existing_summaries=working_summaries,
                provider_config=provider_config,
            )
            if summary is None:
                break
            generated.append(summary)
            metadata = self.summarization_service.append_summary_to_chat_metadata(chat=working_chat, summary=summary)
            updated = self.store.update_chat(chat_id, {'metadata': metadata})
            working_chat = updated or {**working_chat, 'metadata': metadata}
            working_summaries = self.summarization_service.list_summaries(working_chat)
            rebuilt = self.rebuild_and_save_latest_prompt_debug(chat_id)
            latest_chat = rebuilt or self.store.get_chat(chat_id) or working_chat
            latest_debug = ((latest_chat.get('metadata') or {}).get('latestPromptDebug') if isinstance(latest_chat.get('metadata'), dict) else None)
            latest_usage = (latest_debug.get('contextUsage') if isinstance(latest_debug, dict) and isinstance(latest_debug.get('contextUsage'), dict) else {})
            max_context = int(latest_usage.get('maxContext') or max_context or 0)
            total_tokens = int(latest_usage.get('totalTokens') or total_tokens or 0)
            current_ratio = ((total_tokens / max_context) if max_context > 0 and total_tokens > 0 else 0.0)
            if current_ratio <= target_ratio:
                break

        if not generated:
            return None

        memory_metadata = self.long_term_memory_service.extract_and_merge(
            chat=working_chat,
            new_summaries=generated,
            provider_config=provider_config,
        )
        updated_with_memory = self.store.update_chat(chat_id, {'metadata': memory_metadata})
        working_chat = updated_with_memory or {**working_chat, 'metadata': memory_metadata}
        self.rebuild_and_save_latest_prompt_debug(chat_id)
        refreshed_chat = self.store.get_chat(chat_id)
        return {
            'summary': generated[-1],
            'summaries': generated,
            'chat': refreshed_chat or working_chat,
        }

    def update_worldbook_runtime_after_turn(
        self,
        *,
        chat_id: str,
        matched_worldbook_entries: list[dict[str, Any]],
        rejected_worldbook_entries: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any] | None:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return None
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        runtime = dict(metadata.get('worldbookRuntime') or {}) if isinstance(metadata.get('worldbookRuntime'), dict) else {}
        entry_states = dict(runtime.get('entries') or {}) if isinstance(runtime.get('entries'), dict) else {}

        next_states: dict[str, dict[str, Any]] = {}
        for entry_id, raw_state in entry_states.items():
            if not isinstance(raw_state, dict):
                continue
            state = dict(raw_state)
            sticky_remaining = max(0, int(state.get('stickyRemaining') or 0) - 1)
            cooldown_remaining = max(0, int(state.get('cooldownRemaining') or 0) - 1)
            delay_remaining = max(0, int(state.get('delayRemaining') or 0) - 1)
            pending_activation = bool(state.get('pendingActivation'))
            activation_count = max(0, int(state.get('activationCount') or 0))
            last_activated_at = state.get('lastActivatedAt')
            if delay_remaining <= 0 and pending_activation:
                pending_activation = False
            if sticky_remaining > 0 or cooldown_remaining > 0 or delay_remaining > 0 or pending_activation or activation_count > 0 or last_activated_at:
                next_states[str(entry_id)] = {
                    'stickyRemaining': sticky_remaining,
                    'cooldownRemaining': cooldown_remaining,
                    'delayRemaining': delay_remaining,
                    'pendingActivation': pending_activation,
                    'activationCount': activation_count,
                    'lastActivatedAt': last_activated_at,
                }

        for item in rejected_worldbook_entries or []:
            if not isinstance(item, dict) or item.get('reason') != 'delay_scheduled':
                continue
            entry = item.get('entry') if isinstance(item.get('entry'), dict) else {}
            entry_id = str(entry.get('id') or '').strip()
            if not entry_id:
                continue
            delay = max(0, int(entry.get('delay') or ((item.get('details') or {}).get('delay') if isinstance(item.get('details'), dict) else 0) or 0))
            if delay <= 0:
                continue
            next_states[entry_id] = {
                **next_states.get(entry_id, {}),
                'stickyRemaining': max(0, int((next_states.get(entry_id, {}) or {}).get('stickyRemaining') or 0)),
                'cooldownRemaining': max(0, int((next_states.get(entry_id, {}) or {}).get('cooldownRemaining') or 0)),
                'delayRemaining': delay,
                'pendingActivation': True,
                'activationCount': max(0, int((next_states.get(entry_id, {}) or {}).get('activationCount') or 0)),
                'lastActivatedAt': (next_states.get(entry_id, {}) or {}).get('lastActivatedAt'),
            }

        now_ts = int(time.time())
        for entry in matched_worldbook_entries:
            entry_id = str(entry.get('id') or '').strip()
            if not entry_id:
                continue
            current = dict(next_states.get(entry_id) or {})
            sticky = max(0, int(entry.get('sticky') or 0))
            cooldown = max(0, int(entry.get('cooldown') or 0))
            current['stickyRemaining'] = max(max(0, int(current.get('stickyRemaining') or 0)), sticky)
            current['cooldownRemaining'] = max(max(0, int(current.get('cooldownRemaining') or 0)), cooldown)
            current['delayRemaining'] = 0
            current['pendingActivation'] = False
            current['activationCount'] = max(0, int(current.get('activationCount') or 0)) + 1
            current['lastActivatedAt'] = now_ts
            next_states[entry_id] = current

        runtime['entries'] = next_states
        metadata['worldbookRuntime'] = runtime
        updated = self.store.update_chat(chat_id, {'metadata': metadata})
        return updated or self.store.get_chat(chat_id)

    def _resolve_preset_and_prompt_order(
        self,
        *,
        chat: dict[str, Any],
        preset_id: str = '',
    ) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        effective_preset_id = preset_id or chat.get('presetId') or ''
        preset = None
        presets = self.store.list_presets()
        if effective_preset_id:
            preset = next((item for item in presets if item['id'] == effective_preset_id), None)
        if preset is None and presets:
            preset = presets[0]

        prompt_order = None
        prompt_orders = self.store.list_prompt_orders()
        if prompt_orders:
            prompt_order_id = str((preset or {}).get('promptOrderId') or chat.get('promptOrderId') or '').strip()
            if prompt_order_id:
                prompt_order = next((item for item in prompt_orders if str(item.get('id') or '').strip() == prompt_order_id), None)
            if prompt_order is None:
                prompt_order = prompt_orders[0]
        return preset, prompt_order

    def _latest_real_prompt_debug(self, history: list[dict[str, Any]]) -> dict[str, Any] | None:
        for message in reversed(history):
            if str(message.get('role') or '').strip() != 'assistant':
                continue
            metadata = message.get('metadata') if isinstance(message.get('metadata'), dict) else {}
            prompt_debug = metadata.get('promptDebug') if isinstance(metadata.get('promptDebug'), dict) else None
            if not prompt_debug:
                continue
            messages = prompt_debug.get('messages') if isinstance(prompt_debug.get('messages'), list) else None
            blocks = prompt_debug.get('blocks') if isinstance(prompt_debug.get('blocks'), list) else None
            if messages is None or blocks is None:
                continue
            return dict(prompt_debug)
        return None

    def _collect_effective_worldbook_entries(self, character_id: str) -> list[dict[str, Any]]:
        worldbooks = [
            item
            for item in self.store.list_worldbooks()
            if item.get('enabled', True)
        ]
        worldbook_map = {item['id']: item for item in worldbooks}
        global_worldbook_ids = {
            str(item.get('id') or '').strip()
            for item in worldbooks
            if str(item.get('scope') or 'local').strip().lower() == 'global'
        }
        collected: list[dict[str, Any]] = []
        seen_ids: set[str] = set()

        for binding in self.store.list_character_lore_bindings(character_id):
            worldbook_id = str(binding.get('worldbookId') or '').strip()
            if not worldbook_id or worldbook_id not in worldbook_map:
                continue
            for entry in self.store.list_worldbook_entries(worldbook_id):
                entry_id = str(entry.get('id') or '').strip()
                if entry_id and entry_id not in seen_ids:
                    annotated = dict(entry)
                    annotated['_sourceScope'] = 'character'
                    annotated['_binding'] = binding
                    annotated['_worldbookScope'] = str(worldbook_map[worldbook_id].get('scope') or 'local')
                    if binding.get('priorityOverride') is not None:
                        annotated['priority'] = int(binding.get('priorityOverride') or 0)
                    collected.append(annotated)
                    seen_ids.add(entry_id)

        for worldbook_id in global_worldbook_ids:
            for entry in self.store.list_worldbook_entries(worldbook_id):
                entry_id = str(entry.get('id') or '').strip()
                if entry_id and entry_id not in seen_ids:
                    annotated = dict(entry)
                    annotated['_sourceScope'] = 'global'
                    annotated['_worldbookScope'] = 'global'
                    collected.append(annotated)
                    seen_ids.add(entry_id)
        return collected

    def _iso_now(self) -> str:
        from datetime import datetime, timezone

        return datetime.now(timezone.utc).isoformat()

    def _resolve_scene_reference_image(self, character: dict[str, Any]) -> Path | str:
        _ = character
        image_provider = get_tavern_image_provider()
        reference_url = str(image_provider.get('referenceImageUrl') or image_provider.get('reference_url') or '').strip()
        if reference_url:
            return reference_url
        fallback = Path(__file__).resolve().parents[4] / 'assets' / 'avatars' / 'tavern_default.png'
        if fallback.exists() and fallback.is_file():
            return fallback
        raise FileNotFoundError('default tavern reference image not found')

    def _build_character_import_warnings(self, character: dict[str, Any]) -> list[str]:
        warnings: list[str] = []
        if not character.get('firstMessage'):
            warnings.append('角色缺少 first message，已按空字符串导入。')
        if not character.get('exampleDialogues'):
            warnings.append('角色缺少 examples，已按空字符串导入。')
        if not character.get('avatarPath'):
            raw_avatar = str((character.get('rawJson') or {}).get('avatar') or ((character.get('metadata') or {}).get('cardData') or {}).get('avatar') or '').strip()
            if raw_avatar:
                warnings.append('发现 avatar 字段，但头像资源未能成功落盘。')
        return warnings

    def _materialize_character_avatar(self, character: dict[str, Any], *, filename: str, raw_bytes: bytes | None = None) -> dict[str, Any]:
        if not self.uploads_dir:
            return character
        avatar_bytes = raw_bytes
        if avatar_bytes is None:
            avatar_ref = str(character.get('avatarPath') or '').strip()
            if not avatar_ref or avatar_ref.startswith('/uploads/'):
                return character
            avatar_bytes = self._fetch_avatar_bytes(avatar_ref)
        if not avatar_bytes:
            return character
        ext = self._guess_image_extension(avatar_bytes, fallback=Path(filename).suffix or '.png')
        rel = Path('tavern') / 'avatars' / f"{character['id']}{ext}"
        target = (self.uploads_dir / rel).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(avatar_bytes)
        updated_metadata = dict(character.get('metadata') or {})
        updated_metadata['storedAvatarPath'] = f"/uploads/{rel.as_posix()}"
        updated = self.store.update_character_import_fields(
            character['id'],
            {
                'avatarPath': f"/uploads/{rel.as_posix()}",
                'metadata': updated_metadata,
            },
        )
        return updated or character

    def _fetch_avatar_bytes(self, avatar_ref: str) -> bytes | None:
        value = str(avatar_ref or '').strip()
        if not value:
            return None
        lowered = value.lower()
        if lowered.startswith('data:image/') and ',' in value:
            import base64
            payload = value.split(',', 1)[1]
            return base64.b64decode(payload)
        if lowered.startswith('http://') or lowered.startswith('https://'):
            req = Request(value, headers={'User-Agent': 'AliceChat Tavern Importer/1.0'})
            with urlopen(req, timeout=20) as resp:
                return resp.read()
        path = Path(os.path.expanduser(value))
        if path.exists() and path.is_file():
            return path.read_bytes()
        return None

    def _guess_image_extension(self, raw: bytes, *, fallback: str) -> str:
        kind = None
        try:
            import imghdr
            kind = imghdr.what(None, h=raw)
        except Exception:
            kind = None
        mapping = {
            'jpeg': '.jpg',
            'png': '.png',
            'gif': '.gif',
            'webp': '.webp',
            'bmp': '.bmp',
        }
        return mapping.get(kind, fallback if fallback.startswith('.') else f'.{fallback}')

    def _find_zip_member(self, archive: zipfile.ZipFile, name: str) -> str | None:
        target = name.lower()
        for item in archive.namelist():
            if item.lower().endswith(target):
                return item
        return None

    def _find_charx_icon_member(self, archive: zipfile.ZipFile, payload: dict[str, Any]) -> str | None:
        assets = self._charx_assets(payload)
        candidates: list[str] = []
        for asset in assets:
            asset_type = str(asset.get('type') or '').strip().lower()
            if asset_type not in {'icon', 'avatar', 'user_icon'}:
                continue
            uri = str(asset.get('uri') or '').strip()
            zip_path = self._charx_uri_to_member(uri)
            if zip_path:
                candidates.append(zip_path)
        for candidate in candidates:
            for member in archive.namelist():
                normalized = member.replace('\\', '/').lstrip('./')
                if normalized == candidate:
                    return member
        return None

    def _charx_uri_to_member(self, uri: str) -> str | None:
        lowered = uri.lower()
        prefixes = ('embeded://', 'embedded://', '__asset:')
        for prefix in prefixes:
            if lowered.startswith(prefix):
                value = uri[len(prefix):].replace('\\', '/').lstrip('./')
                return value
        return None

    def _charx_assets(self, payload: dict[str, Any]) -> list[dict[str, Any]]:
        data = payload.get('data') if isinstance(payload.get('data'), dict) else payload
        assets = data.get('assets') if isinstance(data, dict) else None
        if not isinstance(assets, list):
            return []
        return [asset for asset in assets if isinstance(asset, dict)]

    def _persist_charx_auxiliary_assets(
        self,
        archive: zipfile.ZipFile,
        payload: dict[str, Any],
        character: dict[str, Any],
    ) -> dict[str, Any]:
        if not self.uploads_dir:
            return {'sprites': 0, 'backgrounds': 0, 'misc': 0, 'paths': {'sprites': [], 'backgrounds': [], 'misc': []}}
        summary: dict[str, Any] = {
            'sprites': 0,
            'backgrounds': 0,
            'misc': 0,
            'paths': {'sprites': [], 'backgrounds': [], 'misc': []},
        }
        character_id = str(character.get('id') or '').strip()
        if not character_id:
            return summary
        for index, asset in enumerate(self._charx_assets(payload)):
            asset_type = str(asset.get('type') or '').strip().lower()
            if asset_type in {'icon', 'avatar', 'user_icon'}:
                continue
            uri = str(asset.get('uri') or '').strip()
            member_name = self._charx_uri_to_member(uri)
            if not member_name:
                continue
            member = None
            for archive_name in archive.namelist():
                normalized = archive_name.replace('\\', '/').lstrip('./')
                if normalized == member_name:
                    member = archive_name
                    break
            if not member:
                continue
            try:
                raw = archive.read(member)
            except KeyError:
                continue
            ext = Path(member_name).suffix.lower() or self._extension_from_asset(asset)
            category = self._charx_asset_category(asset_type)
            base_name = self._charx_asset_base_name(asset, category=category, index=index)
            rel_dir = Path('tavern') / 'characters' / character_id / category
            target_dir = (self.uploads_dir / rel_dir).resolve()
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / f'{base_name}{ext}'
            target.write_bytes(raw)
            key = self._charx_summary_key(category)
            summary[key] += 1
            summary['paths'][key].append(f"/uploads/{(rel_dir / f'{base_name}{ext}').as_posix()}")
        return summary

    def _charx_asset_category(self, asset_type: str) -> str:
        lowered = asset_type.lower()
        if lowered in {'emotion', 'expression'}:
            return 'sprites'
        if lowered in {'background'}:
            return 'backgrounds'
        return 'misc'

    def _charx_summary_key(self, category: str) -> str:
        if category == 'sprites':
            return 'sprites'
        if category == 'backgrounds':
            return 'backgrounds'
        return 'misc'

    def _charx_asset_base_name(self, asset: dict[str, Any], *, category: str, index: int) -> str:
        import re
        name = str(asset.get('name') or '').strip().lower()
        if not name:
            name = f'{category[:-1] if category.endswith("s") else category}-{index}'
        name = re.sub(r'\.[a-z0-9]+$', '', name)
        separator = '-' if category == 'sprites' else '_'
        name = re.sub(r'[^a-z0-9]+', separator, name).strip(separator)
        return name or f'{category}-{index}'

    def _extension_from_asset(self, asset: dict[str, Any]) -> str:
        ext = str(asset.get('ext') or '').strip().lower().lstrip('.')
        return f'.{ext}' if ext else '.png'

    def _build_placeholder_reply(self, character: dict[str, Any], user_text: str) -> str:
        name = str(character.get('name') or '角色').strip() or '角色'
        if not user_text.strip():
            return f'{name} 正安静地看着你。'
        return f'{name} 已收到：{user_text}'
