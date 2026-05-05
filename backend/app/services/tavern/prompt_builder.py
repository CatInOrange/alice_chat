from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(slots=True)
class PromptDebugResult:
    preset_id: str
    prompt_order_id: str
    matched_worldbook_entries: list[dict[str, Any]]
    character_lore_bindings: list[dict[str, Any]]
    blocks: list[dict[str, Any]]
    messages: list[dict[str, Any]]


class PromptBuilder:
    """Tavern prompt assembly pipeline.

    Current target is closer to SillyTavern semantics than a generic block list:
    - prompt order decides semantic section order
    - world info is split into wiBefore / wiAfter / atDepth style injections
    - story_string / example_separator / chat_start matter
    - debug output should reveal the exact assembled structure
    """

    _IDENTIFIER_MAP = {
        'main': 'system_prompt',
        'personaDescription': 'persona',
        'charDescription': 'character_description',
        'charPersonality': 'character_personality',
        'scenario': 'character_scenario',
        'dialogueExamples': 'example_messages',
        'worldInfoBefore': 'world_info_before',
        'worldInfoAfter': 'world_info_after',
        'chatHistory': 'chat_history',
        'jailbreak': 'post_history_instructions',
        'nsfw': 'nsfw',
    }

    def build_messages(
        self,
        *,
        character: dict[str, Any],
        preset: dict[str, Any] | None,
        prompt_order: dict[str, Any] | None,
        prompt_blocks: list[dict[str, Any]] | None,
        worldbook_entries: list[dict[str, Any]] | None,
        character_lore_bindings: list[dict[str, Any]] | None,
        history: list[dict[str, Any]] | None,
        user_text: str,
        chat: dict[str, Any] | None = None,
    ) -> PromptDebugResult:
        history = list(history or [])
        prompt_blocks = list(prompt_blocks or [])
        matched_worldbook_entries = self._match_worldbook_entries(
            entries=worldbook_entries or [],
            history=history,
            user_text=user_text,
            character=character,
        )
        ordered_blocks = self._build_ordered_blocks(
            character=character,
            preset=preset or {},
            prompt_order=prompt_order or {},
            prompt_blocks=prompt_blocks,
            matched_worldbook_entries=matched_worldbook_entries,
            history=history,
            user_text=user_text,
            chat=chat or {},
        )
        messages = self._render_messages(
            ordered_blocks=ordered_blocks,
            history=history,
            user_text=user_text,
            preset=preset or {},
            chat=chat or {},
        )
        return PromptDebugResult(
            preset_id=str((preset or {}).get('id') or ''),
            prompt_order_id=str((prompt_order or {}).get('id') or ''),
            matched_worldbook_entries=matched_worldbook_entries,
            character_lore_bindings=list(character_lore_bindings or []),
            blocks=ordered_blocks,
            messages=messages,
        )

    def _build_ordered_blocks(
        self,
        *,
        character: dict[str, Any],
        preset: dict[str, Any],
        prompt_order: dict[str, Any],
        prompt_blocks: list[dict[str, Any]],
        matched_worldbook_entries: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        chat: dict[str, Any],
    ) -> list[dict[str, Any]]:
        world_before = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'before'
        ]
        world_after = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'after'
        ]
        world_depth = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'at_depth'
        ]

        semantic = {
            'system_prompt': self._block(
                name='system_prompt',
                kind='system',
                position='in_prompt',
                role='system',
                content=self._default_system_prompt(),
                source='builtin',
            ),
            'persona': self._block(
                name='persona',
                kind='persona',
                position='in_prompt',
                role='system',
                content='',
                source='persona',
            ),
            'character_description': self._block(
                name='character_description',
                kind='character',
                position='in_prompt',
                role='system',
                content=str(character.get('description') or ''),
                source='character',
            ),
            'character_personality': self._block(
                name='character_personality',
                kind='character',
                position='in_prompt',
                role='system',
                content=str(character.get('personality') or ''),
                source='character',
            ),
            'character_scenario': self._block(
                name='character_scenario',
                kind='scenario',
                position='in_prompt',
                role='system',
                content=str(character.get('scenario') or ''),
                source='character',
            ),
            'example_messages': self._block(
                name='example_messages',
                kind='example_messages',
                position='examples',
                role='system',
                content=str(character.get('exampleDialogues') or ''),
                source='character',
            ),
            'world_info_before': self._block(
                name='world_info_before',
                kind='world_info',
                position='in_prompt',
                role='system',
                content='\n\n'.join(self._entry_content(entry) for entry in world_before),
                source='worldbook',
                meta={'entryIds': [entry.get('id') for entry in world_before]},
            ),
            'world_info_after': self._block(
                name='world_info_after',
                kind='world_info',
                position='in_prompt',
                role='system',
                content='\n\n'.join(self._entry_content(entry) for entry in world_after),
                source='worldbook',
                meta={'entryIds': [entry.get('id') for entry in world_after]},
            ),
            'chat_history': self._block(
                name='chat_history',
                kind='chat_history',
                position='history',
                role='history',
                content=f'{len(history)} messages',
                source='runtime',
            ),
            'post_history_instructions': self._block(
                name='post_history_instructions',
                kind='custom',
                position='post_history',
                role='system',
                content='',
                source='builtin',
            ),
            'nsfw': self._block(
                name='nsfw',
                kind='custom',
                position='post_history',
                role='system',
                content='',
                source='builtin',
            ),
        }

        order_items = [
            item for item in (prompt_order.get('items') or [])
            if isinstance(item, dict)
        ]
        if not order_items:
            order_items = [
                {'identifier': 'main', 'enabled': True, 'order_index': 0},
                {'identifier': 'worldInfoBefore', 'enabled': True, 'order_index': 10},
                {'identifier': 'charDescription', 'enabled': True, 'order_index': 20},
                {'identifier': 'charPersonality', 'enabled': True, 'order_index': 30},
                {'identifier': 'scenario', 'enabled': True, 'order_index': 40},
                {'identifier': 'worldInfoAfter', 'enabled': True, 'order_index': 50},
                {'identifier': 'dialogueExamples', 'enabled': True, 'order_index': 60},
                {'identifier': 'chatHistory', 'enabled': True, 'order_index': 70},
            ]

        ordered_blocks: list[dict[str, Any]] = []
        seen_kinds: set[str] = set()
        for item in sorted(order_items, key=lambda it: int(it.get('order_index') or 0)):
            if item.get('enabled') is False:
                continue
            identifier = str(item.get('identifier') or '').strip()
            semantic_key = self._IDENTIFIER_MAP.get(identifier)
            if not semantic_key or semantic_key not in semantic:
                continue
            if semantic_key in seen_kinds:
                continue
            block = dict(semantic[semantic_key])
            block['meta'] = {
                **(block.get('meta') or {}),
                'identifier': identifier,
                'orderIndex': int(item.get('order_index') or 0),
            }
            ordered_blocks.append(block)
            seen_kinds.add(semantic_key)

        for block in prompt_blocks:
            if not block.get('enabled', True):
                continue
            injection_mode = str(block.get('injectionMode') or 'position').strip() or 'position'
            position = 'at_depth' if injection_mode == 'depth' else 'post_history'
            ordered_blocks.append(self._block(
                name=str(block.get('name') or block.get('id') or 'custom_block'),
                kind=str(block.get('kind') or 'custom'),
                position=position,
                role='system',
                content=str(block.get('content') or ''),
                depth=block.get('depth'),
                source='prompt_block',
                meta={
                    'blockId': block.get('id'),
                    'roleScope': block.get('roleScope'),
                },
            ))

        if chat.get('authorNoteEnabled') and str(chat.get('authorNote') or '').strip():
            ordered_blocks.append(self._block(
                name='author_note',
                kind='author_note',
                position='at_depth',
                role='system',
                content=str(chat.get('authorNote') or '').strip(),
                depth=int(chat.get('authorNoteDepth') or 4),
                source='chat',
            ))

        for entry in world_depth:
            ordered_blocks.append(self._block(
                name=f"worldbook:{entry.get('id') or ''}",
                kind='world_info',
                position='at_depth',
                role='system',
                content=self._entry_content(entry),
                depth=entry.get('depth'),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                },
            ))

        return ordered_blocks

    def _render_messages(
        self,
        *,
        ordered_blocks: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        preset: dict[str, Any],
        chat: dict[str, Any],
    ) -> list[dict[str, Any]]:
        system_text = self._render_story_string(ordered_blocks, preset)
        example_text = self._build_examples_block(ordered_blocks, preset)
        post_history_texts = [
            str(block.get('content') or '').strip()
            for block in ordered_blocks
            if block.get('position') == 'post_history' and str(block.get('content') or '').strip()
        ]
        depth_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'at_depth' and str(block.get('content') or '').strip()
        ]

        messages: list[dict[str, Any]] = []
        if system_text.strip():
            messages.append({'role': str(preset.get('storyStringRole') or 'system'), 'content': system_text})
        if example_text.strip():
            messages.append({'role': 'system', 'content': example_text})

        rendered_history = [
            {
                'role': str(item.get('role') or 'user'),
                'content': str(item.get('content') or item.get('text') or ''),
            }
            for item in history
            if str(item.get('content') or item.get('text') or '').strip()
        ]

        if rendered_history:
            for i, message in enumerate(rendered_history):
                depth_from_end = len(rendered_history) - 1 - i
                for block in depth_blocks:
                    if int(block.get('depth') or 0) == depth_from_end:
                        messages.append({'role': 'system', 'content': self._decorate_depth_block(block)})
                messages.append(message)
        else:
            for block in depth_blocks:
                if int(block.get('depth') or 0) >= 0:
                    messages.append({'role': 'system', 'content': self._decorate_depth_block(block)})

        for text in post_history_texts:
            messages.append({'role': 'system', 'content': text})

        if user_text.strip():
            chat_start = str(preset.get('chatStart') or '').strip()
            final_user = user_text.strip()
            if chat_start and not rendered_history:
                final_user = f'{chat_start}\n{final_user}'
            messages.append({'role': 'user', 'content': final_user})

        return messages

    def _render_story_string(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any]) -> str:
        story_string = str(preset.get('storyString') or '').strip()
        if not story_string:
            story_string = (
                "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}"
                "{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{char}}'s personality: {{personality}}\n{{/if}}"
                "{{#if scenario}}Scenario: {{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}"
            )

        values = {
            'system': self._block_content(ordered_blocks, 'system_prompt'),
            'wiBefore': self._block_content(ordered_blocks, 'world_info_before'),
            'description': self._block_content(ordered_blocks, 'character_description'),
            'personality': self._block_content(ordered_blocks, 'character_personality'),
            'scenario': self._block_content(ordered_blocks, 'character_scenario'),
            'wiAfter': self._block_content(ordered_blocks, 'world_info_after'),
            'persona': self._block_content(ordered_blocks, 'persona'),
            'char': 'Character',
        }

        rendered = story_string
        rendered = rendered.replace("{{char}}", values['char'])
        for key, value in values.items():
            rendered = rendered.replace(f'{{{{{key}}}}}', value)
            rendered = rendered.replace(f'{{{{#{"if"} {key}}}}}', '')
            rendered = rendered.replace('{{/if}}', '')
        lines = [line.rstrip() for line in rendered.splitlines()]
        return '\n'.join(line for line in lines if line.strip()).strip()

    def _build_examples_block(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any]) -> str:
        examples = self._block_content(ordered_blocks, 'example_messages')
        if not examples:
            return ''
        separator = str(preset.get('exampleSeparator') or '').strip()
        if not separator:
            return examples
        return f'{separator}\n{examples}'

    def _match_worldbook_entries(
        self,
        *,
        entries: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        character: dict[str, Any],
    ) -> list[dict[str, Any]]:
        corpus_parts = [user_text]
        corpus_parts.extend(str(item.get('content') or item.get('text') or '') for item in history[-8:])
        corpus_parts.extend([
            str(character.get('name') or ''),
            str(character.get('description') or ''),
            str(character.get('scenario') or ''),
        ])
        corpus = '\n'.join(part for part in corpus_parts if part).lower()

        matched: list[dict[str, Any]] = []
        for entry in entries:
            if not entry.get('enabled', True):
                continue
            if entry.get('constant'):
                matched.append(entry)
                continue
            keys = [str(key).strip().lower() for key in (entry.get('keys') or []) if str(key).strip()]
            if not keys:
                continue
            if any(key in corpus for key in keys):
                secondary = [str(key).strip().lower() for key in (entry.get('secondaryKeys') or []) if str(key).strip()]
                if secondary and not any(key in corpus for key in secondary):
                    continue
                matched.append(entry)

        matched.sort(
            key=lambda item: (
                -int(item.get('priority') or 0),
                str(item.get('groupName') or ''),
                str(item.get('id') or ''),
            ),
        )
        return matched

    def _map_worldbook_position(self, value: str) -> str:
        mapping = {
            'before_character': 'before',
            'before_chat_history': 'before',
            'after_character': 'after',
            'before_example_messages': 'after',
            'before_last_user': 'after',
            'at_depth': 'at_depth',
        }
        return mapping.get(value, 'before')

    def _entry_content(self, entry: dict[str, Any]) -> str:
        label = str(entry.get('groupName') or '').strip()
        content = str(entry.get('content') or '').strip()
        if label:
            return f'[{label}]\n{content}'
        return content

    def _block_content(self, ordered_blocks: list[dict[str, Any]], name: str) -> str:
        for block in ordered_blocks:
            if str(block.get('name') or '') == name:
                return str(block.get('content') or '').strip()
        return ''

    def _decorate_depth_block(self, block: dict[str, Any]) -> str:
        title = str(block.get('name') or 'depth_block')
        if title == 'author_note':
            return f"[Author's Note]\n{str(block.get('content') or '').strip()}"
        if str(block.get('source') or '') == 'worldbook':
            return f"[World Info]\n{str(block.get('content') or '').strip()}"
        return str(block.get('content') or '').strip()

    def _default_system_prompt(self) -> str:
        return (
            "Write the next reply in a fictional chat between {{char}} and {{user}}. "
            "Stay in character, be coherent with the established scenario, and avoid repetition."
        )

    def _block(
        self,
        *,
        name: str,
        kind: str,
        position: str,
        role: str,
        content: str,
        source: str,
        depth: Any = None,
        meta: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return {
            'name': name,
            'kind': kind,
            'position': position,
            'role': role,
            'content': content,
            'depth': depth,
            'source': source,
            'meta': meta or {},
        }
