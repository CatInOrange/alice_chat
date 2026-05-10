from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable
from urllib.request import Request, urlopen


StreamEmitter = Callable[[dict[str, Any]], None]


@dataclass(slots=True)
class TavernModelResponse:
    text: str
    raw: dict[str, Any]


class TavernModelClient:
    """Tavern-dedicated direct LLM client.

    This path is intentionally separate from the main chat/OpenClaw pipeline.
    Supports OpenAI-compatible chat completions and anthropic-messages style APIs.
    """

    def __init__(self, provider_config: dict[str, Any]):
        self.provider_config = dict(provider_config or {})

    def generate(self, *, messages: list[dict[str, Any]]) -> TavernModelResponse:
        endpoint = self._endpoint()
        payload = self._build_payload(messages=messages, stream=False)
        raw = self._post_json(endpoint, payload)
        text = self._extract_text(raw)
        return TavernModelResponse(text=text, raw=raw)

    def stream_generate(self, *, messages: list[dict[str, Any]], emit: StreamEmitter) -> TavernModelResponse:
        endpoint = self._endpoint()
        payload = self._build_payload(messages=messages, stream=True)
        req = Request(endpoint, data=json.dumps(payload).encode('utf-8'), headers=self._headers(), method='POST')
        chunks: list[str] = []
        with urlopen(req, timeout=self._timeout_seconds()) as resp:
            for raw_line in resp:
                line = raw_line.decode('utf-8', errors='ignore').strip()
                if not line or not line.startswith('data:'):
                    continue
                data = line[5:].strip()
                if not data or data == '[DONE]':
                    continue
                try:
                    frame = json.loads(data)
                except Exception:
                    continue
                delta = self._extract_delta(frame)
                if delta:
                    chunks.append(delta)
                    emit({'delta': delta, 'raw': frame})
        text = ''.join(chunks).strip()
        return TavernModelResponse(text=text, raw={'streamed': True, 'text': text})

    def _api_kind(self) -> str:
        return str(self.provider_config.get('api') or 'openai-chat-completions').strip() or 'openai-chat-completions'

    def _endpoint(self) -> str:
        explicit = str(self.provider_config.get('endpoint') or '').strip()
        if explicit:
            return explicit
        base_url = str(self.provider_config.get('baseUrl') or '').rstrip('/')
        if not base_url:
            raise ValueError('tavern provider missing baseUrl')
        if self._api_kind() == 'anthropic-messages':
            return f'{base_url}/v1/messages'
        return f'{base_url}/chat/completions'

    def _build_payload(self, *, messages: list[dict[str, Any]], stream: bool) -> dict[str, Any]:
        if self._api_kind() == 'anthropic-messages':
            return self._build_anthropic_payload(messages=messages, stream=stream)
        payload = {
            'model': str(self.provider_config.get('model') or '').strip(),
            'messages': messages,
            'stream': stream,
            'temperature': float(self.provider_config.get('temperature', 1.0) or 1.0),
            'top_p': float(self.provider_config.get('topP', 1.0) or 1.0),
            'frequency_penalty': float(self.provider_config.get('frequencyPenalty', 0.0) or 0.0),
            'presence_penalty': float(self.provider_config.get('presencePenalty', 0.0) or 0.0),
        }
        max_tokens = self.provider_config.get('maxTokens')
        if max_tokens not in (None, '', 0, '0'):
            payload['max_tokens'] = int(max_tokens)

        self._apply_reasoning_options(payload)

        def add_optional(name: str, value: Any) -> None:
            if value in (None, ''):
                return
            payload[name] = value

        extra_param_mode = str(self.provider_config.get('extraSamplingParams') or 'openai-compatible').strip() or 'openai-compatible'
        if extra_param_mode != 'openai-strict':
            add_optional('top_k', int(self.provider_config.get('topK') or 0))
            add_optional('top_a', float(self.provider_config.get('topA') or 0.0))
            add_optional('min_p', float(self.provider_config.get('minP') or 0.0))
            add_optional('typical_p', float(self.provider_config.get('typicalP') or 1.0))
            add_optional('repetition_penalty', float(self.provider_config.get('repetitionPenalty') or 1.0))
        stop = self.provider_config.get('stopSequences') or []
        if stop:
            payload['stop'] = stop
        return payload

    def _apply_reasoning_options(self, payload: dict[str, Any]) -> None:
        thinking_enabled = self.provider_config.get('thinkingEnabled') is True
        reasoning_effort = str(self.provider_config.get('reasoningEffort') or '').strip()
        thinking_budget = self.provider_config.get('thinkingBudget')
        model_name = str(self.provider_config.get('model') or '').strip().lower()
        base_url = str(self.provider_config.get('baseUrl') or '').strip().lower()
        is_deepseek = 'deepseek' in base_url or model_name.startswith('deepseek')
        if not is_deepseek:
            return
        if thinking_enabled:
            payload['thinking'] = {'type': 'enabled'}
            if reasoning_effort in {'low', 'medium', 'high'}:
                payload['reasoning_effort'] = reasoning_effort
            if thinking_budget not in (None, '', 0, '0'):
                try:
                    payload['thinking_budget'] = int(thinking_budget)
                except Exception:
                    pass
        elif model_name.endswith('reasoner'):
            payload['thinking'] = {'type': 'disabled'}

    def _build_anthropic_payload(self, *, messages: list[dict[str, Any]], stream: bool) -> dict[str, Any]:
        system_parts: list[str] = []
        anthropic_messages: list[dict[str, Any]] = []
        for message in messages:
            role = str(message.get('role') or 'user').strip()
            content = str(message.get('content') or '').strip()
            if not content:
                continue
            if role == 'system':
                system_parts.append(content)
                continue
            mapped_role = 'assistant' if role == 'assistant' else 'user'
            anthropic_messages.append({
                'role': mapped_role,
                'content': content,
            })
        payload = {
            'model': str(self.provider_config.get('model') or '').strip(),
            'messages': anthropic_messages,
            'stream': stream,
            'temperature': float(self.provider_config.get('temperature', 1.0) or 1.0),
            'top_p': float(self.provider_config.get('topP', 1.0) or 1.0),
            'max_tokens': int(self.provider_config.get('maxTokens') or 1024),
        }
        if system_parts:
            payload['system'] = '\n\n'.join(system_parts)
        stop = self.provider_config.get('stopSequences') or []
        if stop:
            payload['stop_sequences'] = stop
        return payload

    def _headers(self) -> dict[str, str]:
        headers = {
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream, application/json',
        }
        api_key = str(self.provider_config.get('apiKey') or '').strip()
        if self._api_kind() == 'anthropic-messages':
            if api_key:
                headers['x-api-key'] = api_key
            headers['anthropic-version'] = str(self.provider_config.get('anthropicVersion') or '2023-06-01')
            return headers
        if api_key:
            headers['Authorization'] = f'Bearer {api_key}'
        return headers

    def _timeout_seconds(self) -> int:
        try:
            return max(5, int(float(self.provider_config.get('timeoutSeconds') or 120)))
        except Exception:
            return 120

    def _post_json(self, endpoint: str, payload: dict[str, Any]) -> dict[str, Any]:
        req = Request(endpoint, data=json.dumps(payload).encode('utf-8'), headers=self._headers(), method='POST')
        with urlopen(req, timeout=self._timeout_seconds()) as resp:
            raw = resp.read().decode('utf-8', errors='ignore')
        return json.loads(raw or '{}')

    def _extract_text(self, raw: dict[str, Any]) -> str:
        if self._api_kind() == 'anthropic-messages':
            content = raw.get('content')
            if isinstance(content, list):
                parts: list[str] = []
                for item in content:
                    if isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str):
                        parts.append(item['text'])
                return ''.join(parts).strip()
            return ''
        choices = raw.get('choices') or []
        if not choices:
            return ''
        first = choices[0] or {}
        message = first.get('message') or {}
        content = message.get('content')
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str):
                    parts.append(item['text'])
            return ''.join(parts).strip()
        return ''

    def _extract_delta(self, raw: dict[str, Any]) -> str:
        if self._api_kind() == 'anthropic-messages':
            if raw.get('type') == 'content_block_delta':
                delta = raw.get('delta') or {}
                text = delta.get('text')
                return text if isinstance(text, str) else ''
            return ''
        choices = raw.get('choices') or []
        if not choices:
            return ''
        delta = (choices[0] or {}).get('delta') or {}
        content = delta.get('content')
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str):
                    parts.append(item['text'])
            return ''.join(parts)
        return ''
