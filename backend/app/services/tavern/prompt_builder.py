from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any

from .prompt_runtime import PromptRuntimeContext, PromptTemplateRenderer, build_prompt_runtime_context


@dataclass(slots=True)
class PromptDebugResult:
    preset_id: str
    prompt_order_id: str
    matched_worldbook_entries: list[dict[str, Any]]
    character_lore_bindings: list[dict[str, Any]]
    blocks: list[dict[str, Any]]
    messages: list[dict[str, Any]]
    rendered_story_string: str
    rendered_examples: str
    runtime_context: dict[str, str]
    rejected_worldbook_entries: list[dict[str, Any]]
    depth_inserts: list[dict[str, Any]]


class PromptBuilder:
    """Tavern prompt assembly pipeline.

    Current target is closer to SillyTavern semantics than a generic block list:
    - prompt order decides semantic section order
    - world info is split into wiBefore / wiAfter / atDepth style injections
    - story_string / example_separator / chat_start matter
    - debug output should reveal the exact assembled structure
    """

    def __init__(self) -> None:
        self.renderer = PromptTemplateRenderer()

    _IDENTIFIER_MAP = {
        'main': 'system_prompt',
        'builtin_system': 'system_prompt',
        'personaDescription': 'persona',
        'builtin_persona': 'persona',
        'charDescription': 'character_description',
        'builtin_character': 'character_description',
        'charPersonality': 'character_personality',
        'scenario': 'character_scenario',
        'builtin_scenario': 'character_scenario',
        'dialogueExamples': 'example_messages',
        'builtin_examples': 'example_messages',
        'worldInfoBefore': 'world_info_before',
        'builtin_worldbook': 'world_info_before',
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
        runtime_context = build_prompt_runtime_context(
            character=character,
            chat=chat or {},
            history=history,
            user_text=user_text,
        )
        matched_worldbook_entries, rejected_worldbook_entries = self._match_worldbook_entries(
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
        messages, rendered_story_string, rendered_examples, depth_inserts = self._render_messages(
            ordered_blocks=ordered_blocks,
            history=history,
            user_text=user_text,
            preset=preset or {},
            chat=chat or {},
            runtime_context=runtime_context,
        )
        return PromptDebugResult(
            preset_id=str((preset or {}).get('id') or ''),
            prompt_order_id=str((prompt_order or {}).get('id') or ''),
            matched_worldbook_entries=matched_worldbook_entries,
            character_lore_bindings=list(character_lore_bindings or []),
            blocks=ordered_blocks,
            messages=messages,
            rendered_story_string=rendered_story_string,
            rendered_examples=rendered_examples,
            runtime_context=runtime_context.preview(),
            rejected_worldbook_entries=rejected_worldbook_entries,
            depth_inserts=depth_inserts,
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
        world_before_character = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'before_character'
        ]
        world_before_history = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) in {'before', 'before_chat_history'}
        ]
        world_after_character = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'after_character'
        ]
        world_before_examples = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'before_example_messages'
        ]
        world_before_last_user = [
            entry for entry in matched_worldbook_entries
            if self._map_worldbook_position(str(entry.get('insertionPosition') or '')) == 'before_last_user'
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
                content='\n\n'.join(self._entry_content(entry) for entry in world_before_history),
                source='worldbook',
                meta={'entryIds': [entry.get('id') for entry in world_before_history]},
            ),
            'world_info_after': self._block(
                name='world_info_after',
                kind='world_info',
                position='in_prompt',
                role='system',
                content='',
                source='worldbook',
                meta={'entryIds': []},
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
            identifier = str(item.get('identifier') or item.get('block_id') or '').strip()
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
                'sourceItem': item,
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

        for entry in world_before_character:
            ordered_blocks.append(self._block(
                name=f"worldbook:before_character:{entry.get('id') or ''}",
                kind='world_info',
                position='before_story',
                role='system',
                content=self._entry_content(entry),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'matchMeta': entry.get('_matchMeta') or {},
                },
            ))

        for entry in world_after_character:
            ordered_blocks.append(self._block(
                name=f"worldbook:after_character:{entry.get('id') or ''}",
                kind='world_info',
                position='after_story',
                role='system',
                content=self._entry_content(entry),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'matchMeta': entry.get('_matchMeta') or {},
                },
            ))

        for entry in world_before_examples:
            ordered_blocks.append(self._block(
                name=f"worldbook:before_examples:{entry.get('id') or ''}",
                kind='world_info',
                position='before_examples',
                role='system',
                content=self._entry_content(entry),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'matchMeta': entry.get('_matchMeta') or {},
                },
            ))

        for entry in world_depth:
            ordered_blocks.append(self._block(
                name=f"worldbook:{entry.get('id') or ''}",
                kind='world_info',
                position='at_depth',
                role='system',
                content=self._entry_content(entry),
                depth=int(entry.get('depth') or 2),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'matchMeta': entry.get('_matchMeta') or {},
                },
            ))

        for entry in world_before_last_user:
            ordered_blocks.append(self._block(
                name=f"worldbook:last_user:{entry.get('id') or ''}",
                kind='world_info',
                position='before_last_user',
                role='system',
                content=self._entry_content(entry),
                source='worldbook',
                meta={
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'matchMeta': entry.get('_matchMeta') or {},
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
        runtime_context: PromptRuntimeContext,
    ) -> tuple[list[dict[str, Any]], str, str, list[dict[str, Any]]]:
        system_text = self._render_story_string(ordered_blocks, preset, runtime_context)
        example_text = self._build_examples_block(ordered_blocks, preset, runtime_context)
        story_position = str(preset.get('storyStringPosition') or 'in_prompt').strip() or 'in_prompt'
        story_depth = int(preset.get('storyStringDepth') or 1)
        story_role = str(preset.get('storyStringRole') or 'system').strip() or 'system'

        before_story_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'before_story' and str(block.get('content') or '').strip()
        ]
        after_story_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'after_story' and str(block.get('content') or '').strip()
        ]
        before_examples_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'before_examples' and str(block.get('content') or '').strip()
        ]
        post_history_texts = [
            str(block.get('content') or '').strip()
            for block in ordered_blocks
            if block.get('position') == 'post_history' and str(block.get('content') or '').strip()
        ]
        before_last_user_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'before_last_user' and str(block.get('content') or '').strip()
        ]
        depth_blocks = [
            block for block in ordered_blocks
            if block.get('position') == 'at_depth' and str(block.get('content') or '').strip()
        ]

        messages: list[dict[str, Any]] = []
        depth_inserts: list[dict[str, Any]] = []
        story_inserted = False

        def insert_story_string(*, depth: int | None = None) -> None:
            nonlocal story_inserted
            if story_inserted or not system_text.strip():
                return
            messages.append({
                'role': story_role,
                'content': system_text,
                'meta': {
                    'kind': 'story_string',
                    'position': story_position,
                    'depth': depth,
                },
            })
            story_inserted = True

        for block in before_story_blocks:
            messages.append({
                'role': 'system',
                'content': self._decorate_depth_block(block),
                'meta': {
                    'kind': 'world_info',
                    'position': 'before_character',
                    **(block.get('meta') or {}),
                },
            })

        if story_position not in {'at_depth', 'before_last_user'}:
            insert_story_string()

        for block in after_story_blocks:
            messages.append({
                'role': 'system',
                'content': self._decorate_depth_block(block),
                'meta': {
                    'kind': 'world_info',
                    'position': 'after_character',
                    **(block.get('meta') or {}),
                },
            })

        for block in before_examples_blocks:
            messages.append({
                'role': 'system',
                'content': self._decorate_depth_block(block),
                'meta': {
                    'kind': 'world_info',
                    'position': 'before_example_messages',
                    **(block.get('meta') or {}),
                },
            })

        if example_text.strip():
            messages.append({'role': 'system', 'content': example_text, 'meta': {'kind': 'example_messages'}})

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
                        rendered_block = self._decorate_depth_block(block)
                        messages.append({'role': 'system', 'content': rendered_block})
                        depth_inserts.append({'depth': depth_from_end, 'block': block, 'content': rendered_block})
                if story_position == 'at_depth' and story_depth == depth_from_end:
                    insert_story_string(depth=depth_from_end)
                messages.append(message)
        else:
            if story_position == 'at_depth':
                insert_story_string(depth=story_depth)
            for block in depth_blocks:
                if int(block.get('depth') or 0) >= 0:
                    rendered_block = self._decorate_depth_block(block)
                    messages.append({'role': 'system', 'content': rendered_block})
                    depth_inserts.append({'depth': int(block.get('depth') or 0), 'block': block, 'content': rendered_block})

        for text in post_history_texts:
            messages.append({'role': 'system', 'content': text})

        if story_position == 'before_last_user':
            insert_story_string(depth=story_depth)

        for block in before_last_user_blocks:
            messages.append({
                'role': 'system',
                'content': self._decorate_depth_block(block),
                'meta': {
                    'kind': 'world_info',
                    'position': 'before_last_user',
                    **(block.get('meta') or {}),
                },
            })

        if user_text.strip():
            chat_start = str(preset.get('chatStart') or '').strip()
            final_user = user_text.strip()
            if chat_start and not rendered_history:
                final_user = f'{chat_start}\n{final_user}'
            messages.append({'role': 'user', 'content': final_user})
        elif not messages:
            insert_story_string(depth=story_depth if story_position == 'at_depth' else None)

        return messages, system_text, example_text, depth_inserts

    def _render_story_string(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any], runtime_context: PromptRuntimeContext) -> str:
        story_string = str(preset.get('storyString') or '').strip()
        if not story_string:
            story_string = (
                "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}"
                "{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{char}}'s personality: {{personality}}\n{{/if}}"
                "{{#if scenario}}Scenario: {{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}"
            )

        values = {
            **runtime_context.preview(),
            'system': self._block_content(ordered_blocks, 'system_prompt') or runtime_context.values.get('system', ''),
            'wiBefore': self._block_content(ordered_blocks, 'world_info_before'),
            'description': self._block_content(ordered_blocks, 'character_description') or runtime_context.values.get('description', ''),
            'personality': self._block_content(ordered_blocks, 'character_personality') or runtime_context.values.get('personality', ''),
            'scenario': self._block_content(ordered_blocks, 'character_scenario') or runtime_context.values.get('scenario', ''),
            'wiAfter': self._block_content(ordered_blocks, 'world_info_after'),
            'persona': self._block_content(ordered_blocks, 'persona') or runtime_context.values.get('persona', ''),
        }
        return self.renderer.render(story_string, PromptRuntimeContext(values=values))

    def _build_examples_block(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any], runtime_context: PromptRuntimeContext) -> str:
        examples = self._block_content(ordered_blocks, 'example_messages')
        if not examples:
            return ''
        separator = str(preset.get('exampleSeparator') or '').strip()
        rendered_examples = self.renderer.render(examples, runtime_context).strip()
        if not rendered_examples:
            return ''
        if not separator:
            return rendered_examples
        return f'{separator}\n{rendered_examples}'

    def _match_worldbook_entries(
        self,
        *,
        entries: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        character: dict[str, Any],
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        recent_history = [
            str(item.get('content') or item.get('text') or '').strip()
            for item in history[-12:]
            if str(item.get('content') or item.get('text') or '').strip()
        ]
        base_parts = [
            user_text,
            *recent_history,
            str(character.get('name') or ''),
            str(character.get('description') or ''),
            str(character.get('scenario') or ''),
            str(character.get('personality') or ''),
        ]
        full_corpus = '\n'.join(part for part in base_parts if part).strip()
        recursive_corpus = '\n'.join([user_text, *recent_history[-4:]]).strip()

        ordered_entries = sorted(
            entries,
            key=lambda item: (
                0 if bool(item.get('constant')) else 1,
                -int(item.get('priority') or 0),
                len(str(item.get('content') or '')),
                str(item.get('groupName') or ''),
                str(item.get('id') or ''),
            ),
        )

        pending = list(ordered_entries)
        matched_raw: list[dict[str, Any]] = []
        rejected: list[dict[str, Any]] = []
        seen_groups: set[str] = set()
        selected_ids: set[str] = set()
        budget_chars = 4000
        used_chars = 0
        pass_index = 0

        while pending and pass_index < 3:
            pass_index += 1
            next_pending: list[dict[str, Any]] = []
            progress = False
            recursive_seed = '\n'.join(
                str(item.get('content') or '').strip()
                for item in matched_raw
                if bool(item.get('recursive')) and str(item.get('content') or '').strip()
            ).strip()
            expanded_recursive_corpus = '\n'.join(part for part in [recursive_corpus, recursive_seed] if part).strip()
            expanded_full_corpus = '\n'.join(part for part in [full_corpus, recursive_seed] if part).strip()

            for entry in pending:
                if str(entry.get('id') or '') in selected_ids:
                    continue
                if not entry.get('enabled', True):
                    rejected.append({'entry': entry, 'reason': 'disabled'})
                    continue

                content = str(entry.get('content') or '').strip()
                if not content:
                    rejected.append({'entry': entry, 'reason': 'empty_content'})
                    continue

                keys = self._normalize_matchers(entry.get('keys') or [])
                secondary = self._normalize_matchers(entry.get('secondaryKeys') or [])
                scan_corpus = expanded_recursive_corpus if bool(entry.get('recursive')) else expanded_full_corpus

                if entry.get('constant'):
                    primary_info = {'matched': True, 'kind': 'constant', 'hits': []}
                else:
                    if not keys:
                        rejected.append({'entry': entry, 'reason': 'no_primary_keys'})
                        continue
                    primary_info = self._match_key_list(keys, scan_corpus)
                    if not primary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < 3:
                            next_pending.append(entry)
                        else:
                            rejected.append({'entry': entry, 'reason': 'primary_keys_not_matched', 'details': primary_info})
                        continue

                secondary_info = {'matched': True, 'kind': 'none', 'hits': []}
                if secondary:
                    secondary_info = self._match_key_list(secondary, scan_corpus)
                    if not secondary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < 3:
                            next_pending.append(entry)
                        else:
                            rejected.append({'entry': entry, 'reason': 'secondary_keys_not_matched', 'details': secondary_info})
                        continue

                group_name = str(entry.get('groupName') or '').strip()
                if group_name and group_name in seen_groups:
                    rejected.append({'entry': entry, 'reason': 'group_already_selected'})
                    continue

                content_len = len(content)
                if used_chars + content_len > budget_chars and matched_raw:
                    rejected.append({'entry': entry, 'reason': 'budget_exceeded'})
                    continue

                enriched = {
                    **entry,
                    '_matchMeta': {
                        'primary': primary_info,
                        'secondary': secondary_info,
                        'corpus': 'recursive' if bool(entry.get('recursive')) else 'full',
                        'pass': pass_index,
                    },
                }
                matched_raw.append(enriched)
                selected_ids.add(str(entry.get('id') or ''))
                used_chars += content_len
                if group_name:
                    seen_groups.add(group_name)
                progress = True

            if not progress:
                pending = next_pending
                break
            pending = next_pending

        for entry in pending:
            rejected.append({'entry': entry, 'reason': 'recursive_match_not_resolved'})

        matched_raw.sort(
            key=lambda item: (
                -int(item.get('priority') or 0),
                str(item.get('groupName') or ''),
                str(item.get('id') or ''),
            ),
        )
        return matched_raw, rejected

    def _normalize_matchers(self, values: list[Any]) -> list[str]:
        normalized: list[str] = []
        for value in values:
            text = str(value or '').strip()
            if text:
                normalized.append(text)
        return normalized

    def _match_key_list(self, keys: list[str], corpus: str) -> dict[str, Any]:
        hits: list[dict[str, Any]] = []
        lowered = corpus.lower()
        for raw_key in keys:
            key = raw_key.strip()
            if not key:
                continue
            if key.startswith('re:'):
                pattern = key[3:]
                try:
                    if re.search(pattern, corpus, flags=re.IGNORECASE):
                        hits.append({'key': raw_key, 'mode': 'regex'})
                except re.error:
                    continue
            else:
                if key.lower() in lowered:
                    hits.append({'key': raw_key, 'mode': 'substring'})
        return {
            'matched': bool(hits),
            'hits': hits,
            'tested': keys,
        }

    def _map_worldbook_position(self, value: str) -> str:
        normalized = str(value or '').strip() or 'before_chat_history'
        mapping = {
            'before_character': 'before_character',
            'before_chat_history': 'before_chat_history',
            'after_character': 'after_character',
            'before_example_messages': 'before_example_messages',
            'before_last_user': 'before_last_user',
            'at_depth': 'at_depth',
        }
        return mapping.get(normalized, 'before_chat_history')

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
