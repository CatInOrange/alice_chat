from __future__ import annotations

from dataclasses import dataclass
from typing import Any
import re


@dataclass(slots=True)
class PromptRuntimeContext:
    values: dict[str, str]

    def preview(self) -> dict[str, str]:
        return dict(self.values)


class PromptTemplateRenderer:
    _IF_PATTERN = re.compile(r"\{\{#if\s+([a-zA-Z0-9_]+)\}\}(.*?)\{\{/if\}\}", re.DOTALL)
    _VAR_PATTERN = re.compile(r"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}")

    def render(self, template: str, context: PromptRuntimeContext) -> str:
        text = str(template or '')
        if not text:
            return ''

        def _if_replace(match: re.Match[str]) -> str:
            key = match.group(1)
            body = match.group(2)
            return body if context.values.get(key, '').strip() else ''

        rendered = self._IF_PATTERN.sub(_if_replace, text)

        def _var_replace(match: re.Match[str]) -> str:
            key = match.group(1)
            return context.values.get(key, '')

        rendered = self._VAR_PATTERN.sub(_var_replace, rendered)
        lines = [line.rstrip() for line in rendered.splitlines()]
        return '\n'.join(line for line in lines if line.strip()).strip()


def build_prompt_runtime_context(
    *,
    character: dict[str, Any],
    chat: dict[str, Any] | None,
    history: list[dict[str, Any]] | None,
    user_text: str,
    persona_name: str = 'User',
) -> PromptRuntimeContext:
    history = list(history or [])
    last_message = ''
    last_user_message = ''
    last_char_message = ''
    for item in reversed(history):
        content = str(item.get('content') or item.get('text') or '').strip()
        role = str(item.get('role') or '').strip()
        if not content:
            continue
        if not last_message:
            last_message = content
        if role == 'user' and not last_user_message:
            last_user_message = content
        if role == 'assistant' and not last_char_message:
            last_char_message = content
        if last_message and last_user_message and last_char_message:
            break

    values = {
        'char': str(character.get('name') or 'Character').strip() or 'Character',
        'user': persona_name.strip() or 'User',
        'persona': str((chat or {}).get('personaName') or '').strip(),
        'description': str(character.get('description') or '').strip(),
        'personality': str(character.get('personality') or '').strip(),
        'scenario': str(character.get('scenario') or '').strip(),
        'system': str(character.get('systemPrompt') or '').strip(),
        'postHistoryInstructions': str(character.get('postHistoryInstructions') or '').strip(),
        'creatorNotes': str(character.get('creatorNotes') or '').strip(),
        'lastMessage': last_message,
        'lastUserMessage': last_user_message,
        'lastCharMessage': last_char_message,
        'userInput': str(user_text or '').strip(),
    }
    return PromptRuntimeContext(values=values)
