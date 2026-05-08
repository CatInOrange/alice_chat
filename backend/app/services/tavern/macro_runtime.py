from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
import json
import random
import re
import uuid
from typing import Any


def normalize_legacy_angle_bracket_placeholders(text: str) -> str:
    normalized = str(text or '')
    if not normalized:
        return ''
    replacements = {
        '<user>': '{{user}}',
        '<USER>': '{{user}}',
        '<char>': '{{char}}',
        '<CHAR>': '{{char}}',
        '<persona>': '{{persona}}',
        '<PERSONA>': '{{persona}}',
    }
    for src, dst in replacements.items():
        normalized = normalized.replace(src, dst)
    return normalized


@dataclass(slots=True)
class MacroRuntimeContext:
    values: dict[str, str]
    local_variables: dict[str, Any] = field(default_factory=dict)
    global_variables: dict[str, Any] = field(default_factory=dict)

    def preview(self) -> dict[str, str]:
        return dict(self.values)


@dataclass(slots=True)
class MacroEffect:
    scope: str
    op: str
    name: str
    value: Any


@dataclass(slots=True)
class MacroRenderResult:
    text: str
    effects: list[MacroEffect]
    unknown_macros: list[str]


class MacroEngine:
    _IF_BLOCK_PATTERN = re.compile(r"\{\{#if\s+([a-zA-Z0-9_]+)\}\}(.*?)\{\{/if\}\}", re.DOTALL)
    _GENERIC_MACRO_PATTERN = re.compile(r"\{\{\s*([^{}]+?)\s*\}\}")

    def render(
        self,
        template: str,
        context: MacroRuntimeContext,
        *,
        allow_side_effects: bool = False,
    ) -> MacroRenderResult:
        text = normalize_legacy_angle_bracket_placeholders(str(template or ''))
        if not text:
            return MacroRenderResult(text='', effects=[], unknown_macros=[])

        effects: list[MacroEffect] = []
        unknown_macros: list[str] = []

        def replace_if_block(match: re.Match[str]) -> str:
            key = str(match.group(1) or '').strip()
            body = str(match.group(2) or '')
            return body if self._truthy(context.values.get(key, '')) else ''

        rendered = self._IF_BLOCK_PATTERN.sub(replace_if_block, text)

        def replace_macro(match: re.Match[str]) -> str:
            raw = str(match.group(1) or '').strip()
            if not raw:
                return ''
            result = self._evaluate_macro(
                raw,
                context,
                allow_side_effects=allow_side_effects,
                effects=effects,
                unknown_macros=unknown_macros,
            )
            return result

        rendered = self._GENERIC_MACRO_PATTERN.sub(replace_macro, rendered)
        lines = [line.rstrip() for line in rendered.splitlines()]
        normalized = '\n'.join(line for line in lines if line.strip()).strip()
        return MacroRenderResult(text=normalized, effects=effects, unknown_macros=unknown_macros)

    def _evaluate_macro(
        self,
        raw: str,
        context: MacroRuntimeContext,
        *,
        allow_side_effects: bool,
        effects: list[MacroEffect],
        unknown_macros: list[str],
    ) -> str:
        parts = [part.strip() for part in raw.split('::')]
        head = (parts[0] or '').strip().lower()

        simple = self._simple_macro_value(raw, context)
        if simple is not None:
            return simple

        if head == 'if':
            return self._macro_if(parts[1:], context)
        if head == 'random':
            return self._macro_random(parts[1:])
        if head == 'roll':
            return self._macro_roll(parts[1:])
        if head == 'pick':
            return self._macro_pick(parts[1:])
        if head == 'uuid':
            return uuid.uuid4().hex

        if head in {'getvar', 'setvar', 'addvar', 'incvar', 'decvar'}:
            return self._macro_variable('local', head, parts[1:], context, allow_side_effects, effects)
        if head in {'getglobalvar', 'setglobalvar', 'addglobalvar', 'incglobalvar', 'decglobalvar'}:
            return self._macro_variable('global', head, parts[1:], context, allow_side_effects, effects)

        unknown_macros.append('{{' + raw + '}}')
        return ''

    def _simple_macro_value(self, raw: str, context: MacroRuntimeContext) -> str | None:
        key = raw.strip()
        lower = key.lower()
        if lower in {'trim', 'noop'}:
            return ''
        if lower in {'newline', 'nl'}:
            return '\n'
        if lower in {k.lower() for k in context.values.keys()}:
            for actual_key, value in context.values.items():
                if actual_key.lower() == lower:
                    return str(value or '')
        return None

    def _macro_if(self, args: list[str], context: MacroRuntimeContext) -> str:
        if not args:
            return ''
        condition = args[0] if len(args) > 0 else ''
        then_value = args[1] if len(args) > 1 else ''
        else_value = args[2] if len(args) > 2 else ''
        return then_value if self._evaluate_condition(condition, context) else else_value

    def _macro_random(self, args: list[str]) -> str:
        if len(args) >= 2:
            try:
                start = int(args[0])
                end = int(args[1])
                if start > end:
                    start, end = end, start
                return str(random.randint(start, end))
            except Exception:
                return ''
        return str(random.randint(0, 100))

    def _macro_roll(self, args: list[str]) -> str:
        if not args:
            return ''
        formula = str(args[0]).strip().lower()
        match = re.fullmatch(r'(\d*)d(\d+)', formula)
        if not match:
            return ''
        count = int(match.group(1) or '1')
        sides = int(match.group(2) or '0')
        if count <= 0 or sides <= 0:
            return '0'
        total = 0
        for _ in range(min(count, 1000)):
            total += random.randint(1, sides)
        return str(total)

    def _macro_pick(self, args: list[str]) -> str:
        options = [item for item in args if item != '']
        if not options:
            return ''
        return random.choice(options)

    def _macro_variable(
        self,
        scope: str,
        head: str,
        args: list[str],
        context: MacroRuntimeContext,
        allow_side_effects: bool,
        effects: list[MacroEffect],
    ) -> str:
        storage = context.local_variables if scope == 'local' else context.global_variables
        base_head = head.lower()
        if base_head in {'getvar', 'getglobalvar'}:
            name = args[0] if args else ''
            return self._stringify(storage.get(name, ''))

        name = args[0] if args else ''
        if not name:
            return ''

        if base_head in {'incvar', 'incglobalvar'}:
            new_value = self._numeric_add(storage.get(name, 0), 1)
        elif base_head in {'decvar', 'decglobalvar'}:
            new_value = self._numeric_add(storage.get(name, 0), -1)
        elif base_head in {'addvar', 'addglobalvar'}:
            operand = args[1] if len(args) > 1 else ''
            new_value = self._apply_add(storage.get(name, ''), operand)
        else:
            new_value = args[1] if len(args) > 1 else ''

        storage[name] = new_value
        if allow_side_effects:
            effects.append(MacroEffect(scope=scope, op=base_head, name=name, value=new_value))
        return self._stringify(new_value)

    def _truthy(self, value: Any) -> bool:
        text = str(value or '').strip().lower()
        return text not in {'', '0', 'false', 'none', 'null'}

    def _evaluate_condition(self, condition: str, context: MacroRuntimeContext) -> bool:
        raw = str(condition or '').strip()
        if not raw:
            return False
        if '!=' in raw:
            left, right = raw.split('!=', 1)
            return self._resolve_operand(left, context) != self._resolve_operand(right, context)
        if '==' in raw:
            left, right = raw.split('==', 1)
            return self._resolve_operand(left, context) == self._resolve_operand(right, context)
        if raw.startswith('!'):
            return not self._evaluate_condition(raw[1:], context)
        return self._truthy(self._resolve_operand(raw, context))

    def _resolve_operand(self, operand: str, context: MacroRuntimeContext) -> str:
        token = str(operand or '').strip()
        if not token:
            return ''
        lowered = token.lower()
        for key, value in context.values.items():
            if key.lower() == lowered:
                return str(value or '')
        if token in context.local_variables:
            return self._stringify(context.local_variables.get(token, ''))
        if token in context.global_variables:
            return self._stringify(context.global_variables.get(token, ''))
        return token

    def _numeric_add(self, current: Any, delta: int | float) -> Any:
        try:
            number = float(current)
            result = number + delta
            if float(result).is_integer():
                return int(result)
            return result
        except Exception:
            return delta

    def _apply_add(self, current: Any, operand: Any) -> Any:
        try:
            left = float(current)
            right = float(operand)
            total = left + right
            if float(total).is_integer():
                return int(total)
            return total
        except Exception:
            if isinstance(current, list):
                updated = list(current)
                updated.append(operand)
                return updated
            return f'{self._stringify(current)}{self._stringify(operand)}'

    def _stringify(self, value: Any) -> str:
        if value is None:
            return ''
        if isinstance(value, (dict, list)):
            return json.dumps(value, ensure_ascii=False)
        return str(value)


