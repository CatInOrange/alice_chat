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

from ...config import get_tavern_config
from ...store.tavern import TavernStore
from .prompt_builder import PromptBuilder, PromptDebugResult


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
    ):
        self.store = store or TavernStore()
        self.prompt_builder = prompt_builder or PromptBuilder()
        self.uploads_dir = uploads_dir

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

    # Chat
    def create_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.store.create_chat(payload)

    def list_chats(self) -> list[dict[str, Any]]:
        return self.store.list_chats()

    def get_chat(self, chat_id: str) -> dict[str, Any] | None:
        return self.store.get_chat(chat_id)

    def delete_chat(self, chat_id: str) -> bool:
        return self.store.delete_chat(chat_id)

    def update_chat(self, chat_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self.store.update_chat(chat_id, payload)

    def list_chat_messages(self, chat_id: str) -> list[dict[str, Any]]:
        return self.store.list_chat_messages(chat_id)

    def send_message(self, chat_id: str, *, text: str, preset_id: str = '') -> TavernSendResult:
        prepared = self.prepare_generation(chat_id, text=text, preset_id=preset_id)
        user_message = self.store.append_message(chat_id, role='user', content=text)
        assistant_text = self._build_placeholder_reply(prepared['character'], text)
        assistant_message = self.store.append_message(
            chat_id,
            role='assistant',
            content=assistant_text,
            metadata={
                'requestId': user_message['id'],
                'promptDebug': {
                    'presetId': prepared['promptDebug'].preset_id,
                    'promptOrderId': prepared['promptDebug'].prompt_order_id,
                },
            },
        )
        return TavernSendResult(
            request_id=user_message['id'],
            user_message=user_message,
            assistant_message=assistant_message,
            prompt_debug=prepared['promptDebug'],
        )

    def build_prompt_debug(self, chat_id: str) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        character = self.store.get_character(chat['characterId'])
        if character is None:
            raise ValueError('character not found')
        history = self.store.list_chat_messages(chat_id)
        worldbook_entries = self._collect_effective_worldbook_entries(character['id'])
        preset = None
        prompt_order = None
        effective_preset_id = str(chat.get('presetId') or '').strip()
        presets = self.store.list_presets()
        if effective_preset_id:
            preset = next((item for item in presets if item['id'] == effective_preset_id), None)
        if preset is None and presets:
            preset = presets[0]
        prompt_order_id = str((preset or {}).get('promptOrderId') or '').strip()
        if prompt_order_id:
            prompt_order = self.store.get_prompt_order(prompt_order_id)
        debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=self.store.list_prompt_blocks(),
            worldbook_entries=worldbook_entries,
            character_lore_bindings=[],
            history=history,
            user_text='',
            chat=chat,
        )
        return {
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
            'depthInserts': debug.depth_inserts,
            'summary': {
                'matchedWorldbookCount': len(debug.matched_worldbook_entries),
                'rejectedWorldbookCount': len(debug.rejected_worldbook_entries),
                'blockCount': len(debug.blocks),
                'messageCount': len(debug.messages),
            },
        }

    def prepare_generation(self, chat_id: str, *, text: str, preset_id: str = '') -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        character = self.store.get_character(chat['characterId'])
        if character is None:
            raise ValueError('character not found')

        effective_preset_id = preset_id or chat.get('presetId') or ''
        preset = None
        prompt_order = None
        if effective_preset_id:
            preset = next((item for item in self.store.list_presets() if item['id'] == effective_preset_id), None)
            prompt_order_id = str((preset or {}).get('promptOrderId') or '').strip()
            if prompt_order_id:
                prompt_order = self.store.get_prompt_order(prompt_order_id)
        if preset is None:
            presets = self.store.list_presets()
            preset = presets[0] if presets else None
            prompt_order_id = str((preset or {}).get('promptOrderId') or '').strip()
            if prompt_order_id:
                prompt_order = self.store.get_prompt_order(prompt_order_id)

        history = self.store.list_chat_messages(chat_id)
        prompt_blocks = self.store.list_prompt_blocks()
        worldbook_entries = self._collect_effective_worldbook_entries(character['id'])

        prompt_debug = self.prompt_builder.build_messages(
            character=character,
            preset=preset,
            prompt_order=prompt_order,
            prompt_blocks=prompt_blocks,
            worldbook_entries=worldbook_entries,
            character_lore_bindings=[],
            history=history,
            user_text=text,
            chat=chat,
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
        }

    def merge_generation_provider(self, provider: dict[str, Any], preset: dict[str, Any] | None) -> dict[str, Any]:
        merged = dict(provider or {})
        if preset:
            if str(preset.get('model') or '').strip():
                merged['model'] = str(preset.get('model') or '').strip()
            merged['temperature'] = preset.get('temperature', merged.get('temperature', 1.0))
            merged['topP'] = preset.get('topP', merged.get('topP', 1.0))
            merged['maxTokens'] = preset.get('maxTokens', merged.get('maxTokens', 0))
            merged['stopSequences'] = list(preset.get('stopSequences') or merged.get('stopSequences') or [])
        return merged

    def _collect_effective_worldbook_entries(self, character_id: str) -> list[dict[str, Any]]:
        worldbook_map = {
            item['id']: item
            for item in self.store.list_worldbooks()
            if item.get('enabled', True)
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
                    collected.append(entry)
                    seen_ids.add(entry_id)

        for worldbook_id in worldbook_map:
            for entry in self.store.list_worldbook_entries(worldbook_id):
                entry_id = str(entry.get('id') or '').strip()
                if entry_id and entry_id not in seen_ids:
                    collected.append(entry)
                    seen_ids.add(entry_id)
        return collected

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
