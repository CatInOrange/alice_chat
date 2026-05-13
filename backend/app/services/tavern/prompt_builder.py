from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any

from .context_usage import TavernContextUsageService, TavernTokenizerService
from .long_term_memory_service import TavernLongTermMemoryService
from .macro_runtime import MacroEngine, MacroRuntimeContext, build_macro_runtime_context


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
    macro_effects: list[dict[str, Any]]
    unknown_macros: list[str]
    rejected_worldbook_entries: list[dict[str, Any]]
    depth_inserts: list[dict[str, Any]]
    context_usage: dict[str, Any]


class PromptBuilder:
    """Tavern prompt assembly pipeline.

    Current target is closer to SillyTavern semantics than a generic block list:
    - prompt order decides movable semantic sections
    - world info entries remain special injections grouped by insertion buckets
    - author note remains a dedicated at-depth injection, not a normal movable section
    - story_string / example_separator / chat_start matter
    - debug output should reveal the exact assembled structure
    """

    def __init__(self) -> None:
        self.renderer = MacroEngine()
        self.tokenizer = TavernTokenizerService()
        self.context_usage_service = TavernContextUsageService(self.tokenizer)
        self.long_term_memory_service = TavernLongTermMemoryService()

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
        'longTermMemory': 'long_term_memory',
        'summaries': 'summaries',
        'chatHistory': 'chat_history',
        'postHistoryInstructions': 'post_history_instructions',
        'jailbreak': 'post_history_instructions',
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
        persona: dict[str, Any] | None = None,
        local_variables: dict[str, Any] | None = None,
        global_variables: dict[str, Any] | None = None,
        provider_id: str = '',
        model_name: str = '',
        allow_side_effects: bool = False,
    ) -> PromptDebugResult:
        history = list(history or [])
        prompt_blocks = list(prompt_blocks or [])
        summaries, history = self._extract_context_summaries(history=history, chat=chat or {})
        runtime_context = build_macro_runtime_context(
            character=character,
            chat=chat or {},
            history=history,
            user_text=user_text,
            persona=persona,
            preset=preset or {},
            provider_id=provider_id,
            model_name=model_name,
            local_variables=local_variables,
            global_variables=global_variables,
            original_text=user_text,
        )
        matched_worldbook_entries, rejected_worldbook_entries = self._match_worldbook_entries(
            entries=worldbook_entries or [],
            history=history,
            user_text=user_text,
            character=character,
            chat=chat or {},
        )
        ordered_blocks = self._build_ordered_blocks(
            character=character,
            preset=preset or {},
            prompt_order=prompt_order or {},
            prompt_blocks=prompt_blocks,
            matched_worldbook_entries=matched_worldbook_entries,
            history=history,
            summaries=summaries,
            user_text=user_text,
            chat=chat or {},
        )
        worldbook_token_budget = self._resolve_worldbook_token_budget(character)
        max_context = self._resolve_max_context(preset or {})

        effective_history = list(history)
        effective_blocks = list(ordered_blocks)
        effective_worldbook_entries = list(matched_worldbook_entries)

        messages = []
        rendered_story_string = ''
        rendered_examples = ''
        depth_inserts: list[dict[str, Any]] = []
        context_usage = self.context_usage_service.calculate(
            ordered_blocks=effective_blocks,
            matched_worldbook_entries=effective_worldbook_entries,
            history=effective_history,
            user_text=user_text,
            chat=chat or {},
            max_context=max_context,
            worldbook_token_budget=worldbook_token_budget,
            rendered_messages=[],
        )

        for _ in range(6):
            messages, rendered_story_string, rendered_examples, depth_inserts, macro_effects, unknown_macros = self._render_messages(
                ordered_blocks=effective_blocks,
                history=effective_history,
                user_text=user_text,
                preset=preset or {},
                chat=chat or {},
                runtime_context=runtime_context,
                allow_side_effects=allow_side_effects,
            )
            context_usage = self.context_usage_service.calculate(
                ordered_blocks=effective_blocks,
                matched_worldbook_entries=effective_worldbook_entries,
                history=effective_history,
                user_text=user_text,
                chat=chat or {},
                max_context=max_context,
                worldbook_token_budget=worldbook_token_budget,
                rendered_messages=messages,
            )
            before_history = effective_history
            before_blocks = effective_blocks
            before_entries = effective_worldbook_entries
            trim_plan = ((context_usage.to_dict().get('meta') or {}).get('trimPlan') or {})
            effective_history, effective_blocks, effective_worldbook_entries, trim_rejections = self._apply_total_context_budget(
                history=effective_history,
                ordered_blocks=effective_blocks,
                matched_worldbook_entries=effective_worldbook_entries,
                context_usage=context_usage.to_dict(),
            )
            if trim_rejections:
                rejected_worldbook_entries.extend(trim_rejections)

            changed = (
                effective_history != before_history
                or effective_blocks != before_blocks
                or effective_worldbook_entries != before_entries
            )
            unresolved = int(trim_plan.get('unresolvedOverLimitTokens') or 0)
            suggested_cuts = list(trim_plan.get('suggestedCuts') or [])
            if not changed:
                break
            if unresolved <= 0 and not suggested_cuts:
                break

        messages, rendered_story_string, rendered_examples, depth_inserts, macro_effects, unknown_macros = self._render_messages(
            ordered_blocks=effective_blocks,
            history=effective_history,
            user_text=user_text,
            preset=preset or {},
            chat=chat or {},
            runtime_context=runtime_context,
            allow_side_effects=allow_side_effects,
        )
        context_usage = self.context_usage_service.calculate(
            ordered_blocks=effective_blocks,
            matched_worldbook_entries=effective_worldbook_entries,
            history=effective_history,
            user_text=user_text,
            chat=chat or {},
            max_context=max_context,
            worldbook_token_budget=worldbook_token_budget,
            rendered_messages=messages,
        )

        return PromptDebugResult(
            preset_id=str((preset or {}).get('id') or ''),
            prompt_order_id=str((prompt_order or {}).get('id') or ''),
            matched_worldbook_entries=effective_worldbook_entries,
            character_lore_bindings=list(character_lore_bindings or []),
            blocks=effective_blocks,
            messages=messages,
            rendered_story_string=rendered_story_string,
            rendered_examples=rendered_examples,
            runtime_context=runtime_context.preview(),
            macro_effects=[{'scope': item.scope, 'op': item.op, 'name': item.name, 'value': item.value} for item in macro_effects],
            unknown_macros=unknown_macros,
            rejected_worldbook_entries=rejected_worldbook_entries,
            depth_inserts=depth_inserts,
            context_usage=context_usage.to_dict(),
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
        summaries: list[dict[str, Any]],
        user_text: str,
        chat: dict[str, Any],
    ) -> list[dict[str, Any]]:
        world_entries_by_position: dict[str, list[dict[str, Any]]] = {}
        for entry in matched_worldbook_entries:
            position = self._map_worldbook_position(str(entry.get('insertionPosition') or ''))
            world_entries_by_position.setdefault(position, []).append(entry)

        world_before_system = world_entries_by_position.get('before_system', [])
        world_after_system = world_entries_by_position.get('after_system', [])
        world_before_character = world_entries_by_position.get('before_character', [])
        world_before_history = world_entries_by_position.get('before_chat_history', [])
        world_after_character = world_entries_by_position.get('after_character', [])
        world_before_examples = world_entries_by_position.get('before_example_messages', [])
        world_after_examples = world_entries_by_position.get('after_example_messages', [])
        world_after_history = world_entries_by_position.get('after_chat_history', [])
        world_before_last_user = world_entries_by_position.get('before_last_user', [])
        world_depth = world_entries_by_position.get('at_depth', [])

        summary_blocks = self._build_summary_blocks(summaries)
        long_term_memory_block = self._build_long_term_memory_block(chat)

        semantic = {
            'system_prompt': self._block(
                name='system_prompt',
                kind='system',
                position='after_system',
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
                position='before_character',
                role='system',
                content=str(character.get('description') or ''),
                source='character',
            ),
            'character_personality': self._block(
                name='character_personality',
                kind='character',
                position='before_character',
                role='system',
                content=str(character.get('personality') or ''),
                source='character',
            ),
            'character_scenario': self._block(
                name='character_scenario',
                kind='scenario',
                position='after_character',
                role='system',
                content=str(character.get('scenario') or ''),
                source='character',
            ),
            'example_messages': self._block(
                name='example_messages',
                kind='example_messages',
                position='before_example_messages',
                role='system',
                content=str(character.get('exampleDialogues') or ''),
                source='character',
            ),
            'world_info_before': self._block(
                name='world_info_before',
                kind='world_info',
                position='in_prompt',
                role='system',
                content='',
                source='worldbook',
                meta={'entryIds': []},
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
            'long_term_memory': self._block(
                name='long_term_memory',
                kind='long_term_memory',
                position='before_chat_history',
                role='system',
                content=long_term_memory_block,
                source='long_term_memory',
                meta={
                    'memoryItemCount': len(self.long_term_memory_service.build_prompt_items(chat, tokenizer=self.tokenizer)),
                },
            ),
            'chat_history': self._block(
                name='chat_history',
                kind='chat_history',
                position='before_last_user',
                role='history',
                content=f'{len(history)} messages',
                source='runtime',
            ),
            'summaries': self._block(
                name='summaries',
                kind='summary_group',
                position='before_chat_history',
                role='system',
                content='summary-group',
                source='summary',
                meta={
                    'summaryCount': len(summaries),
                    'summaryIds': [item.get('id') for item in summaries if item.get('id')],
                },
            ),
            'author_note': self._block(
                name='author_note',
                kind='author_note',
                position='at_depth',
                role='system',
                content=str(chat.get('authorNote') or '').strip() if chat.get('authorNoteEnabled') else '',
                depth=int(chat.get('authorNoteDepth') or 4),
                source='chat',
            ),
            'post_history_instructions': self._block(
                name='post_history_instructions',
                kind='custom',
                position='after_chat_history',
                role='system',
                content=str(character.get('postHistoryInstructions') or '').strip(),
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
                {'identifier': 'personaDescription', 'enabled': True, 'order_index': 10},
                {'identifier': 'charDescription', 'enabled': True, 'order_index': 20},
                {'identifier': 'charPersonality', 'enabled': True, 'order_index': 30},
                {'identifier': 'scenario', 'enabled': True, 'order_index': 40},
                {'identifier': 'worldInfoBefore', 'enabled': True, 'order_index': 50},
                {'identifier': 'dialogueExamples', 'enabled': True, 'order_index': 60},
                {'identifier': 'longTermMemory', 'enabled': True, 'order_index': 65},
                {'identifier': 'summaries', 'enabled': True, 'order_index': 70},
                {'identifier': 'chatHistory', 'enabled': True, 'order_index': 80},
                {'identifier': 'worldInfoAfter', 'enabled': True, 'order_index': 90},
                {'identifier': 'postHistoryInstructions', 'enabled': True, 'order_index': 100},
            ]

        prompt_blocks_by_id = {
            str(block.get('id') or '').strip(): block
            for block in prompt_blocks
            if str(block.get('id') or '').strip()
        }

        ordered_blocks: list[dict[str, Any]] = []
        used_keys: set[str] = set()
        for item in sorted(order_items, key=lambda it: int(it.get('order_index') or it.get('orderIndex') or 0)):
            if item.get('enabled') is False:
                continue
            block_id = str(item.get('block_id') or item.get('blockId') or '').strip()
            identifier = str(item.get('identifier') or '').strip()
            custom_content = str(item.get('content') or item.get('text') or '').strip()

            if block_id:
                prompt_block = prompt_blocks_by_id.get(block_id)
                if prompt_block and prompt_block.get('enabled', True):
                    ordered_blocks.append(self._build_prompt_block(prompt_block, source_item=item))
                    used_keys.add(f'block:{block_id}')
                continue

            if not identifier and custom_content:
                ordered_blocks.append(self._build_custom_prompt_order_item(item))
                continue

            semantic_key = self._IDENTIFIER_MAP.get(identifier)
            if not semantic_key or semantic_key not in semantic:
                continue
            if semantic_key == 'summaries':
                if semantic_key in used_keys:
                    continue
                ordered_blocks.extend(self._clone_summary_blocks_with_item(summary_blocks, item))
                used_keys.add(semantic_key)
                continue
            if semantic_key == 'long_term_memory':
                if semantic_key in used_keys:
                    continue
                if semantic[semantic_key].get('content'):
                    ordered_blocks.append(self._clone_block_with_item(semantic[semantic_key], item))
                used_keys.add(semantic_key)
                continue
            if semantic_key in used_keys:
                continue
            ordered_blocks.append(self._clone_block_with_item(semantic[semantic_key], item))
            used_keys.add(semantic_key)

        if semantic['author_note'].get('content'):
            ordered_blocks.append(semantic['author_note'])

        if semantic['post_history_instructions'].get('content') and 'post_history_instructions' not in used_keys:
            ordered_blocks.append(semantic['post_history_instructions'])


        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_before_system, position='before_system', name_prefix='worldbook:before_system'),
            before_name='system_prompt',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_after_system, position='after_system', name_prefix='worldbook:after_system'),
            after_name='system_prompt',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_before_character, position='before_character', name_prefix='worldbook:before_character'),
            before_names=['character_description', 'character_personality'],
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_after_character, position='after_character', name_prefix='worldbook:after_character'),
            after_names=['character_scenario', 'character_personality', 'character_description'],
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_before_examples, position='before_example_messages', name_prefix='worldbook:before_examples'),
            before_name='example_messages',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_after_examples, position='after_example_messages', name_prefix='worldbook:after_examples'),
            after_name='example_messages',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_before_history, position='before_chat_history', name_prefix='worldbook:before_history'),
            before_name='chat_history',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_after_history, position='after_chat_history', name_prefix='worldbook:after_history'),
            after_name='chat_history',
        )
        ordered_blocks = self._insert_blocks_relative(
            ordered_blocks,
            self._build_worldbook_blocks(world_before_last_user, position='before_last_user', name_prefix='worldbook:last_user'),
            before_names=['author_note'],
            before_position='before_last_user',
        )
        ordered_blocks.extend(self._build_worldbook_blocks(world_depth, position='at_depth', name_prefix='worldbook:depth'))

        return ordered_blocks

    def _insert_blocks_relative(
        self,
        ordered_blocks: list[dict[str, Any]],
        blocks_to_insert: list[dict[str, Any]],
        *,
        before_name: str | None = None,
        after_name: str | None = None,
        before_names: list[str] | None = None,
        after_names: list[str] | None = None,
        before_position: str | None = None,
    ) -> list[dict[str, Any]]:
        if not blocks_to_insert:
            return ordered_blocks

        targets_before = [*(before_names or []), *([before_name] if before_name else [])]
        targets_after = [*(after_names or []), *([after_name] if after_name else [])]

        insert_index: int | None = None
        if targets_before:
            for index, block in enumerate(ordered_blocks):
                if str(block.get('name') or '') in targets_before:
                    insert_index = index
                    break
        elif targets_after:
            for index, block in enumerate(ordered_blocks):
                if str(block.get('name') or '') in targets_after:
                    insert_index = index + 1
        elif before_position:
            for index, block in enumerate(ordered_blocks):
                if self._normalize_position(str(block.get('position') or '')) == before_position:
                    insert_index = index
                    break

        if insert_index is None:
            if before_position:
                for index, block in enumerate(ordered_blocks):
                    if self._normalize_position(str(block.get('position') or '')) == before_position:
                        insert_index = index
                        break
            if insert_index is None:
                insert_index = len(ordered_blocks)

        return [
            *ordered_blocks[:insert_index],
            *blocks_to_insert,
            *ordered_blocks[insert_index:],
        ]

    def _extract_context_summaries(
        self,
        *,
        history: list[dict[str, Any]],
        chat: dict[str, Any],
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        summaries: list[dict[str, Any]] = []
        filtered_history: list[dict[str, Any]] = []

        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}

        chat_summary = (chat.get('summary') if isinstance(chat.get('summary'), dict) else None)
        metadata_summary = (metadata.get('summary') if isinstance(metadata.get('summary'), dict) else None)
        for source_summary, source_name in ((chat_summary, 'chat'), (metadata_summary, 'chat_metadata')):
            if not isinstance(source_summary, dict):
                continue
            content = str(source_summary.get('content') or '').strip()
            if content:
                summaries.append({
                    'id': source_summary.get('id') or 'chat_summary',
                    'content': content,
                    'source': source_name,
                    'endMessageId': str(source_summary.get('endMessageId') or '').strip(),
                    'endMessageIndex': int(source_summary.get('endMessageIndex') or -1),
                    'createdAt': float(source_summary.get('createdAt') or 0),
                })

        chat_summaries = chat.get('summaries') if isinstance(chat.get('summaries'), list) else []
        metadata_summaries = metadata.get('summaries') if isinstance(metadata.get('summaries'), list) else []
        for item in [*chat_summaries, *metadata_summaries]:
            if not isinstance(item, dict):
                continue
            content = str(item.get('content') or '').strip()
            if not content:
                continue
            summaries.append({
                'id': item.get('id') or '',
                'content': content,
                'source': item.get('source') or 'chat',
                'endMessageId': str(item.get('endMessageId') or '').strip(),
                'endMessageIndex': int(item.get('endMessageIndex') or -1),
                'createdAt': float(item.get('createdAt') or 0),
            })

        for item in history:
            metadata = item.get('metadata') if isinstance(item.get('metadata'), dict) else {}
            if metadata.get('isSummary') is True or str(metadata.get('kind') or '') == 'summary':
                content = str(item.get('content') or item.get('text') or '').strip()
                if content:
                    summaries.append({
                        'id': item.get('id') or '',
                        'content': content,
                        'source': 'message',
                        'endMessageId': str(metadata.get('endMessageId') or '').strip(),
                        'endMessageIndex': int(metadata.get('endMessageIndex') or -1),
                        'createdAt': float(metadata.get('createdAt') or item.get('createdAt') or 0),
                    })
                continue
            filtered_history.append(item)

        deduped: list[dict[str, Any]] = []
        seen_keys: set[str] = set()
        for item in summaries:
            key = str(item.get('id') or '') or str(item.get('content') or '')
            if key in seen_keys:
                continue
            seen_keys.add(key)
            deduped.append(item)

        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        summary_settings = metadata.get('summarySettings') if isinstance(metadata.get('summarySettings'), dict) else {}
        inject_latest_only = bool(summary_settings.get('injectLatestOnly', False))
        use_recent_after_latest = bool(summary_settings.get('useRecentMessagesAfterLatest', True))
        max_injected_summaries = max(1, int(summary_settings.get('maxInjectedSummaries', 3) or 3))
        ordered = sorted(
            deduped,
            key=lambda item: (
                int(item.get('startMessageIndex') or item.get('endMessageIndex') or -1),
                int(item.get('endMessageIndex') or -1),
                float(item.get('createdAt') or 0),
            ),
        )
        if ordered and use_recent_after_latest:
            filtered_history = self._slice_history_after_latest_summary(filtered_history, ordered[-1])
        if inject_latest_only and ordered:
            return [ordered[-1]], filtered_history
        if len(ordered) > max_injected_summaries:
            ordered = ordered[-max_injected_summaries:]
        return ordered, filtered_history

    def _slice_history_after_latest_summary(
        self,
        history: list[dict[str, Any]],
        latest_summary: dict[str, Any],
    ) -> list[dict[str, Any]]:
        end_message_id = str(latest_summary.get('endMessageId') or '').strip()
        end_message_index = int(latest_summary.get('endMessageIndex') or -1)
        if end_message_id:
            for index, item in enumerate(history):
                if str(item.get('id') or '').strip() == end_message_id:
                    return list(history[index + 1 :])
        if end_message_index >= 0:
            return list(history[end_message_index + 1 :])
        return history

    def _build_long_term_memory_block(self, chat: dict[str, Any]) -> str:
        return self.long_term_memory_service.render_prompt_block(chat, tokenizer=self.tokenizer)

    def _build_summary_blocks(self, summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not summaries:
            return []
        blocks: list[dict[str, Any]] = []
        latest_index = len(summaries) - 1
        for index, item in enumerate(summaries):
            content = str(item.get('content') or '').strip()
            if not content:
                continue
            summary_id = str(item.get('id') or f'summary_{index + 1}')
            tier = 'latest' if index == latest_index else 'older'
            blocks.append(self._block(
                name=f'summary:{summary_id}',
                kind='summary',
                position='before_chat_history',
                role='system',
                content=content,
                source='summary',
                meta={
                    'summaryId': summary_id,
                    'summaryIndex': index,
                    'summaryTier': tier,
                    'summarySource': item.get('source'),
                },
            ))
        return blocks

    def _clone_summary_blocks_with_item(self, blocks: list[dict[str, Any]], item: dict[str, Any]) -> list[dict[str, Any]]:
        cloned: list[dict[str, Any]] = []
        for block in blocks:
            cloned_block = self._clone_block_with_item(block, item)
            cloned_meta = dict(cloned_block.get('meta') or {})
            cloned_meta['summaryOrderIndex'] = item.get('order_index') or item.get('orderIndex')
            cloned_block['meta'] = cloned_meta
            cloned.append(cloned_block)
        return cloned

    def _build_worldbook_blocks(
        self,
        entries: list[dict[str, Any]],
        *,
        position: str,
        name_prefix: str,
    ) -> list[dict[str, Any]]:
        blocks: list[dict[str, Any]] = []
        for entry in entries:
            depth = int(entry.get('depth') or 2) if position == 'at_depth' else None
            blocks.append(self._block(
                name=f"{name_prefix}:{entry.get('id') or ''}",
                kind='world_info',
                position=position,
                role='system',
                content=self._entry_content(entry),
                depth=depth,
                source='worldbook',
                meta={
                    'entryId': entry.get('id'),
                    'worldbookId': entry.get('worldbookId'),
                    'priority': entry.get('priority'),
                    'sourceScope': entry.get('_sourceScope') or 'global',
                    'matchMeta': entry.get('_matchMeta') or {},
                },
            ))
        return blocks

    def _apply_total_context_budget(
        self,
        *,
        history: list[dict[str, Any]],
        ordered_blocks: list[dict[str, Any]],
        matched_worldbook_entries: list[dict[str, Any]],
        context_usage: dict[str, Any],
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
        trim_plan = ((context_usage.get('meta') or {}).get('trimPlan') or {}) if isinstance(context_usage, dict) else {}
        cuts = list(trim_plan.get('suggestedCuts') or [])
        if not cuts:
            return history, ordered_blocks, matched_worldbook_entries, []

        effective_history = list(history)
        effective_blocks = list(ordered_blocks)
        effective_entries = list(matched_worldbook_entries)
        extra_rejections: list[dict[str, Any]] = []

        for cut in cuts:
            mode = str(cut.get('mode') or '')
            if mode == 'trim_oldest_first':
                effective_history = self._trim_history_oldest_first(effective_history, int(cut.get('suggestedTrimTokens') or 0))
            elif mode == 'drop_low_priority_entries_first':
                effective_blocks, effective_entries, removed = self._trim_world_info_low_priority_first(
                    effective_blocks,
                    effective_entries,
                    int(cut.get('suggestedTrimTokens') or 0),
                )
                extra_rejections.extend(removed)
            elif mode == 'trim_summaries_oldest_first':
                effective_blocks = self._trim_summaries_oldest_first(
                    effective_blocks,
                    int(cut.get('suggestedTrimTokens') or 0),
                    allow_latest=bool(cut.get('lastResort')),
                )
            elif mode == 'drop_author_note':
                effective_blocks = self._drop_author_note_blocks(effective_blocks)
            elif mode == 'drop_optional_sections_first':
                effective_blocks = self._drop_optional_prompt_sections(effective_blocks, int(cut.get('suggestedTrimTokens') or 0))

        return effective_history, effective_blocks, effective_entries, extra_rejections

    def _trim_history_oldest_first(self, history: list[dict[str, Any]], tokens_to_trim: int) -> list[dict[str, Any]]:
        if tokens_to_trim <= 0 or not history:
            return history
        kept = list(history)
        trimmed = 0
        while len(kept) > 1 and trimmed < tokens_to_trim:
            oldest = kept.pop(0)
            trimmed += self.tokenizer.estimate_token_count(str(oldest.get('content') or oldest.get('text') or ''))
        return kept

    def _trim_summaries_oldest_first(
        self,
        ordered_blocks: list[dict[str, Any]],
        tokens_to_trim: int,
        *,
        allow_latest: bool = False,
    ) -> list[dict[str, Any]]:
        if tokens_to_trim <= 0:
            return ordered_blocks

        summary_indices = [
            index for index, block in enumerate(ordered_blocks)
            if str(block.get('kind') or '') == 'summary' or str(block.get('source') or '') == 'summary'
        ]
        if not summary_indices:
            return ordered_blocks

        kept_flags = [True] * len(ordered_blocks)
        trimmed = 0
        removable_indices = [
            index for index in summary_indices
            if str(((ordered_blocks[index].get('meta') or {}).get('summaryTier') or 'older')) != 'latest'
        ]
        latest_indices = [index for index in summary_indices if index not in removable_indices]

        for index in removable_indices:
            if trimmed >= tokens_to_trim:
                break
            kept_flags[index] = False
            trimmed += self.tokenizer.estimate_token_count(str(ordered_blocks[index].get('content') or ''))

        if allow_latest:
            for index in latest_indices:
                if trimmed >= tokens_to_trim:
                    break
                kept_flags[index] = False
                trimmed += self.tokenizer.estimate_token_count(str(ordered_blocks[index].get('content') or ''))

        return [block for index, block in enumerate(ordered_blocks) if kept_flags[index]]

    def _drop_author_note_blocks(self, ordered_blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return [
            block for block in ordered_blocks
            if not (
                str(block.get('name') or '') == 'author_note'
                or str(block.get('kind') or '') == 'author_note'
            )
        ]

    def _drop_optional_prompt_sections(self, ordered_blocks: list[dict[str, Any]], tokens_to_trim: int) -> list[dict[str, Any]]:
        if tokens_to_trim <= 0:
            return ordered_blocks
        optional_names = ['example_messages', 'post_history_instructions']
        remaining = list(ordered_blocks)
        trimmed = 0
        for name in optional_names:
            next_blocks: list[dict[str, Any]] = []
            for block in remaining:
                if trimmed < tokens_to_trim and str(block.get('name') or '') == name:
                    trimmed += self.tokenizer.estimate_token_count(str(block.get('content') or ''))
                    continue
                next_blocks.append(block)
            remaining = next_blocks
            if trimmed >= tokens_to_trim:
                break
        return remaining

    def _trim_world_info_low_priority_first(
        self,
        ordered_blocks: list[dict[str, Any]],
        matched_worldbook_entries: list[dict[str, Any]],
        tokens_to_trim: int,
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
        if tokens_to_trim <= 0:
            return ordered_blocks, matched_worldbook_entries, []

        removable_entries = sorted(
            matched_worldbook_entries,
            key=lambda entry: (
                int(entry.get('priority') or 0),
                0 if str(entry.get('_sourceScope') or 'global') == 'global' else 1,
                str(entry.get('id') or ''),
            ),
        )
        removed_ids: set[str] = set()
        removed_payloads: list[dict[str, Any]] = []
        trimmed = 0
        for entry in removable_entries:
            if trimmed >= tokens_to_trim:
                break
            entry_id = str(entry.get('id') or '')
            content = str(entry.get('content') or '').strip()
            entry_tokens = self.tokenizer.estimate_token_count(content)
            removed_ids.add(entry_id)
            trimmed += entry_tokens
            removed_payloads.append({
                'entry': entry,
                'reason': 'trimmed_by_total_context_budget',
                'sourceScope': str(entry.get('_sourceScope') or 'global'),
                'details': {
                    'entryTokens': entry_tokens,
                    'targetTrimTokens': tokens_to_trim,
                },
            })

        filtered_entries = [entry for entry in matched_worldbook_entries if str(entry.get('id') or '') not in removed_ids]
        filtered_blocks = [
            block for block in ordered_blocks
            if not (
                str(block.get('kind') or '') == 'world_info'
                and str((block.get('meta') or {}).get('entryId') or '') in removed_ids
            )
        ]
        return filtered_blocks, filtered_entries, removed_payloads

    def _render_messages(
        self,
        *,
        ordered_blocks: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        preset: dict[str, Any],
        chat: dict[str, Any],
        runtime_context: MacroRuntimeContext,
        allow_side_effects: bool = False,
    ) -> tuple[list[dict[str, Any]], str, str, list[dict[str, Any]], list[Any], list[str]]:
        story_render = self._render_story_string(ordered_blocks, preset, runtime_context, allow_side_effects=allow_side_effects)
        system_text = story_render.text
        example_render = self._build_examples_block(ordered_blocks, preset, runtime_context, allow_side_effects=allow_side_effects)
        example_text = example_render.text
        macro_effects = [*story_render.effects, *example_render.effects]
        unknown_macros = [*story_render.unknown_macros, *example_render.unknown_macros]
        story_position = str(preset.get('storyStringPosition') or 'in_prompt').strip() or 'in_prompt'
        story_depth = int(preset.get('storyStringDepth') or 1)
        story_role = str(preset.get('storyStringRole') or 'system').strip() or 'system'

        messages: list[dict[str, Any]] = []
        depth_inserts: list[dict[str, Any]] = []
        story_inserted = False

        rendered_history = [
            {
                'role': str(item.get('role') or 'user'),
                'content': str(item.get('content') or item.get('text') or ''),
            }
            for item in history
            if str(item.get('content') or item.get('text') or '').strip()
        ]
        history_length = len(rendered_history)

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

        def emit_block(block: dict[str, Any], *, extra_meta: dict[str, Any] | None = None) -> None:
            if str(block.get('name') or '') == 'system_prompt':
                return
            content = str(block.get('content') or '').strip()
            if not content:
                return
            meta = {
                'kind': block.get('kind'),
                'position': self._normalize_position(str(block.get('position') or 'after_chat_history')),
                'source': block.get('source'),
                **(block.get('meta') or {}),
            }
            if extra_meta:
                meta.update(extra_meta)
            render = self.renderer.render(self._decorate_depth_block(block), runtime_context, allow_side_effects=allow_side_effects)
            if render.effects:
                macro_effects.extend(render.effects)
            if render.unknown_macros:
                unknown_macros.extend(render.unknown_macros)
            if not render.text.strip():
                return
            messages.append({
                'role': str(block.get('role') or 'system'),
                'content': render.text,
                'meta': meta,
            })

        def emit_depth_blocks(depth_from_end: int) -> None:
            for block in ordered_blocks:
                if self._normalize_position(str(block.get('position') or 'after_chat_history')) != 'at_depth':
                    continue
                if int(block.get('depth') or 0) != depth_from_end:
                    continue
                render = self.renderer.render(self._decorate_depth_block(block), runtime_context, allow_side_effects=allow_side_effects)
                if render.effects:
                    macro_effects.extend(render.effects)
                if render.unknown_macros:
                    unknown_macros.extend(render.unknown_macros)
                if not render.text.strip():
                    continue
                messages.append({
                    'role': str(block.get('role') or 'system'),
                    'content': render.text,
                    'meta': {
                        'kind': block.get('kind'),
                        'position': 'at_depth',
                        'depth': depth_from_end,
                        **(block.get('meta') or {}),
                    },
                })
                depth_inserts.append({'depth': depth_from_end, 'block': block, 'content': render.text})

        def emit_history_once() -> None:
            nonlocal story_inserted
            if rendered_history:
                for i, message in enumerate(rendered_history):
                    depth_from_end = history_length - 1 - i
                    emit_depth_blocks(depth_from_end)
                    if story_position == 'at_depth' and story_depth == depth_from_end:
                        insert_story_string(depth=depth_from_end)
                    messages.append(message)
            else:
                if story_position == 'at_depth':
                    insert_story_string(depth=story_depth)
                for block in ordered_blocks:
                    if self._normalize_position(str(block.get('position') or 'after_chat_history')) != 'at_depth':
                        continue
                    if int(block.get('depth') or 0) < 0:
                        continue
                    render = self.renderer.render(self._decorate_depth_block(block), runtime_context, allow_side_effects=allow_side_effects)
                    if render.effects:
                        macro_effects.extend(render.effects)
                    if render.unknown_macros:
                        unknown_macros.extend(render.unknown_macros)
                    if not render.text.strip():
                        continue
                    messages.append({
                        'role': str(block.get('role') or 'system'),
                        'content': render.text,
                        'meta': {
                            'kind': block.get('kind'),
                            'position': 'at_depth',
                            'depth': int(block.get('depth') or 0),
                            **(block.get('meta') or {}),
                        },
                    })
                    depth_inserts.append({'depth': int(block.get('depth') or 0), 'block': block, 'content': render.text})

        history_emitted = False

        for block in ordered_blocks:
            name = str(block.get('name') or '')
            position = self._normalize_position(str(block.get('position') or 'after_chat_history'))

            if name == 'system_prompt':
                if story_position not in {'at_depth', 'before_last_user'}:
                    insert_story_string()
                continue

            if name == 'example_messages':
                if example_text.strip():
                    messages.append({'role': 'system', 'content': example_text, 'meta': {'kind': 'example_messages'}})
                continue

            if name == 'chat_history':
                if not history_emitted:
                    emit_history_once()
                    history_emitted = True
                continue

            if position == 'at_depth':
                continue

            emit_block(block)

        if not story_inserted and story_position not in {'at_depth', 'before_last_user'} and not messages:
            insert_story_string()

        if not history_emitted:
            emit_history_once()
            history_emitted = True

        if story_position == 'before_last_user':
            insert_story_string(depth=story_depth)

        if user_text.strip():
            chat_start = str(preset.get('chatStart') or '').strip()
            final_user = user_text.strip()
            if chat_start and not rendered_history:
                final_user = f'{chat_start}\n{final_user}'
            user_render = self.renderer.render(final_user, runtime_context, allow_side_effects=False)
            if user_render.unknown_macros:
                unknown_macros.extend(user_render.unknown_macros)
            messages.append({'role': 'user', 'content': user_render.text or final_user})
        elif not messages:
            insert_story_string(depth=story_depth if story_position == 'at_depth' else None)

        return messages, system_text, example_text, depth_inserts, macro_effects, unknown_macros

    def _render_story_string(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any], runtime_context: MacroRuntimeContext, *, allow_side_effects: bool = False):
        story_string = str(preset.get('storyString') or '').strip()
        if not story_string:
            story_string = (
                "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}"
                "{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{char}}'s personality: {{personality}}\n{{/if}}"
                "{{#if scenario}}Scenario: {{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}"
            )

        values = {
            **runtime_context.preview(),
            'system': self._story_slot_content(ordered_blocks, 'system_prompt', allow_positions={'after_system', 'in_prompt'}) or runtime_context.values.get('system', ''),
            'wiBefore': self._story_slot_content(ordered_blocks, 'world_info_before', allow_positions={'in_prompt'}),
            'description': self._story_slot_content(ordered_blocks, 'character_description', allow_positions={'in_prompt'}) or '',
            'personality': self._story_slot_content(ordered_blocks, 'character_personality', allow_positions={'in_prompt'}) or '',
            'scenario': self._story_slot_content(ordered_blocks, 'character_scenario', allow_positions={'in_prompt'}) or '',
            'wiAfter': self._story_slot_content(ordered_blocks, 'world_info_after', allow_positions={'in_prompt'}),
            'persona': self._story_slot_content(ordered_blocks, 'persona', allow_positions={'in_prompt'}) or '',
        }
        story_context = MacroRuntimeContext(
            values=values,
            local_variables=runtime_context.local_variables,
            global_variables=runtime_context.global_variables,
        )
        return self.renderer.render(story_string, story_context, allow_side_effects=allow_side_effects)

    def _build_examples_block(self, ordered_blocks: list[dict[str, Any]], preset: dict[str, Any], runtime_context: MacroRuntimeContext, *, allow_side_effects: bool = False):
        examples = self._block_content(ordered_blocks, 'example_messages')
        if not examples:
            from .macro_runtime import MacroRenderResult
            return MacroRenderResult(text='', effects=[], unknown_macros=[])
        separator = str(preset.get('exampleSeparator') or '').strip()
        rendered_examples = self.renderer.render(examples, runtime_context, allow_side_effects=allow_side_effects)
        if not rendered_examples.text:
            return rendered_examples
        if separator:
            rendered_examples.text = f'{separator}\n{rendered_examples.text}'
        return rendered_examples


    def _resolve_worldbook_token_budget(self, character: dict[str, Any]) -> int:
        raw_book = self._character_book_data(character)
        if isinstance(raw_book, dict):
            try:
                return max(0, int(raw_book.get('token_budget') or raw_book.get('tokenBudget') or 0))
            except Exception:
                return 0
        return 0

    def _resolve_worldbook_max_recursion_steps(self, character: dict[str, Any]) -> int:
        raw_book = self._character_book_data(character)
        if isinstance(raw_book, dict):
            try:
                return max(0, int(raw_book.get('max_recursion_steps') or raw_book.get('maxRecursionSteps') or 0))
            except Exception:
                return 0
        return 0

    def _character_book_data(self, character: dict[str, Any]) -> dict[str, Any] | None:
        metadata = character.get('metadata') if isinstance(character.get('metadata'), dict) else {}
        raw_book = None
        if isinstance(metadata, dict):
            raw_book = metadata.get('character_book')
            if raw_book is None:
                data_layer = metadata.get('data') if isinstance(metadata.get('data'), dict) else None
                if isinstance(data_layer, dict):
                    raw_book = data_layer.get('character_book')
            if raw_book is None:
                card_data = metadata.get('cardData') if isinstance(metadata.get('cardData'), dict) else None
                if isinstance(card_data, dict):
                    raw_book = card_data.get('character_book')
        return raw_book if isinstance(raw_book, dict) else None

    def _resolve_max_context(self, preset: dict[str, Any]) -> int:
        try:
            context_length = int(
                preset.get('contextLength')
                or preset.get('maxContext')
                or preset.get('openaiMaxContext')
                or 0
            )
        except Exception:
            context_length = 0
        if context_length > 0:
            return context_length
        return 0

    def _match_worldbook_entries(
        self,
        *,
        entries: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        character: dict[str, Any],
        chat: dict[str, Any] | None = None,
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        recent_history = [
            str(item.get('content') or item.get('text') or '').strip()
            for item in history[-12:]
            if str(item.get('content') or item.get('text') or '').strip()
        ]
        recent_history_with_depth = list(enumerate(recent_history, start=1))
        chat_corpus = '\n'.join(part for part in [user_text, *recent_history] if part).strip()
        recursive_corpus = '\n'.join(part for part in [user_text, *recent_history[-4:]] if part).strip()

        worldbook_token_budget = self._resolve_worldbook_token_budget(character)
        runtime_states = self._worldbook_runtime_state_map(chat or {})
        ordered_entries = sorted(
            entries,
            key=lambda item: (
                0 if bool(item.get('constant')) else 1,
                -int(item.get('priority') or 0),
                self._entry_scan_depth(item) or 10_000,
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
        used_tokens = 0
        pass_index = 0
        max_recursion_steps = self._resolve_worldbook_max_recursion_steps(character)
        max_passes = max_recursion_steps if max_recursion_steps > 0 else 3
        delayed_levels = sorted({
            self._entry_delay_until_recursion_level(item)
            for item in ordered_entries
            if self._entry_delay_until_recursion_level(item) > 0
        })
        current_delay_level = delayed_levels[0] if delayed_levels else 0

        while pending and pass_index < max_passes:
            pass_index += 1
            next_pending: list[dict[str, Any]] = []
            progress = False
            recursive_seed = '\n'.join(
                str(item.get('content') or '').strip()
                for item in matched_raw
                if bool(item.get('recursive')) and str(item.get('content') or '').strip()
            ).strip()
            expanded_recursive_corpus = '\n'.join(part for part in [recursive_corpus, recursive_seed] if part).strip()

            for entry in pending:
                if str(entry.get('id') or '') in selected_ids:
                    continue
                if not entry.get('enabled', True):
                    rejected.append({'entry': entry, 'reason': 'disabled'})
                    continue

                entry_id = str(entry.get('id') or '').strip()
                state = runtime_states.get(entry_id, {}) if entry_id else {}
                sticky_remaining = max(0, int(state.get('stickyRemaining') or 0))
                cooldown_remaining = max(0, int(state.get('cooldownRemaining') or 0))
                delay_remaining = max(0, int(state.get('delayRemaining') or 0))
                pending_activation = bool(state.get('pendingActivation'))

                content = str(entry.get('content') or '').strip()
                if not content:
                    rejected.append({'entry': entry, 'reason': 'empty_content'})
                    continue

                char_filter = self._entry_character_filter(entry)
                char_filter_result = self._entry_matches_character_filter(entry=entry, character=character)
                if not char_filter_result['matched']:
                    rejected.append({
                        'entry': entry,
                        'reason': char_filter_result['reason'],
                        'details': char_filter_result,
                        'sourceScope': str(entry.get('_sourceScope') or 'global'),
                    })
                    continue

                keys = self._normalize_matchers(entry.get('keys') or [])
                secondary = self._normalize_matchers(entry.get('secondaryKeys') or [])
                scan_corpus = self._build_worldbook_scan_corpus(
                    entry=entry,
                    chat_corpus=chat_corpus,
                    recursive_corpus=expanded_recursive_corpus,
                    recent_history_with_depth=recent_history_with_depth,
                    character=character,
                )

                if sticky_remaining > 0:
                    primary_info = {'matched': True, 'kind': 'sticky', 'hits': [], 'state': state}
                elif pending_activation and delay_remaining <= 0:
                    primary_info = {'matched': True, 'kind': 'delayed_activation', 'hits': [], 'state': state}
                elif cooldown_remaining > 0:
                    rejected.append({'entry': entry, 'reason': 'cooldown_active', 'state': state, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                    continue
                elif entry.get('constant'):
                    primary_info = {'matched': True, 'kind': 'constant', 'hits': []}
                else:
                    delay_until_recursion = self._entry_delay_until_recursion_level(entry)
                    if pass_index == 1 and delay_until_recursion > 0:
                        next_pending.append(entry)
                        rejected.append({'entry': entry, 'reason': 'delayed_until_recursion', 'details': {'level': delay_until_recursion}, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue
                    if pass_index > 1 and delay_until_recursion > current_delay_level:
                        next_pending.append(entry)
                        rejected.append({'entry': entry, 'reason': 'delayed_until_recursion_level', 'details': {'level': delay_until_recursion, 'currentLevel': current_delay_level}, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue
                    if not keys:
                        rejected.append({'entry': entry, 'reason': 'no_primary_keys'})
                        continue
                    if bool(entry.get('preventRecursion')) and pass_index > 1:
                        rejected.append({'entry': entry, 'reason': 'prevent_recursion_blocked', 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue
                    primary_info = self._match_key_list(keys, scan_corpus, entry=entry)
                    if not primary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < max_passes:
                            next_pending.append(entry)
                        else:
                            rejected.append({'entry': entry, 'reason': 'primary_keys_not_matched', 'details': primary_info, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue

                secondary_info = {'matched': True, 'kind': 'none', 'hits': [], 'mode': 'none'}
                if secondary:
                    secondary_mode = self._entry_secondary_mode(entry)
                    secondary_info = self._match_key_list(secondary, scan_corpus, mode=secondary_mode, entry=entry)
                    if not secondary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < max_passes:
                            next_pending.append(entry)
                        else:
                            rejected.append({'entry': entry, 'reason': 'secondary_keys_not_matched', 'details': secondary_info, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue

                entry_delay = max(0, int(entry.get('delay') or 0))
                if primary_info['matched'] and primary_info.get('kind') not in {'sticky', 'delayed_activation'} and entry_delay > 0:
                    rejected.append({
                        'entry': entry,
                        'reason': 'delay_scheduled',
                        'sourceScope': str(entry.get('_sourceScope') or 'global'),
                        'details': {'delay': entry_delay},
                    })
                    continue

                match_score = self._entry_match_score(primary_info=primary_info, secondary_info=secondary_info, entry=entry)
                enriched = {
                    **entry,
                    '_matchMeta': {
                        'primary': primary_info,
                        'secondary': secondary_info,
                        'corpus': 'recursive' if bool(entry.get('recursive')) else 'full',
                        'pass': pass_index,
                        'runtimeState': state,
                        'characterFilter': char_filter,
                        'score': match_score,
                    },
                    '_sourceScope': str(entry.get('_sourceScope') or 'global'),
                }
                next_pending.append(enriched)
                progress = True

            if not progress:
                pending = next_pending
                break
            pending, accepted, pass_rejections, used_tokens, seen_groups, selected_ids = self._select_worldbook_pass_matches(
                pending=next_pending,
                already_matched=matched_raw,
                seen_groups=seen_groups,
                selected_ids=selected_ids,
                used_tokens=used_tokens,
                worldbook_token_budget=worldbook_token_budget,
            )
            matched_raw.extend(accepted)
            rejected.extend(pass_rejections)
            if pass_index > 1 and delayed_levels:
                current_delay_level = self._next_delay_level(delayed_levels, current_delay_level)

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

    def _worldbook_runtime_state_map(self, chat: dict[str, Any]) -> dict[str, dict[str, Any]]:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        runtime = metadata.get('worldbookRuntime') if isinstance(metadata.get('worldbookRuntime'), dict) else {}
        entries = runtime.get('entries') if isinstance(runtime.get('entries'), dict) else {}
        result: dict[str, dict[str, Any]] = {}
        for entry_id, state in entries.items():
            if not isinstance(state, dict):
                continue
            result[str(entry_id)] = dict(state)
        return result

    def _normalize_matchers(self, values: list[Any]) -> list[str]:
        normalized: list[str] = []
        for value in values:
            text = str(value or '').strip()
            if text:
                normalized.append(text)
        return normalized

    def _entry_secondary_mode(self, entry: dict[str, Any]) -> str:
        raw = str(
            entry.get('secondaryLogic')
            or entry.get('secondary_logic')
            or entry.get('selectiveLogic')
            or entry.get('selective_logic')
            or entry.get('logic')
            or entry.get('scanState')
            or 'and_any'
        ).strip().lower()
        aliases = {
            '0': 'and_any',
            '1': 'not_all',
            '2': 'not_any',
            '3': 'and_all',
            'any': 'and_any',
            'all': 'and_all',
            'and': 'and_any',
            'or': 'and_any',
            'not': 'not_any',
            'and_any': 'and_any',
            'and_all': 'and_all',
            'not_any': 'not_any',
            'not_all': 'not_all',
        }
        return aliases.get(raw, 'and_any')

    def _build_worldbook_scan_corpus(
        self,
        *,
        entry: dict[str, Any],
        chat_corpus: str,
        recursive_corpus: str,
        recent_history_with_depth: list[tuple[int, str]],
        character: dict[str, Any],
    ) -> str:
        scan_depth = self._entry_scan_depth(entry)
        if scan_depth > 0:
            history_slice = [text for depth, text in recent_history_with_depth if depth <= scan_depth]
            effective_chat_corpus = '\n'.join(part for part in [*history_slice] if part).strip()
            if not effective_chat_corpus:
                effective_chat_corpus = str(recent_history_with_depth[0][1] if recent_history_with_depth else '').strip()
            effective_recursive_corpus = '\n'.join(part for part in [*history_slice[: max(1, min(scan_depth, 4))]] if part).strip()
        else:
            effective_chat_corpus = chat_corpus
            effective_recursive_corpus = recursive_corpus

        parts = [effective_recursive_corpus if bool(entry.get('recursive')) else effective_chat_corpus]
        if self._entry_match_character_description(entry):
            parts.append(str(character.get('description') or '').strip())
        if self._entry_match_character_personality(entry):
            parts.append(str(character.get('personality') or '').strip())
        if self._entry_match_scenario(entry):
            parts.append(str(character.get('scenario') or '').strip())
        return '\n'.join(part for part in parts if part).strip()

    def _entry_scan_depth(self, entry: dict[str, Any]) -> int:
        for key in ('scanDepth', 'scan_depth'):
            try:
                value = int(entry.get(key) or 0)
            except Exception:
                value = 0
            if value > 0:
                return value
        return 0

    def _entry_match_character_description(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'matchCharacterDescription', 'match_character_description')

    def _entry_match_character_personality(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'matchCharacterPersonality', 'match_character_personality')

    def _entry_match_scenario(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'matchScenario', 'match_scenario')

    def _entry_case_sensitive(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'caseSensitive', 'case_sensitive')

    def _entry_match_whole_words(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'matchWholeWords', 'match_whole_words')

    def _entry_bool(self, entry: dict[str, Any], *keys: str) -> bool:
        for key in keys:
            if key in entry:
                value = entry.get(key)
                if isinstance(value, bool):
                    return value
                if isinstance(value, int):
                    return value != 0
                if isinstance(value, str):
                    lowered = value.strip().lower()
                    if lowered in {'1', 'true', 'yes', 'on'}:
                        return True
                    if lowered in {'0', 'false', 'no', 'off'}:
                        return False
        return False

    def _entry_character_filter(self, entry: dict[str, Any]) -> dict[str, Any]:
        names = self._normalize_matchers(entry.get('characterFilterNames') or entry.get('character_filter_names') or [])
        tags = self._normalize_matchers(entry.get('characterFilterTags') or entry.get('character_filter_tags') or [])
        exclude = self._entry_bool(entry, 'characterFilterExclude', 'character_filter_exclude')
        return {'names': names, 'tags': tags, 'exclude': exclude}

    def _entry_matches_character_filter(self, *, entry: dict[str, Any], character: dict[str, Any]) -> dict[str, Any]:
        filter_data = self._entry_character_filter(entry)
        names = filter_data['names']
        tags = filter_data['tags']
        exclude = bool(filter_data['exclude'])
        if not names and not tags:
            return {'matched': True, 'reason': 'no_character_filter', 'filter': filter_data}

        char_name = str(character.get('name') or '').strip()
        char_tags = [str(item).strip() for item in (character.get('tags') or []) if str(item).strip()]
        name_hit = bool(char_name) and any(item == char_name for item in names)
        tag_hit = bool(set(tags).intersection(char_tags)) if tags else False
        raw_hit = name_hit or tag_hit
        matched = (not raw_hit) if exclude else raw_hit
        return {
            'matched': matched,
            'reason': 'character_filter_excluded' if exclude and raw_hit else ('character_filter_not_matched' if not exclude and not raw_hit else 'character_filter_matched'),
            'filter': filter_data,
            'characterName': char_name,
            'characterTags': char_tags,
            'nameHit': name_hit,
            'tagHit': tag_hit,
        }

    def _match_key_list(self, keys: list[str], corpus: str, *, mode: str = 'and_any', entry: dict[str, Any] | None = None) -> dict[str, Any]:
        hit_map: list[dict[str, Any]] = []
        case_sensitive = self._entry_case_sensitive(entry or {})
        whole_words = self._entry_match_whole_words(entry or {})
        haystack = corpus if case_sensitive else corpus.lower()
        for raw_key in keys:
            key = raw_key.strip()
            if not key:
                continue
            hit = False
            hit_mode = 'substring'
            if key.startswith('re:'):
                pattern = key[3:]
                hit_mode = 'regex'
                flags = 0 if case_sensitive else re.IGNORECASE
                try:
                    hit = bool(re.search(pattern, corpus, flags=flags))
                except re.error:
                    hit = False
                    hit_mode = 'regex_error'
            else:
                needle = key if case_sensitive else key.lower()
                if whole_words:
                    hit_mode = 'whole_word' if ' ' not in needle else 'phrase'
                    hit = self._match_plaintext(haystack, needle, whole_words=whole_words)
                else:
                    hit = needle in haystack
            hit_map.append({'key': raw_key, 'mode': hit_mode, 'matched': hit})

        matched_hits = [item for item in hit_map if item['matched']]
        tested = [item['key'] for item in hit_map]
        normalized_mode = mode if mode in {'and_any', 'and_all', 'not_any', 'not_all'} else 'and_any'
        if not tested:
            matched = False
        elif normalized_mode == 'and_all':
            matched = len(matched_hits) == len(tested)
        elif normalized_mode == 'not_any':
            matched = len(matched_hits) == 0
        elif normalized_mode == 'not_all':
            matched = len(matched_hits) != len(tested)
        else:
            matched = len(matched_hits) > 0

        return {
            'matched': matched,
            'hits': matched_hits,
            'tested': tested,
            'mode': normalized_mode,
            'evaluated': hit_map,
        }

    def _match_plaintext(self, haystack: str, needle: str, *, whole_words: bool) -> bool:
        if not whole_words:
            return needle in haystack
        if not needle:
            return False
        if ' ' in needle:
            return needle in haystack
        pattern = re.compile(rf'(?<![\\w\u4e00-\u9fff]){re.escape(needle)}(?![\\w\u4e00-\u9fff])')
        return bool(pattern.search(haystack))

    def _entry_match_score(
        self,
        *,
        primary_info: dict[str, Any],
        secondary_info: dict[str, Any],
        entry: dict[str, Any],
    ) -> int:
        primary_hits = len(primary_info.get('hits') or [])
        secondary_hits = len(secondary_info.get('hits') or [])
        mode = str(secondary_info.get('mode') or self._entry_secondary_mode(entry))
        score = primary_hits
        if mode == 'and_any':
            score += secondary_hits
        elif mode == 'and_all' and secondary_hits == len(secondary_info.get('tested') or []):
            score += secondary_hits
        return score

    def _entry_use_group_scoring(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'useGroupScoring', 'use_group_scoring')

    def _entry_group_override(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'groupOverride', 'group_override')

    def _entry_group_weight(self, entry: dict[str, Any]) -> int:
        for key in ('groupWeight', 'group_weight'):
            try:
                value = int(entry.get(key) or 100)
            except Exception:
                value = 100
            if value > 0:
                return value
        return 100

    def _entry_delay_until_recursion_level(self, entry: dict[str, Any]) -> int:
        for key in ('delayUntilRecursion', 'delay_until_recursion'):
            try:
                value = int(entry.get(key) or 0)
            except Exception:
                value = 0
            if value > 0:
                return value
        return 0

    def _entry_probability(self, entry: dict[str, Any]) -> int:
        for key in ('probability',):
            try:
                value = int(entry.get(key) or 100)
            except Exception:
                value = 100
            return min(100, max(0, value))
        return 100

    def _entry_ignore_budget(self, entry: dict[str, Any]) -> bool:
        return self._entry_bool(entry, 'ignoreBudget', 'ignore_budget')

    def _next_delay_level(self, levels: list[int], current_level: int) -> int:
        for level in levels:
            if level > current_level:
                return level
        return current_level

    def _select_worldbook_pass_matches(
        self,
        *,
        pending: list[dict[str, Any]],
        already_matched: list[dict[str, Any]],
        seen_groups: set[str],
        selected_ids: set[str],
        used_tokens: int,
        worldbook_token_budget: int,
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], int, set[str], set[str]]:
        carry_pending: list[dict[str, Any]] = []
        accepted: list[dict[str, Any]] = []
        rejected: list[dict[str, Any]] = []
        grouped: dict[str, list[dict[str, Any]]] = {}
        ungrouped: list[dict[str, Any]] = []

        for entry in pending:
            group_name = str(entry.get('groupName') or '').strip()
            if group_name:
                grouped.setdefault(group_name, []).append(entry)
            else:
                ungrouped.append(entry)

        candidates: list[dict[str, Any]] = []
        for group_name, group_entries in grouped.items():
            if group_name in seen_groups:
                rejected.extend({
                    'entry': item,
                    'reason': 'group_already_selected',
                    'sourceScope': str(item.get('_sourceScope') or 'global'),
                } for item in group_entries)
                continue

            overrides = [item for item in group_entries if self._entry_group_override(item)]
            if overrides:
                chosen = sorted(overrides, key=self._group_sort_key)[0]
                losers = [item for item in group_entries if item is not chosen]
                rejected.extend({
                    'entry': item,
                    'reason': 'group_override_loser',
                    'sourceScope': str(item.get('_sourceScope') or 'global'),
                } for item in losers)
                candidates.append(chosen)
                continue

            if any(self._entry_use_group_scoring(item) for item in group_entries):
                best_score = max(int((item.get('_matchMeta') or {}).get('score') or 0) for item in group_entries)
                group_entries = [item for item in group_entries if int((item.get('_matchMeta') or {}).get('score') or 0) == best_score]

            chosen = sorted(group_entries, key=self._group_sort_key)[0]
            losers = [item for item in group_entries if item is not chosen]
            rejected.extend({
                'entry': item,
                'reason': 'group_not_selected',
                'sourceScope': str(item.get('_sourceScope') or 'global'),
            } for item in losers)
            candidates.append(chosen)

        candidates.extend(ungrouped)
        candidates.sort(key=self._group_sort_key)

        for entry in candidates:
            entry_id = str(entry.get('id') or '')
            group_name = str(entry.get('groupName') or '').strip()
            probability = self._entry_probability(entry)
            if probability < 100:
                roll = random.randint(1, 100)
                if roll > probability:
                    rejected.append({
                        'entry': entry,
                        'reason': 'probability_failed',
                        'sourceScope': str(entry.get('_sourceScope') or 'global'),
                        'details': {'roll': roll, 'probability': probability},
                    })
                    continue
            content_tokens = self.tokenizer.estimate_token_count(str(entry.get('content') or '').strip())
            if worldbook_token_budget > 0 and used_tokens + content_tokens > worldbook_token_budget and already_matched and not self._entry_ignore_budget(entry):
                rejected.append({
                    'entry': entry,
                    'reason': 'budget_exceeded',
                    'sourceScope': str(entry.get('_sourceScope') or 'global'),
                    'details': {
                        'usedTokens': used_tokens,
                        'entryTokens': content_tokens,
                        'worldbookTokenBudget': worldbook_token_budget,
                    },
                })
                continue
            accepted.append(entry)
            selected_ids.add(entry_id)
            used_tokens += content_tokens
            if group_name:
                seen_groups.add(group_name)

        for entry in pending:
            if entry not in accepted and not any(r.get('entry') is entry for r in rejected):
                if bool(entry.get('recursive')):
                    carry_pending.append(entry)
        return carry_pending, accepted, rejected, used_tokens, seen_groups, selected_ids

    def _group_sort_key(self, item: dict[str, Any]) -> tuple[Any, ...]:
        return (
            0 if bool(item.get('constant')) else 1,
            -int(item.get('priority') or 0),
            -int((item.get('_matchMeta') or {}).get('score') or 0),
            self._entry_scan_depth(item) or 10_000,
            -self._entry_group_weight(item),
            len(str(item.get('content') or '')),
            str(item.get('groupName') or ''),
            str(item.get('id') or ''),
        )

    def _map_worldbook_position(self, value: str) -> str:
        normalized = str(value or '').strip() or 'before_chat_history'
        mapping = {
            'before_system': 'before_system',
            'after_system': 'after_system',
            'before_character': 'before_character',
            'before_chat_history': 'before_chat_history',
            'after_character': 'after_character',
            'before_example_messages': 'before_example_messages',
            'after_example_messages': 'after_example_messages',
            'after_chat_history': 'after_chat_history',
            'before_last_user': 'before_last_user',
            'at_depth': 'at_depth',
        }
        return mapping.get(normalized, 'before_chat_history')

    def _normalize_position(self, value: str) -> str:
        normalized = str(value or '').strip() or 'after_chat_history'
        mapping = {
            'in_prompt': 'after_system',
            'post_history': 'after_chat_history',
            'history': 'before_last_user',
            'examples': 'before_example_messages',
            'before_story': 'before_character',
            'after_story': 'after_character',
            'before_examples': 'before_example_messages',
        }
        return mapping.get(normalized, normalized)

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

    def _story_slot_content(self, ordered_blocks: list[dict[str, Any]], name: str, *, allow_positions: set[str]) -> str:
        for block in ordered_blocks:
            if str(block.get('name') or '') != name:
                continue
            position = self._normalize_position(str(block.get('position') or 'after_chat_history'))
            if position in allow_positions:
                return str(block.get('content') or '').strip()
        return ''

    def _decorate_depth_block(self, block: dict[str, Any]) -> str:
        title = str(block.get('name') or 'depth_block')
        if title == 'author_note':
            return f"[Author's Note]\n{str(block.get('content') or '').strip()}"
        if str(block.get('source') or '') == 'worldbook':
            return f"[World Info]\n{str(block.get('content') or '').strip()}"
        return str(block.get('content') or '').strip()

    def _clone_block_with_item(self, block: dict[str, Any], item: dict[str, Any]) -> dict[str, Any]:
        cloned = dict(block)
        position = item.get('position')
        depth = item.get('depth')
        if position is not None:
            cloned['position'] = self._normalize_position(str(position))
        else:
            cloned['position'] = self._normalize_position(str(cloned.get('position') or 'after_chat_history'))
        if depth is not None:
            cloned['depth'] = int(depth)
        cloned['meta'] = {
            **(cloned.get('meta') or {}),
            'identifier': item.get('identifier'),
            'orderIndex': int(item.get('order_index') or item.get('orderIndex') or 0),
            'sourceItem': item,
        }
        return cloned

    def _build_custom_prompt_order_item(self, item: dict[str, Any]) -> dict[str, Any]:
        position = self._normalize_position(str(item.get('position') or 'after_chat_history'))
        depth_value = item.get('depth')
        meta: dict[str, Any] = {
            'sourceItem': item,
            'orderIndex': int(item.get('order_index') or item.get('orderIndex') or 0),
            'customItem': True,
        }
        return self._block(
            name=str(item.get('name') or 'custom_prompt'),
            kind='custom',
            position=position,
            role=str(item.get('role') or 'system') or 'system',
            content=str(item.get('content') or item.get('text') or ''),
            depth=int(depth_value) if depth_value is not None else None,
            source='prompt_order_item',
            meta=meta,
        )

    def _build_prompt_block(self, block: dict[str, Any], *, source_item: dict[str, Any] | None = None) -> dict[str, Any]:
        injection_mode = str(block.get('injectionMode') or 'position').strip() or 'position'
        if source_item is not None and source_item.get('position') is not None:
            position = self._normalize_position(str(source_item.get('position') or 'after_chat_history'))
        elif injection_mode == 'depth':
            position = 'at_depth'
        else:
            position = 'after_chat_history'

        depth_value = source_item.get('depth') if source_item is not None and source_item.get('depth') is not None else block.get('depth')
        meta: dict[str, Any] = {
            'blockId': block.get('id'),
            'roleScope': block.get('roleScope'),
        }
        if source_item is not None:
            meta['sourceItem'] = source_item
            meta['orderIndex'] = int(source_item.get('order_index') or source_item.get('orderIndex') or 0)
        return self._block(
            name=str(block.get('name') or block.get('id') or 'custom_block'),
            kind=str(block.get('kind') or 'custom'),
            position=position,
            role=str(block.get('role') or 'system') or 'system',
            content=str(block.get('content') or ''),
            depth=int(depth_value) if depth_value is not None else None,
            source='prompt_block',
            meta=meta,
        )

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
