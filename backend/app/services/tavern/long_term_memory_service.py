from __future__ import annotations

import json
import time
import uuid
from typing import Any

from .model_client import TavernModelClient


_DEFAULT_MAX_INJECTED_ITEMS = 8
_DEFAULT_MAX_INJECTED_TOKENS = 800
_DEFAULT_EXTRACTION_MAX_TOKENS = 900
_ALLOWED_CATEGORIES = {
    'relationship',
    'identity',
    'preference',
    'promise',
    'world_state',
    'unresolved_thread',
    'boundary',
    'note',
}


class TavernLongTermMemoryService:
    def get_settings(self, chat: dict[str, Any]) -> dict[str, Any]:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        summary_settings = metadata.get('summarySettings') if isinstance(metadata.get('summarySettings'), dict) else {}
        return {
            'enabled': bool(summary_settings.get('longTermMemoryEnabled', True)),
            'maxInjectedItems': max(1, int(summary_settings.get('maxInjectedLongTermItems', _DEFAULT_MAX_INJECTED_ITEMS) or _DEFAULT_MAX_INJECTED_ITEMS)),
            'maxInjectedTokens': max(64, int(summary_settings.get('maxInjectedLongTermTokens', _DEFAULT_MAX_INJECTED_TOKENS) or _DEFAULT_MAX_INJECTED_TOKENS)),
        }

    def list_items(self, chat: dict[str, Any]) -> list[dict[str, Any]]:
        metadata = chat.get('metadata') if isinstance(chat.get('metadata'), dict) else {}
        memory = metadata.get('longTermMemory') if isinstance(metadata.get('longTermMemory'), dict) else {}
        raw = memory.get('items') if isinstance(memory.get('items'), list) else []
        items: list[dict[str, Any]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            content = str(item.get('content') or '').strip()
            if not content:
                continue
            items.append({
                'id': str(item.get('id') or '').strip() or f"ltm_{uuid.uuid4().hex[:10]}",
                'category': str(item.get('category') or 'note').strip() or 'note',
                'content': content,
                'priority': int(item.get('priority') or 1),
                'confidence': float(item.get('confidence') or 0),
                'createdAt': float(item.get('createdAt') or 0),
                'updatedAt': float(item.get('updatedAt') or item.get('createdAt') or 0),
                'sourceSummaryIds': list(item.get('sourceSummaryIds') or []),
                'sourceMessageIds': list(item.get('sourceMessageIds') or []),
                'active': bool(item.get('active', True)),
            })
        items.sort(
            key=lambda item: (
                0 if bool(item.get('active', True)) else 1,
                -int(item.get('priority') or 0),
                -float(item.get('updatedAt') or 0),
                -float(item.get('createdAt') or 0),
            )
        )
        return items

    def build_prompt_items(self, chat: dict[str, Any], *, tokenizer: Any | None = None) -> list[dict[str, Any]]:
        settings = self.get_settings(chat)
        if not settings['enabled']:
            return []
        items = [item for item in self.list_items(chat) if bool(item.get('active', True))]
        max_items = int(settings['maxInjectedItems'])
        max_tokens = int(settings['maxInjectedTokens'])
        selected: list[dict[str, Any]] = []
        used_tokens = 0
        estimate = (tokenizer.estimate_token_count if tokenizer is not None else lambda text: max(1, len(str(text or '')) // 4))
        for item in items:
            line = self._render_item_line(item)
            token_count = int(item.get('tokenCount') or 0) or estimate(line)
            if selected and (len(selected) >= max_items or used_tokens + token_count > max_tokens):
                continue
            selected.append({
                **item,
                'rendered': line,
                'tokenCount': token_count,
            })
            used_tokens += token_count
            if len(selected) >= max_items or used_tokens >= max_tokens:
                break
        return selected

    def render_prompt_block(self, chat: dict[str, Any], *, tokenizer: Any | None = None) -> str:
        items = self.build_prompt_items(chat, tokenizer=tokenizer)
        if not items:
            return ''
        lines = ['[Long-term memory]']
        for item in items:
            lines.append(self._render_item_line(item))
        return '\n'.join(lines).strip()

    def ensure_metadata_shape(self, chat: dict[str, Any]) -> dict[str, Any]:
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        raw = metadata.get('longTermMemory') if isinstance(metadata.get('longTermMemory'), dict) else {}
        metadata['longTermMemory'] = {
            'version': int(raw.get('version') or 1),
            'updatedAt': float(raw.get('updatedAt') or 0),
            'items': list(raw.get('items') or []),
        }
        return metadata

    def extract_and_merge(
        self,
        *,
        chat: dict[str, Any],
        new_summaries: list[dict[str, Any]],
        provider_config: dict[str, Any],
    ) -> dict[str, Any]:
        metadata = self.ensure_metadata_shape(chat)
        if not new_summaries:
            return metadata
        settings = self.get_settings(chat)
        if not settings['enabled']:
            return metadata
        extracted = self._extract_memory_items(
            chat={**chat, 'metadata': metadata},
            new_summaries=new_summaries,
            provider_config=provider_config,
        )
        if not extracted:
            return metadata
        merged_items = self._merge_items(self.list_items({**chat, 'metadata': metadata}), extracted)
        metadata['longTermMemory'] = {
            'version': 1,
            'updatedAt': time.time(),
            'items': merged_items,
        }
        return metadata

    def _extract_memory_items(
        self,
        *,
        chat: dict[str, Any],
        new_summaries: list[dict[str, Any]],
        provider_config: dict[str, Any],
    ) -> list[dict[str, Any]]:
        existing_items = self.list_items(chat)
        prompt = self._build_extraction_prompt(existing_items=existing_items, new_summaries=new_summaries)
        extraction_config = dict(provider_config or {})
        extraction_config['temperature'] = 0.2
        extraction_config['maxTokens'] = int(extraction_config.get('longTermMemoryMaxTokens') or _DEFAULT_EXTRACTION_MAX_TOKENS)
        client = TavernModelClient(extraction_config)
        result = client.generate(messages=[
            {
                'role': 'system',
                'content': (
                    'You extract durable long-term memory facts for roleplay continuity. '
                    'Return strict JSON only. Prefer stable facts over transient narration. '
                    'Never include markdown fences.'
                ),
            },
            {
                'role': 'user',
                'content': prompt,
            },
        ])
        return self._parse_extraction_result(str(result.text or ''))

    def _build_extraction_prompt(
        self,
        *,
        existing_items: list[dict[str, Any]],
        new_summaries: list[dict[str, Any]],
    ) -> str:
        lines: list[str] = [
            'Update the long-term memory store from the new summary chunks.',
            'Only keep durable facts useful across future scenes.',
            'Do not store temporary moment-to-moment narration unless it remains canonically important.',
            'Allowed categories: relationship, identity, preference, promise, world_state, unresolved_thread, boundary, note.',
            'Return JSON object: {"items": [...]}',
            'Each item may contain: id, category, content, priority, confidence, active, replaceIds.',
            'Use replaceIds when a new item supersedes an old memory item.',
            'Set active=false only when intentionally deactivating or resolving an existing memory line.',
            '',
            '=== EXISTING LONG-TERM MEMORY ===',
        ]
        if existing_items:
            for item in existing_items[:24]:
                lines.append(json.dumps({
                    'id': item.get('id'),
                    'category': item.get('category'),
                    'content': item.get('content'),
                    'priority': item.get('priority'),
                    'confidence': item.get('confidence'),
                    'active': item.get('active', True),
                }, ensure_ascii=False))
        else:
            lines.append('[]')
        lines.extend(['', '=== NEW SUMMARY CHUNKS ==='])
        for item in new_summaries:
            payload = {
                'id': item.get('id'),
                'content': str(item.get('content') or '').strip(),
                'startMessageIndex': item.get('startMessageIndex'),
                'endMessageIndex': item.get('endMessageIndex'),
                'messageCount': item.get('messageCount'),
            }
            lines.append(json.dumps(payload, ensure_ascii=False))
        lines.extend(['', 'Return strict JSON only.'])
        return '\n'.join(lines)

    def _parse_extraction_result(self, text: str) -> list[dict[str, Any]]:
        text = text.strip()
        if not text:
            return []
        start = text.find('{')
        end = text.rfind('}')
        if start < 0 or end <= start:
            return []
        try:
            payload = json.loads(text[start:end + 1])
        except Exception:
            return []
        raw_items = payload.get('items') if isinstance(payload, dict) else None
        if not isinstance(raw_items, list):
            return []
        parsed: list[dict[str, Any]] = []
        now = time.time()
        for raw in raw_items:
            if not isinstance(raw, dict):
                continue
            content = str(raw.get('content') or '').strip()
            if not content:
                continue
            category = str(raw.get('category') or 'note').strip() or 'note'
            if category not in _ALLOWED_CATEGORIES:
                category = 'note'
            parsed.append({
                'id': str(raw.get('id') or '').strip() or f'ltm_{uuid.uuid4().hex[:10]}',
                'category': category,
                'content': content,
                'priority': min(5, max(1, int(raw.get('priority') or 1))),
                'confidence': min(1.0, max(0.0, float(raw.get('confidence') or 0.7))),
                'createdAt': float(raw.get('createdAt') or now),
                'updatedAt': now,
                'sourceSummaryIds': list(raw.get('sourceSummaryIds') or []),
                'sourceMessageIds': list(raw.get('sourceMessageIds') or []),
                'active': bool(raw.get('active', True)),
                'replaceIds': [str(item).strip() for item in (raw.get('replaceIds') or []) if str(item).strip()],
            })
        return parsed

    def _merge_items(self, existing: list[dict[str, Any]], incoming: list[dict[str, Any]]) -> list[dict[str, Any]]:
        items = [dict(item) for item in existing]
        index_by_id = {str(item.get('id')): idx for idx, item in enumerate(items) if str(item.get('id') or '').strip()}
        index_by_key = {
            self._content_key(item): idx
            for idx, item in enumerate(items)
            if self._content_key(item)
        }
        for item in incoming:
            replace_ids = [rid for rid in item.get('replaceIds', []) if rid]
            for rid in replace_ids:
                idx = index_by_id.get(rid)
                if idx is not None:
                    items[idx]['active'] = False
                    items[idx]['updatedAt'] = item.get('updatedAt') or time.time()
            key = self._content_key(item)
            existing_idx = index_by_id.get(str(item.get('id') or ''))
            if existing_idx is None and key:
                existing_idx = index_by_key.get(key)
            if existing_idx is not None:
                merged = dict(items[existing_idx])
                merged.update({k: v for k, v in item.items() if k != 'replaceIds'})
                merged['sourceSummaryIds'] = sorted({
                    *[str(v) for v in (items[existing_idx].get('sourceSummaryIds') or []) if str(v).strip()],
                    *[str(v) for v in (item.get('sourceSummaryIds') or []) if str(v).strip()],
                })
                merged['sourceMessageIds'] = sorted({
                    *[str(v) for v in (items[existing_idx].get('sourceMessageIds') or []) if str(v).strip()],
                    *[str(v) for v in (item.get('sourceMessageIds') or []) if str(v).strip()],
                })
                items[existing_idx] = merged
                index_by_id[str(merged.get('id'))] = existing_idx
                if key:
                    index_by_key[key] = existing_idx
                continue
            new_item = {k: v for k, v in item.items() if k != 'replaceIds'}
            items.append(new_item)
            new_idx = len(items) - 1
            index_by_id[str(new_item.get('id'))] = new_idx
            if key:
                index_by_key[key] = new_idx
        items.sort(
            key=lambda item: (
                0 if bool(item.get('active', True)) else 1,
                -int(item.get('priority') or 0),
                -float(item.get('updatedAt') or 0),
                -float(item.get('createdAt') or 0),
            )
        )
        return items

    def _content_key(self, item: dict[str, Any]) -> str:
        category = str(item.get('category') or 'note').strip()
        content = ' '.join(str(item.get('content') or '').lower().split())
        if not content:
            return ''
        return f'{category}:{content[:120]}'

    def _render_item_line(self, item: dict[str, Any]) -> str:
        category = str(item.get('category') or 'note').strip().replace('_', ' ')
        content = str(item.get('content') or '').strip()
        return f'- {category}: {content}'
