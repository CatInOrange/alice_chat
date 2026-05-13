from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from .context_usage import TavernTokenizerService
from .model_client import TavernModelClient


_DEFAULT_SUMMARY_TRIGGER_RATIO = 0.8
_DEFAULT_SUMMARY_TARGET_RATIO = 0.68
_DEFAULT_SUMMARY_MAX_TOKENS = 1024
_DEFAULT_SUMMARY_TEMPERATURE = 0.3
_DEFAULT_MIN_MESSAGES = 8
_DEFAULT_RECENT_MESSAGE_WINDOW = 24
_DEFAULT_RECENT_TOKEN_WINDOW = 3500
_DEFAULT_CHUNK_MIN_MESSAGES = 8
_DEFAULT_CHUNK_MAX_MESSAGES = 16
_DEFAULT_CHUNK_TARGET_TOKENS = 1800
_DEFAULT_MAX_INJECTED_SUMMARIES = 3


@dataclass(slots=True)
class TavernChatSummary:
    id: str
    content: str
    start_message_id: str
    start_message_index: int
    end_message_id: str
    end_message_index: int
    created_at: float
    source: str = 'auto'
    kind: str = 'chunk'
    message_count: int = 0
    token_count: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            'id': self.id,
            'content': self.content,
            'startMessageId': self.start_message_id,
            'startMessageIndex': self.start_message_index,
            'endMessageId': self.end_message_id,
            'endMessageIndex': self.end_message_index,
            'createdAt': self.created_at,
            'source': self.source,
            'kind': self.kind,
            'messageCount': self.message_count,
            'tokenCount': self.token_count,
        }


