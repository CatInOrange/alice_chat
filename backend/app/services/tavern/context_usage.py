from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


_BYTES_PER_TOKEN_RATIO = 4.0
_TOKENS_PER_MESSAGE_OVERHEAD = 3
_TOKENS_PER_NAME_FIELD = 1


@dataclass(slots=True)
class ContextComponentUsage:
    name: str
    token_count: int
    content: str | None = None
    icon: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)
    children: list['ContextComponentUsage'] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload['tokenCount'] = payload.pop('token_count')
        payload['children'] = [child.to_dict() for child in self.children]
        return payload


@dataclass(slots=True)
class ContextUsage:
    total_tokens: int
    max_context: int
    components: list[ContextComponentUsage]
    meta: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            'totalTokens': self.total_tokens,
            'maxContext': self.max_context,
            'remainingTokens': max(0, self.max_context - self.total_tokens) if self.max_context > 0 else None,
            'isOverLimit': self.max_context > 0 and self.total_tokens > self.max_context,
            'usagePercentage': ((self.total_tokens / self.max_context) * 100.0) if self.max_context > 0 else None,
            'components': [component.to_dict() for component in self.components],
            'meta': dict(self.meta),
        }


class TavernTokenizerService:
    """Lightweight tokenizer estimate service.

    Standard best-practice is model/provider-specific tokenizers (for example
    tiktoken or provider count-tokens endpoints). When an exact tokenizer is not
    available locally, use a UTF-8-byte heuristic plus lightweight chat-message
    framing overhead so mixed English/CJK text is less undercounted than a plain
    chars/token ratio.
    """

    bytes_per_token_ratio = _BYTES_PER_TOKEN_RATIO
    tokens_per_message_overhead = _TOKENS_PER_MESSAGE_OVERHEAD
    tokens_per_name_field = _TOKENS_PER_NAME_FIELD

    def estimate_token_count(self, text: str) -> int:
        text = str(text or '')
        if not text:
            return 0
        byte_length = len(text.encode('utf-8'))
        return max(1, int((byte_length / self.bytes_per_token_ratio) + 0.999999))

    def estimate_message_token_count(self, message: dict[str, Any]) -> int:
        content = str(message.get('content') or message.get('text') or '').strip()
        if not content:
            return 0
        total = self.estimate_token_count(content) + self.tokens_per_message_overhead
        if str(message.get('name') or '').strip():
            total += self.tokens_per_name_field
        return total

    def estimate_messages_token_count(self, messages: list[dict[str, Any]]) -> int:
        total = 0
        for message in messages:
            if not isinstance(message, dict):
                continue
            total += self.estimate_message_token_count(message)
        return total

    def tokens_to_chars(self, token_count: int) -> int:
        if token_count <= 0:
            return 0
        return max(1, int((token_count * self.bytes_per_token_ratio) + 0.999999))


