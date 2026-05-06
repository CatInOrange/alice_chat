from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from .model_client import TavernModelClient


_DEFAULT_AUTO_SUMMARIZE_THRESHOLD = 0.8
_DEFAULT_SUMMARY_MAX_TOKENS = 1024
_DEFAULT_SUMMARY_TEMPERATURE = 0.3


@dataclass(slots=True)
class TavernChatSummary:
    id: str
    content: str
    end_message_id: str
    end_message_index: int
    created_at: float
    source: str = 'auto'

    def to_dict(self) -> dict[str, Any]:
        return {
            'id': self.id,
            'content': self.content,
            'endMessageId': self.end_message_id,
            'endMessageIndex': self.end_message_index,
            'createdAt': self.created_at,
            'source': self.source,
        }


class TavernChatSummarizationService:
    def should_summarize(
        self,
        *,
        context_usage: dict[str, Any] | None,
        chat: dict[str, Any],
        message_count: int = 0,
        new_message_count: int = 0,
        new_token_count: int = 0,
        existing_summaries: list[dict[str, Any]] | None = None,
        latest_message: dict[str, Any] | None = None,
    ) -> bool:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        summary_settings = metadata.get('summarySettings') if isinstance(metadata.get('summarySettings'), dict) else {}
        enabled = bool(summary_settings.get('enabled', True))
        if not enabled:
            return False
        threshold = float(summary_settings.get('threshold', _DEFAULT_AUTO_SUMMARIZE_THRESHOLD) or _DEFAULT_AUTO_SUMMARIZE_THRESHOLD)
        min_messages = int(summary_settings.get('minMessages', 8) or 8)
        min_new_messages = int(summary_settings.get('minNewMessages', 4) or 4)
        min_new_tokens = int(summary_settings.get('minNewTokens', 192) or 192)
        if message_count < min_messages:
            return False
        if new_message_count < min_new_messages:
            return False
        if new_token_count < min_new_tokens:
            return False
        summaries = list(existing_summaries or [])
        if summaries and latest_message is not None:
            latest_summary = summaries[-1]
            if str(latest_summary.get('endMessageId') or '').strip() == str(latest_message.get('id') or '').strip():
                return False
        usage = context_usage or {}
        max_context = int(usage.get('maxContext') or 0)
        total_tokens = int(usage.get('totalTokens') or 0)
        if max_context <= 0 or total_tokens <= 0:
            return False
        return (total_tokens / max_context) >= threshold

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
                'endMessageId': str(item.get('endMessageId') or '').strip(),
                'endMessageIndex': int(item.get('endMessageIndex') or 0),
                'createdAt': float(item.get('createdAt') or 0),
                'source': str(item.get('source') or 'auto').strip() or 'auto',
            })
        return items

    def get_recent_messages(
        self,
        *,
        all_messages: list[dict[str, Any]],
        existing_summaries: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        if not existing_summaries:
            return list(all_messages)
        latest = existing_summaries[-1]
        end_message_id = str(latest.get('endMessageId') or '').strip()
        end_message_index = int(latest.get('endMessageIndex') or -1)
        if end_message_id:
            for index, item in enumerate(all_messages):
                if str(item.get('id') or '').strip() == end_message_id:
                    return list(all_messages[index + 1 :])
        if end_message_index >= 0:
            return list(all_messages[end_message_index + 1 :])
        return list(all_messages)

    def count_tokens_for_messages(self, messages: list[dict[str, Any]]) -> int:
        total = 0
        for item in messages:
            content = str(item.get('content') or item.get('text') or '').strip()
            if not content:
                continue
            total += max(1, int((len(content) / 3.35) + 0.999999))
        return total

    def generate_summary(
        self,
        *,
        chat: dict[str, Any],
        character: dict[str, Any],
        all_messages: list[dict[str, Any]],
        existing_summaries: list[dict[str, Any]],
        provider_config: dict[str, Any],
    ) -> dict[str, Any] | None:
        recent_messages = self.get_recent_messages(all_messages=all_messages, existing_summaries=existing_summaries)
        if len(recent_messages) < 2:
            return None

        prompt = self._build_summarization_prompt(
            existing_summaries=existing_summaries,
            recent_messages=recent_messages,
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
                'content': 'You are a precise narrative memory assistant. Produce concise but complete conversation summaries.'
            },
            {
                'role': 'user',
                'content': prompt,
            },
        ])
        content = str(result.text or '').strip()
        if not content:
            return None
        end_message = recent_messages[-1]
        summary = TavernChatSummary(
            id=f"sum_{uuid.uuid4().hex[:12]}",
            content=content,
            end_message_id=str(end_message.get('id') or '').strip(),
            end_message_index=max(0, len(all_messages) - 1),
            created_at=float(end_message.get('createdAt') or 0),
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
        metadata['summaries'] = summaries
        summary_settings = dict(metadata.get('summarySettings') or {}) if isinstance(metadata.get('summarySettings'), dict) else {}
        summary_settings.setdefault('injectLatestOnly', True)
        summary_settings.setdefault('useRecentMessagesAfterLatest', True)
        metadata['summarySettings'] = summary_settings
        return metadata

    def _build_summarization_prompt(
        self,
        *,
        existing_summaries: list[dict[str, Any]],
        recent_messages: list[dict[str, Any]],
        character_name: str,
        user_name: str,
    ) -> str:
        lines: list[str] = [
            'Summarize the conversation memory for long-context roleplay/chat continuation.',
            'Keep it factual, compact, and useful for future prompt injection.',
            'Preserve important facts, emotional shifts, decisions, promises, unresolved threads, and current scene state.',
            'Prefer concrete details over vague abstraction.',
            'Write in clear prose, no bullet list unless necessary.',
            '',
        ]
        if existing_summaries:
            lines.extend([
                '=== PREVIOUS SUMMARY ===',
                str(existing_summaries[-1].get('content') or '').strip(),
                '',
                '=== NEW MESSAGES TO MERGE ===',
            ])
        else:
            lines.append('=== MESSAGES TO SUMMARIZE ===')
        for message in recent_messages:
            role = str(message.get('role') or 'user').strip().lower()
            speaker = character_name if role == 'assistant' else user_name
            content = str(message.get('content') or '').strip()
            if content:
                lines.append(f'{speaker}: {content}')
        lines.extend([
            '',
            'Return only the updated summary text.',
        ])
        return '\n'.join(lines)
