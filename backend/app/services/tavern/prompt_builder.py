from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any

from .context_usage import TavernContextUsageService, TavernTokenizerService
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
    context_usage: dict[str, Any]


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
        self.tokenizer = TavernTokenizerService()
        self.context_usage_service = TavernContextUsageService(self.tokenizer)

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
        'summaries': 'summaries',
        'chatHistory': 'chat_history',
        'authorNote': 'author_note',
        'postHistoryInstructions': 'post_history_instructions',
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
        summaries, history = self._extract_context_summaries(history=history, chat=chat or {})
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
        )

        for _ in range(6):
            messages, rendered_story_string, rendered_examples, depth_inserts = self._render_messages(
                ordered_blocks=effective_blocks,
                history=effective_history,
                user_text=user_text,
                preset=preset or {},
                chat=chat or {},
                runtime_context=runtime_context,
            )
            context_usage = self.context_usage_service.calculate(
                ordered_blocks=effective_blocks,
                matched_worldbook_entries=effective_worldbook_entries,
                history=effective_history,
                user_text=user_text,
                chat=chat or {},
                max_context=max_context,
                worldbook_token_budget=worldbook_token_budget,
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

        messages, rendered_story_string, rendered_examples, depth_inserts = self._render_messages(
            ordered_blocks=effective_blocks,
            history=effective_history,
            user_text=user_text,
            preset=preset or {},
            chat=chat or {},
            runtime_context=runtime_context,
        )
        context_usage = self.context_usage_service.calculate(
            ordered_blocks=effective_blocks,
            matched_worldbook_entries=effective_worldbook_entries,
            history=effective_history,
            user_text=user_text,
            chat=chat or {},
            max_context=max_context,
            worldbook_token_budget=worldbook_token_budget,
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
            'nsfw': self._block(
                name='nsfw',
                kind='custom',
                position='after_chat_history',
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
                {'identifier': 'worldInfoBefore', 'enabled': True, 'order_index': 10, 'position': 'before_chat_history'},
                {'identifier': 'charDescription', 'enabled': True, 'order_index': 20, 'position': 'before_character'},
                {'identifier': 'charPersonality', 'enabled': True, 'order_index': 30, 'position': 'before_character'},
                {'identifier': 'scenario', 'enabled': True, 'order_index': 40, 'position': 'after_character'},
                {'identifier': 'dialogueExamples', 'enabled': True, 'order_index': 50, 'position': 'before_example_messages'},
                {'identifier': 'summaries', 'enabled': True, 'order_index': 55, 'position': 'before_chat_history'},
                {'identifier': 'chatHistory', 'enabled': True, 'order_index': 60, 'position': 'before_last_user'},
                {'identifier': 'postHistoryInstructions', 'enabled': True, 'order_index': 70, 'position': 'after_chat_history'},
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
            if semantic_key in used_keys:
                continue
            ordered_blocks.append(self._clone_block_with_item(semantic[semantic_key], item))
            used_keys.add(semantic_key)

        if semantic['author_note'].get('content') and 'author_note' not in used_keys:
            ordered_blocks.append(semantic['author_note'])

        if semantic['post_history_instructions'].get('content') and 'post_history_instructions' not in used_keys:
            ordered_blocks.append(semantic['post_history_instructions'])

        ordered_blocks.extend(self._build_worldbook_blocks(world_before_system, position='before_system', name_prefix='worldbook:before_system'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_after_system, position='after_system', name_prefix='worldbook:after_system'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_before_character, position='before_character', name_prefix='worldbook:before_character'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_before_history, position='before_chat_history', name_prefix='worldbook:before_history'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_after_character, position='after_character', name_prefix='worldbook:after_character'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_before_examples, position='before_example_messages', name_prefix='worldbook:before_examples'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_after_examples, position='after_example_messages', name_prefix='worldbook:after_examples'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_after_history, position='after_chat_history', name_prefix='worldbook:after_history'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_before_last_user, position='before_last_user', name_prefix='worldbook:last_user'))
        ordered_blocks.extend(self._build_worldbook_blocks(world_depth, position='at_depth', name_prefix='worldbook:depth'))

        return ordered_blocks

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
        inject_latest_only = bool(summary_settings.get('injectLatestOnly', True))
        use_recent_after_latest = bool(summary_settings.get('useRecentMessagesAfterLatest', True))
        if deduped and use_recent_after_latest:
            filtered_history = self._slice_history_after_latest_summary(filtered_history, deduped[-1])
        if inject_latest_only and deduped:
            return [deduped[-1]], filtered_history
        return deduped, filtered_history

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
        optional_names = ['example_messages', 'post_history_instructions', 'nsfw']
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
        runtime_context: PromptRuntimeContext,
    ) -> tuple[list[dict[str, Any]], str, str, list[dict[str, Any]]]:
        system_text = self._render_story_string(ordered_blocks, preset, runtime_context)
        example_text = self._build_examples_block(ordered_blocks, preset, runtime_context)
        story_position = str(preset.get('storyStringPosition') or 'in_prompt').strip() or 'in_prompt'
        story_depth = int(preset.get('storyStringDepth') or 1)
        story_role = str(preset.get('storyStringRole') or 'system').strip() or 'system'

        blocks_by_position: dict[str, list[dict[str, Any]]] = {}
        for block in ordered_blocks:
            content = str(block.get('content') or '').strip()
            if not content:
                continue
            normalized = self._normalize_position(str(block.get('position') or 'after_chat_history'))
            blocks_by_position.setdefault(normalized, []).append(block)

        before_system_blocks = blocks_by_position.get('before_system', [])
        after_system_blocks = blocks_by_position.get('after_system', [])
        before_story_blocks = blocks_by_position.get('before_character', [])
        after_story_blocks = blocks_by_position.get('after_character', [])
        before_examples_blocks = blocks_by_position.get('before_example_messages', [])
        after_examples_blocks = blocks_by_position.get('after_example_messages', [])
        before_history_blocks = blocks_by_position.get('before_chat_history', [])
        after_history_blocks = blocks_by_position.get('after_chat_history', [])
        post_history_blocks = blocks_by_position.get('post_history', [])
        before_last_user_blocks = blocks_by_position.get('before_last_user', [])
        depth_blocks = blocks_by_position.get('at_depth', [])

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

        def emit_block(block: dict[str, Any], *, extra_meta: dict[str, Any] | None = None) -> None:
            if str(block.get('name') or '') == 'system_prompt':
                return
            meta = {
                'kind': block.get('kind'),
                'position': self._normalize_position(str(block.get('position') or 'after_chat_history')),
                'source': block.get('source'),
                **(block.get('meta') or {}),
            }
            if extra_meta:
                meta.update(extra_meta)
            messages.append({
                'role': str(block.get('role') or 'system'),
                'content': self._decorate_depth_block(block),
                'meta': meta,
            })

        for block in before_system_blocks:
            emit_block(block)

        if story_position not in {'at_depth', 'before_last_user'}:
            insert_story_string()

        for block in after_system_blocks:
            emit_block(block)

        for block in before_story_blocks:
            emit_block(block, extra_meta={'position': 'before_character'})

        for block in after_story_blocks:
            emit_block(block, extra_meta={'position': 'after_character'})

        for block in before_examples_blocks:
            emit_block(block, extra_meta={'position': 'before_example_messages'})

        if example_text.strip():
            messages.append({'role': 'system', 'content': example_text, 'meta': {'kind': 'example_messages'}})

        for block in after_examples_blocks:
            emit_block(block, extra_meta={'position': 'after_example_messages'})

        for block in before_history_blocks:
            emit_block(block, extra_meta={'position': 'before_chat_history'})

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
                        messages.append({
                            'role': str(block.get('role') or 'system'),
                            'content': rendered_block,
                            'meta': {
                                'kind': block.get('kind'),
                                'position': 'at_depth',
                                'depth': depth_from_end,
                                **(block.get('meta') or {}),
                            },
                        })
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
                    messages.append({
                        'role': str(block.get('role') or 'system'),
                        'content': rendered_block,
                        'meta': {
                            'kind': block.get('kind'),
                            'position': 'at_depth',
                            'depth': int(block.get('depth') or 0),
                            **(block.get('meta') or {}),
                        },
                    })
                    depth_inserts.append({'depth': int(block.get('depth') or 0), 'block': block, 'content': rendered_block})

        for block in after_history_blocks:
            emit_block(block, extra_meta={'position': 'after_chat_history'})

        for block in post_history_blocks:
            emit_block(block, extra_meta={'position': 'post_history'})

        if story_position == 'before_last_user':
            insert_story_string(depth=story_depth)

        for block in before_last_user_blocks:
            emit_block(block, extra_meta={'position': 'before_last_user'})

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
            'system': self._story_slot_content(ordered_blocks, 'system_prompt', allow_positions={'after_system', 'in_prompt'}) or runtime_context.values.get('system', ''),
            'wiBefore': self._story_slot_content(ordered_blocks, 'world_info_before', allow_positions={'in_prompt'}),
            'description': self._story_slot_content(ordered_blocks, 'character_description', allow_positions={'in_prompt'}) or '',
            'personality': self._story_slot_content(ordered_blocks, 'character_personality', allow_positions={'in_prompt'}) or '',
            'scenario': self._story_slot_content(ordered_blocks, 'character_scenario', allow_positions={'in_prompt'}) or '',
            'wiAfter': self._story_slot_content(ordered_blocks, 'world_info_after', allow_positions={'in_prompt'}),
            'persona': self._story_slot_content(ordered_blocks, 'persona', allow_positions={'in_prompt'}) or '',
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


    def _resolve_worldbook_token_budget(self, character: dict[str, Any]) -> int:
        metadata = character.get('metadata') if isinstance(character.get('metadata'), dict) else {}
        raw_book = None
        if isinstance(metadata, dict):
            raw_book = metadata.get('character_book')
            if raw_book is None:
                data_layer = metadata.get('data') if isinstance(metadata.get('data'), dict) else None
                if isinstance(data_layer, dict):
                    raw_book = data_layer.get('character_book')
        if isinstance(raw_book, dict):
            try:
                return max(0, int(raw_book.get('token_budget') or raw_book.get('tokenBudget') or 0))
            except Exception:
                return 0
        return 0

    def _resolve_max_context(self, preset: dict[str, Any]) -> int:
        try:
            max_tokens = int(preset.get('maxTokens') or 0)
        except Exception:
            max_tokens = 0
        if max_tokens > 0:
            return max_tokens
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

        worldbook_token_budget = self._resolve_worldbook_token_budget(character)
        runtime_states = self._worldbook_runtime_state_map(chat or {})
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
        used_tokens = 0
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

                keys = self._normalize_matchers(entry.get('keys') or [])
                secondary = self._normalize_matchers(entry.get('secondaryKeys') or [])
                scan_corpus = expanded_recursive_corpus if bool(entry.get('recursive')) else expanded_full_corpus

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
                    if not keys:
                        rejected.append({'entry': entry, 'reason': 'no_primary_keys'})
                        continue
                    if bool(entry.get('preventRecursion')) and pass_index > 1:
                        rejected.append({'entry': entry, 'reason': 'prevent_recursion_blocked', 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue
                    primary_info = self._match_key_list(keys, scan_corpus)
                    if not primary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < 3:
                            next_pending.append(entry)
                        else:
                            rejected.append({'entry': entry, 'reason': 'primary_keys_not_matched', 'details': primary_info, 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                        continue

                secondary_info = {'matched': True, 'kind': 'none', 'hits': [], 'mode': 'none'}
                if secondary:
                    secondary_mode = self._entry_secondary_mode(entry)
                    secondary_info = self._match_key_list(secondary, scan_corpus, mode=secondary_mode)
                    if not secondary_info['matched']:
                        if bool(entry.get('recursive')) and pass_index < 3:
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

                group_name = str(entry.get('groupName') or '').strip()
                if group_name and group_name in seen_groups:
                    rejected.append({'entry': entry, 'reason': 'group_already_selected', 'sourceScope': str(entry.get('_sourceScope') or 'global')})
                    continue

                content_tokens = self.tokenizer.estimate_token_count(content)
                if worldbook_token_budget > 0 and used_tokens + content_tokens > worldbook_token_budget and matched_raw:
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

                enriched = {
                    **entry,
                    '_matchMeta': {
                        'primary': primary_info,
                        'secondary': secondary_info,
                        'corpus': 'recursive' if bool(entry.get('recursive')) else 'full',
                        'pass': pass_index,
                        'runtimeState': state,
                    },
                    '_sourceScope': str(entry.get('_sourceScope') or 'global'),
                }
                matched_raw.append(enriched)
                selected_ids.add(str(entry.get('id') or ''))
                used_tokens += content_tokens
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

    def _match_key_list(self, keys: list[str], corpus: str, *, mode: str = 'and_any') -> dict[str, Any]:
        hit_map: list[dict[str, Any]] = []
        lowered = corpus.lower()
        for raw_key in keys:
            key = raw_key.strip()
            if not key:
                continue
            hit = False
            hit_mode = 'substring'
            if key.startswith('re:'):
                pattern = key[3:]
                hit_mode = 'regex'
                try:
                    hit = bool(re.search(pattern, corpus, flags=re.IGNORECASE))
                except re.error:
                    hit = False
                    hit_mode = 'regex_error'
            else:
                hit = key.lower() in lowered
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