class TavernContextUsageService:
    _TRIM_PRIORITY = {
        'User Input': 100,
        'Prompt Sections': 90,
        "Author's Note": 70,
        'Summaries': 60,
        'World Info / Lorebook': 50,
        'Chat History': 20,
    }

    _PROTECTED_CHILD_NAMES = {
        'system_prompt',
        'persona',
        'character_description',
        'character_personality',
        'character_scenario',
    }

    def __init__(self, tokenizer: TavernTokenizerService | None = None) -> None:
        self.tokenizer = tokenizer or TavernTokenizerService()

    def calculate(
        self,
        *,
        ordered_blocks: list[dict[str, Any]],
        matched_worldbook_entries: list[dict[str, Any]],
        history: list[dict[str, Any]],
        user_text: str,
        chat: dict[str, Any] | None,
        max_context: int = 0,
        worldbook_token_budget: int = 0,
        rendered_messages: list[dict[str, Any]] | None = None,
    ) -> ContextUsage:
        components: list[ContextComponentUsage] = []

        prompt_children: list[ContextComponentUsage] = []
        author_note_component: ContextComponentUsage | None = None
        world_info_children: list[ContextComponentUsage] = []
        summary_children: list[ContextComponentUsage] = []

        for block in ordered_blocks:
            content = str(block.get('content') or '').strip()
            if not content:
                continue
            kind = str(block.get('kind') or '')
            name = str(block.get('name') or kind or 'block')
            source = str(block.get('source') or '')
            position = str(block.get('position') or '')
            token_count = self.tokenizer.estimate_token_count(content)
            meta = {
                'kind': kind,
                'source': source,
                'position': position,
                'depth': block.get('depth'),
            }
            if name == 'author_note' or kind == 'author_note':
                author_note_component = ContextComponentUsage(
                    name="Author's Note",
                    token_count=token_count,
                    content=content,
                    icon='edit_note',
                    meta=meta,
                )
                continue
            if kind == 'summary' or source == 'summary':
                summary_tier = str((block.get('meta') or {}).get('summaryTier') or 'older')
                meta['summaryTier'] = summary_tier
                summary_children.append(ContextComponentUsage(
                    name=name,
                    token_count=token_count,
                    content=content,
                    icon='summarize',
                    meta=meta,
                ))
                continue
            if kind == 'world_info' or source == 'worldbook':
                scope = str((block.get('meta') or {}).get('sourceScope') or 'mixed')
                meta['sourceScope'] = scope
                world_info_children.append(ContextComponentUsage(
                    name=name,
                    token_count=token_count,
                    content=content,
                    icon='book',
                    meta=meta,
                ))
                continue
            if kind == 'chat_history':
                continue
            prompt_children.append(ContextComponentUsage(
                name=name,
                token_count=token_count,
                content=content,
                icon='notes',
                meta=meta,
            ))

        if prompt_children:
            components.append(ContextComponentUsage(
                name='Prompt Sections',
                token_count=sum(item.token_count for item in prompt_children),
                icon='settings',
                children=prompt_children,
            ))

        if summary_children:
            components.append(ContextComponentUsage(
                name='Summaries',
                token_count=sum(item.token_count for item in summary_children),
                icon='summarize',
                children=summary_children,
            ))

        if world_info_children or matched_worldbook_entries:
            if not world_info_children:
                for entry in matched_worldbook_entries:
                    content = str(entry.get('content') or '').strip()
                    if not content:
                        continue
                    scope = str(entry.get('_sourceScope') or 'global')
                    world_info_children.append(ContextComponentUsage(
                        name=str(entry.get('groupName') or entry.get('comment') or entry.get('id') or 'world_info'),
                        token_count=self.tokenizer.estimate_token_count(content),
                        content=content,
                        icon='book',
                        meta={
                            'entryId': entry.get('id'),
                            'sourceScope': scope,
                            'priority': entry.get('priority'),
                            'position': entry.get('insertionPosition'),
                        },
                    ))
            components.append(ContextComponentUsage(
                name='World Info / Lorebook',
                token_count=sum(item.token_count for item in world_info_children),
                icon='menu_book',
                children=world_info_children,
                meta={
                    'matchedCount': len(matched_worldbook_entries),
                    'worldbookTokenBudget': worldbook_token_budget or None,
                },
            ))

        if author_note_component is not None:
            components.append(author_note_component)

        history_children: list[ContextComponentUsage] = []
        for index, item in enumerate(history):
            content = str(item.get('content') or item.get('text') or '').strip()
            if not content:
                continue
            history_children.append(ContextComponentUsage(
                name=f"{str(item.get('role') or 'user')} #{index + 1}",
                token_count=self.tokenizer.estimate_token_count(content),
                content=content,
                icon='chat',
                meta={'messageId': item.get('id')},
            ))
        if history_children:
            components.append(ContextComponentUsage(
                name='Chat History',
                token_count=sum(item.token_count for item in history_children),
                icon='history',
                children=history_children,
            ))

        if str(user_text or '').strip():
            components.append(ContextComponentUsage(
                name='User Input',
                token_count=self.tokenizer.estimate_token_count(user_text),
                content=user_text,
                icon='send',
            ))

        component_total_tokens = sum(component.token_count for component in components)
        rendered_total_tokens = self.tokenizer.estimate_messages_token_count(rendered_messages or [])
        message_overhead_tokens = max(0, rendered_total_tokens - component_total_tokens)
        if message_overhead_tokens > 0:
            components.append(ContextComponentUsage(
                name='Message Framing',
                token_count=message_overhead_tokens,
                icon='token',
                meta={
                    'kind': 'message_overhead',
                    'estimationOnly': True,
                },
            ))
        total_tokens = sum(component.token_count for component in components)
        trim_plan = self._build_trim_plan(components=components, max_context=max_context)
        return ContextUsage(
            total_tokens=total_tokens,
            max_context=max_context,
            components=components,
            meta={
                'tokenizer': 'estimate:utf8_bytes/4+message_overhead',
                'componentTokens': component_total_tokens,
                'renderedMessageTokens': rendered_total_tokens or None,
                'messageOverheadTokens': message_overhead_tokens or None,
                'worldbookTokenBudget': worldbook_token_budget or None,
                'trimPlan': trim_plan,
            },
        )

    def _build_trim_plan(self, *, components: list[ContextComponentUsage], max_context: int) -> dict[str, Any]:
        total_tokens = sum(component.token_count for component in components)
        over_limit = max(0, total_tokens - max_context) if max_context > 0 else 0
        candidates: list[dict[str, Any]] = []

        for component in components:
            candidate = self._build_trim_candidate(component)
            if candidate is not None:
                candidates.append(candidate)

        candidates.sort(key=lambda item: (item['priority'], -item['tokenCount']))

        planned: list[dict[str, Any]] = []
        tokens_to_trim = over_limit
        for candidate in candidates:
            if tokens_to_trim <= 0:
                break
            preferred_removable = min(tokens_to_trim, candidate['removableTokens'])
            if preferred_removable > 0:
                entry = dict(candidate)
                entry['suggestedTrimTokens'] = preferred_removable
                entry['lastResort'] = False
                planned.append(entry)
                tokens_to_trim -= preferred_removable
                continue

            last_resort_tokens = int(candidate.get('lastResortTokens') or 0)
            if last_resort_tokens <= 0:
                continue
            fallback_removable = min(tokens_to_trim, last_resort_tokens)
            if fallback_removable <= 0:
                continue
            entry = dict(candidate)
            entry['suggestedTrimTokens'] = fallback_removable
            entry['lastResort'] = True
            planned.append(entry)
            tokens_to_trim -= fallback_removable

        return {
            'totalTokens': total_tokens,
            'maxContext': max_context,
            'overLimitTokens': over_limit,
            'withinLimit': over_limit == 0,
            'planner': 'native-style-component-budget',
            'candidates': candidates,
            'suggestedCuts': planned,
            'unresolvedOverLimitTokens': tokens_to_trim,
        }

    def _build_trim_candidate(self, component: ContextComponentUsage) -> dict[str, Any] | None:
        priority = self._TRIM_PRIORITY.get(component.name)
        if priority is None:
            return None

        removable = component.token_count
        protected_tokens = 0
        last_resort_tokens = 0
        if component.name == 'Prompt Sections' and component.children:
            for child in component.children:
                child_name = str(child.name or '')
                if child_name in self._PROTECTED_CHILD_NAMES:
                    protected_tokens += child.token_count
            removable = max(0, component.token_count - protected_tokens)
        elif component.name == 'Summaries' and component.children:
            for child in component.children:
                if str((child.meta or {}).get('summaryTier') or 'older') == 'latest':
                    protected_tokens += child.token_count
                    last_resort_tokens += child.token_count
            removable = max(0, component.token_count - protected_tokens)

        if component.name == 'User Input':
            removable = 0
        if removable <= 0 and last_resort_tokens <= 0:
            return None

        mode = 'drop_component'
        if component.name == 'Chat History':
            mode = 'trim_oldest_first'
        elif component.name == 'World Info / Lorebook':
            mode = 'drop_low_priority_entries_first'
        elif component.name == 'Summaries':
            mode = 'trim_summaries_oldest_first'
        elif component.name == 'Prompt Sections':
            mode = 'drop_optional_sections_first'
        elif component.name == "Author's Note":
            mode = 'drop_author_note'

        return {
            'name': component.name,
            'tokenCount': component.token_count,
            'priority': priority,
            'mode': mode,
            'protectedTokens': protected_tokens,
            'removableTokens': removable,
            'lastResortTokens': last_resort_tokens,
            'childCount': len(component.children),
        }