def build_macro_runtime_context(
    *,
    character: dict[str, Any],
    chat: dict[str, Any] | None,
    history: list[dict[str, Any]] | None,
    user_text: str,
    persona: dict[str, Any] | None,
    preset: dict[str, Any] | None = None,
    provider_id: str = '',
    model_name: str = '',
    local_variables: dict[str, Any] | None = None,
    global_variables: dict[str, Any] | None = None,
    original_text: str = '',
) -> MacroRuntimeContext:
    history = list(history or [])
    local_variables = dict(local_variables or {})
    global_variables = dict(global_variables or {})

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

    now = datetime.now()
    idle_duration = 0
    if history:
        last_item = history[-1]
        try:
            created_at = float(last_item.get('createdAt') or 0)
            if created_at > 0:
                idle_duration = max(0, int((datetime.now().timestamp() - created_at) // 60))
        except Exception:
            idle_duration = 0

    persona_name = str((persona or {}).get('name') or '').strip() or 'User'
    persona_description = str((persona or {}).get('description') or '').strip()
    character_name = str(character.get('name') or 'Character').strip() or 'Character'
    system_prompt = str(character.get('systemPrompt') or '').strip()
    post_history = str(character.get('postHistoryInstructions') or '').strip()
    values = {
        'user': persona_name,
        'persona': persona_name,
        'user_description': persona_description,
        'persona_description': persona_description,
        'char': character_name,
        'charname': character_name,
        'description': str(character.get('description') or '').strip(),
        'personality': str(character.get('personality') or '').strip(),
        'scenario': str(character.get('scenario') or '').strip(),
        'first_mes': str(character.get('firstMessage') or '').strip(),
        'greeting': str(character.get('firstMessage') or '').strip(),
        'mes_example': str(character.get('exampleDialogues') or '').strip(),
        'examples': str(character.get('exampleDialogues') or '').strip(),
        'system_prompt': system_prompt,
        'char_system_prompt': system_prompt,
        'system': system_prompt,
        'post_history_instructions': post_history,
        'postHistoryInstructions': post_history,
        'jailbreak': post_history,
        'creatorNotes': str(character.get('creatorNotes') or '').strip(),
        'lastMessage': last_message,
        'last_message': last_message,
        'lastUserMessage': last_user_message,
        'last_user_message': last_user_message,
        'lastCharMessage': last_char_message,
        'last_char_message': last_char_message,
        'messageCount': str(len(history)),
        'message_count': str(len(history)),
        'chatId': str((chat or {}).get('id') or '').strip(),
        'chat_id': str((chat or {}).get('id') or '').strip(),
        'input': str(user_text or '').strip(),
        'userInput': str(user_text or '').strip(),
        'original': str(original_text or '').strip(),
        'model': str(model_name or (preset or {}).get('model') or '').strip(),
        'provider': str(provider_id or (preset or {}).get('provider') or '').strip(),
        'idle_duration': str(idle_duration),
        'time': now.strftime('%H:%M'),
        'time_12h': now.strftime('%I:%M %p'),
        'date': now.strftime('%Y-%m-%d'),
        'date_local': now.strftime('%b %d, %Y'),
        'weekday': now.strftime('%A'),
        'day': str(now.day),
        'month': now.strftime('%B'),
        'year': str(now.year),
        'datetime': now.strftime('%Y-%m-%d %H:%M:%S'),
        'iso_date': now.isoformat(),
    }
    return MacroRuntimeContext(
        values=values,
        local_variables=local_variables,
        global_variables=global_variables,
    )