class TavernChatSummarizationService:
    def __init__(self) -> None:
        self.tokenizer = TavernTokenizerService()

    def get_settings(self, chat: dict[str, Any]) -> dict[str, Any]:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        summary_settings = metadata.get('summarySettings') if isinstance(metadata.get('summarySettings'), dict) else {}
        trigger_ratio = float(
            summary_settings.get('triggerRatio', summary_settings.get('threshold', _DEFAULT_SUMMARY_TRIGGER_RATIO))
            or _DEFAULT_SUMMARY_TRIGGER_RATIO
        )
        trigger_ratio = min(0.98, max(0.5, trigger_ratio))
        target_ratio = float(summary_settings.get('targetRatio', _DEFAULT_SUMMARY_TARGET_RATIO) or _DEFAULT_SUMMARY_TARGET_RATIO)
        target_ratio = min(trigger_ratio - 0.02, target_ratio) if trigger_ratio > 0.52 else target_ratio
        target_ratio = min(0.95, max(0.3, target_ratio))
        recent_message_window = max(0, int(summary_settings.get('recentMessageWindow', _DEFAULT_RECENT_MESSAGE_WINDOW) or _DEFAULT_RECENT_MESSAGE_WINDOW))
        recent_token_window = max(0, int(summary_settings.get('recentTokenWindow', _DEFAULT_RECENT_TOKEN_WINDOW) or _DEFAULT_RECENT_TOKEN_WINDOW))
        chunk_min_messages = max(1, int(summary_settings.get('chunkMinMessages', _DEFAULT_CHUNK_MIN_MESSAGES) or _DEFAULT_CHUNK_MIN_MESSAGES))
        chunk_max_messages = max(chunk_min_messages, int(summary_settings.get('chunkMaxMessages', _DEFAULT_CHUNK_MAX_MESSAGES) or _DEFAULT_CHUNK_MAX_MESSAGES))
        chunk_target_tokens = max(64, int(summary_settings.get('chunkTargetTokens', _DEFAULT_CHUNK_TARGET_TOKENS) or _DEFAULT_CHUNK_TARGET_TOKENS))
        max_injected_summaries = max(1, int(summary_settings.get('maxInjectedSummaries', _DEFAULT_MAX_INJECTED_SUMMARIES) or _DEFAULT_MAX_INJECTED_SUMMARIES))
        min_messages = max(2, int(summary_settings.get('minMessages', _DEFAULT_MIN_MESSAGES) or _DEFAULT_MIN_MESSAGES))
        return {
            'enabled': bool(summary_settings.get('enabled', True)),
            'triggerRatio': trigger_ratio,
            'targetRatio': target_ratio,
            'recentMessageWindow': recent_message_window,
            'recentTokenWindow': recent_token_window,
            'chunkMinMessages': chunk_min_messages,
            'chunkMaxMessages': chunk_max_messages,
            'chunkTargetTokens': chunk_target_tokens,
            'maxInjectedSummaries': max_injected_summaries,
            'injectLatestOnly': bool(summary_settings.get('injectLatestOnly', False)),
            'useRecentMessagesAfterLatest': bool(summary_settings.get('useRecentMessagesAfterLatest', True)),
            'minMessages': min_messages,
        }

    def trigger_ratio(self, chat: dict[str, Any]) -> float:
        return float(self.get_settings(chat).get('triggerRatio') or _DEFAULT_SUMMARY_TRIGGER_RATIO)

    def target_ratio(self, chat: dict[str, Any]) -> float:
        return float(self.get_settings(chat).get('targetRatio') or _DEFAULT_SUMMARY_TARGET_RATIO)

    def should_summarize(
        self,
        *,
        context_usage: dict[str, Any] | None,
        chat: dict[str, Any],
        message_count: int = 0,
        all_messages: list[dict[str, Any]] | None = None,
        existing_summaries: list[dict[str, Any]] | None = None,
    ) -> bool:
        settings = self.get_settings(chat)
        if not settings['enabled']:
            return False
        if message_count < int(settings['minMessages']):
            return False
        usage = context_usage or {}
        max_context = int(usage.get('maxContext') or 0)
        total_tokens = int(usage.get('totalTokens') or 0)
        if max_context <= 0 or total_tokens <= 0:
            return False
        if (total_tokens / max_context) < float(settings['triggerRatio']):
            return False
        candidate = self.select_chunk_for_summary(
            all_messages=list(all_messages or []),
            existing_summaries=list(existing_summaries or []),
            chat=chat,
        )
        return candidate is not None

    def list_summaries(self, chat: dict[str, Any]) -> list[dict[str, Any]]:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        raw = metadata.get('summaries') if isinstance(metadata.get('summaries'), list) else []
        items: list[dict[str, Any]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            content = str(item.get('content') or '').strip()
            if not content:
                continue
            items.append({
                'id': str(item.get('id') or '').strip() or f"sum_{uuid.uuid4().hex[:8]}",
                'content': content,
                'startMessageId': str(item.get('startMessageId') or '').strip(),
                'startMessageIndex': int(item.get('startMessageIndex') or 0),
                'endMessageId': str(item.get('endMessageId') or '').strip(),
                'endMessageIndex': int(item.get('endMessageIndex') or 0),
                'createdAt': float(item.get('createdAt') or 0),
                'source': str(item.get('source') or 'auto').strip() or 'auto',
                'kind': str(item.get('kind') or 'chunk').strip() or 'chunk',
                'messageCount': int(item.get('messageCount') or 0),
                'tokenCount': int(item.get('tokenCount') or 0),
            })
        items.sort(key=lambda item: (int(item.get('startMessageIndex') or 0), int(item.get('endMessageIndex') or 0), float(item.get('createdAt') or 0)))
        return items

    def summarized_until_index(self, existing_summaries: list[dict[str, Any]]) -> int:
        if not existing_summaries:
            return -1
        return max(int(item.get('endMessageIndex') or -1) for item in existing_summaries)

    def get_recent_messages(
        self,
        *,
        all_messages: list[dict[str, Any]],
        existing_summaries: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        summarized_until = self.summarized_until_index(existing_summaries)
        if summarized_until < 0:
            return list(all_messages)
        return list(all_messages[summarized_until + 1 :])

    def count_tokens_for_messages(self, messages: list[dict[str, Any]]) -> int:
        normalized: list[dict[str, Any]] = []
        for item in messages:
            content = str(item.get('content') or item.get('text') or '').strip()
            if not content:
                continue
            normalized.append({
                'role': str(item.get('role') or 'user').strip() or 'user',
                'content': content,
                'name': str(item.get('name') or '').strip(),
            })
        return self.tokenizer.estimate_messages_token_count(normalized)

    def protected_recent_start(
        self,
        *,
        all_messages: list[dict[str, Any]],
        chat: dict[str, Any],
    ) -> int:
        settings = self.get_settings(chat)
        count_start = max(0, len(all_messages) - int(settings['recentMessageWindow']))
        token_start = len(all_messages)
        token_budget = int(settings['recentTokenWindow'])
        if token_budget > 0:
            running = 0
            reached_budget = False
            for index in range(len(all_messages) - 1, -1, -1):
                running += self.tokenizer.estimate_message_token_count(all_messages[index])
                if running >= token_budget:
                    token_start = index
                    reached_budget = True
                    break
            if not reached_budget:
                token_start = len(all_messages)
        return min(count_start, token_start)

    def select_chunk_for_summary(
        self,
        *,
        all_messages: list[dict[str, Any]],
        existing_summaries: list[dict[str, Any]],
        chat: dict[str, Any],
    ) -> dict[str, Any] | None:
        if not all_messages:
            return None
        settings = self.get_settings(chat)
        summarized_until = self.summarized_until_index(existing_summaries)
        candidate_start = summarized_until + 1
        protected_start = self.protected_recent_start(all_messages=all_messages, chat=chat)
        compressible_end = min(max(candidate_start, protected_start), len(all_messages))
        if compressible_end - candidate_start < int(settings['chunkMinMessages']):
            return None

        chunk: list[dict[str, Any]] = []
        token_count = 0
        max_messages = int(settings['chunkMaxMessages'])
        min_messages = int(settings['chunkMinMessages'])
        target_tokens = int(settings['chunkTargetTokens'])

        for item in all_messages[candidate_start:compressible_end]:
            content = str(item.get('content') or item.get('text') or '').strip()
            if not content:
                continue
            chunk.append(item)
            token_count += self.tokenizer.estimate_message_token_count(item)
            if len(chunk) >= max_messages:
                break
            if len(chunk) >= min_messages and token_count >= target_tokens:
                break

        if len(chunk) < min_messages:
            return None

        start_message = chunk[0]
        end_message = chunk[-1]
        return {
            'messages': chunk,
            'startMessageId': str(start_message.get('id') or '').strip(),
            'startMessageIndex': int(candidate_start),
            'endMessageId': str(end_message.get('id') or '').strip(),
            'endMessageIndex': int(candidate_start + len(chunk) - 1),
            'messageCount': len(chunk),
            'tokenCount': token_count,
        }

    def generate_summary(
        self,
        *,
        chat: dict[str, Any],
        character: dict[str, Any],
        all_messages: list[dict[str, Any]],
        existing_summaries: list[dict[str, Any]],
        provider_config: dict[str, Any],
    ) -> dict[str, Any] | None:
        candidate = self.select_chunk_for_summary(
            all_messages=all_messages,
            existing_summaries=existing_summaries,
            chat=chat,
        )
        if candidate is None:
            return None
        chunk_messages = list(candidate['messages'])
        if len(chunk_messages) < 2:
            return None

        prompt = self._build_summarization_prompt(
            chunk_messages=chunk_messages,
            character_name=str(character.get('name') or 'Assistant').strip() or 'Assistant',
            user_name='User',
        )
        summary_config = dict(provider_config or {})
        summary_config['temperature'] = _DEFAULT_SUMMARY_TEMPERATURE
        summary_config['maxTokens'] = int(summary_config.get('summaryMaxTokens') or _DEFAULT_SUMMARY_MAX_TOKENS)
        client = TavernModelClient(summary_config)
        result = client.generate(messages=[
            {
                'role': 'system',
                'content': 'You are a precise narrative memory assistant. Produce concise but complete chunk summaries for long-context roleplay continuation.'
            },
            {
                'role': 'user',
                'content': prompt,
            },
        ])
        content = str(result.text or '').strip()
        if not content:
            return None
        end_message = chunk_messages[-1]
        summary = TavernChatSummary(
            id=f"sum_{uuid.uuid4().hex[:12]}",
            content=content,
            start_message_id=str(candidate.get('startMessageId') or '').strip(),
            start_message_index=int(candidate.get('startMessageIndex') or 0),
            end_message_id=str(candidate.get('endMessageId') or end_message.get('id') or '').strip(),
            end_message_index=int(candidate.get('endMessageIndex') or max(0, len(all_messages) - 1)),
            created_at=float(end_message.get('createdAt') or 0),
            kind='chunk',
            message_count=int(candidate.get('messageCount') or len(chunk_messages)),
            token_count=int(candidate.get('tokenCount') or self.count_tokens_for_messages(chunk_messages)),
        )
        return summary.to_dict()

    def append_summary_to_chat_metadata(
        self,
        *,
        chat: dict[str, Any],
        summary: dict[str, Any],
    ) -> dict[str, Any]:
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        summaries = self.list_summaries({'metadata': metadata})
        summaries.append(summary)
        summaries.sort(key=lambda item: (int(item.get('startMessageIndex') or 0), int(item.get('endMessageIndex') or 0), float(item.get('createdAt') or 0)))
        metadata['summaries'] = summaries
        summary_settings = dict(metadata.get('summarySettings') or {}) if isinstance(metadata.get('summarySettings'), dict) else {}
        summary_settings.setdefault('injectLatestOnly', False)
        summary_settings.setdefault('useRecentMessagesAfterLatest', True)
        summary_settings.setdefault('triggerRatio', _DEFAULT_SUMMARY_TRIGGER_RATIO)
        summary_settings.setdefault('targetRatio', _DEFAULT_SUMMARY_TARGET_RATIO)
        summary_settings.setdefault('recentMessageWindow', _DEFAULT_RECENT_MESSAGE_WINDOW)
        summary_settings.setdefault('recentTokenWindow', _DEFAULT_RECENT_TOKEN_WINDOW)
        summary_settings.setdefault('chunkMinMessages', _DEFAULT_CHUNK_MIN_MESSAGES)
        summary_settings.setdefault('chunkMaxMessages', _DEFAULT_CHUNK_MAX_MESSAGES)
        summary_settings.setdefault('chunkTargetTokens', _DEFAULT_CHUNK_TARGET_TOKENS)
        summary_settings.setdefault('maxInjectedSummaries', _DEFAULT_MAX_INJECTED_SUMMARIES)
        metadata['summarySettings'] = summary_settings
        return metadata

    def _build_summarization_prompt(
        self,
        *,
        chunk_messages: list[dict[str, Any]],
        character_name: str,
        user_name: str,
    ) -> str:
        lines: list[str] = [
            'Summarize this older conversation segment for long-context roleplay continuation.',
            'This is one chunk from the far history, not the latest conversation.',
            'Keep it factual, compact, and useful for future prompt injection.',
            'Preserve important facts, emotional shifts, decisions, promises, unresolved threads, and durable scene state.',
            'Prefer concrete details over vague abstraction.',
            'Write in clear prose, no bullet list unless necessary.',
            '',
            '=== CHUNK TO SUMMARIZE ===',
        ]
        for message in chunk_messages:
            role = str(message.get('role') or 'user').strip().lower()
            speaker = character_name if role == 'assistant' else user_name
            content = str(message.get('content') or '').strip()
            if content:
                lines.append(f'{speaker}: {content}')
        lines.extend([
            '',
            'Return only the chunk summary text.',
        ])
        return '\n'.join(lines)
