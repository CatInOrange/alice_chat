from __future__ import annotations

import json
from typing import Any


SUSPICIOUS_FINAL_KEYWORDS = (
    'apply patch failed',
    'command failed',
    'tool failed',
    'approval required',
    'exit code',
)


def strip_model_prefix(text: str) -> str:
    value = str(text or '').lstrip()
    if not value.startswith('['):
        return str(text or '').strip()
    bracket_end = value.find(']')
    if bracket_end <= 1:
        return str(text or '').strip()
    return value[bracket_end + 1 :].lstrip()


def contains_chinese(text: str) -> bool:
    return any('\u4e00' <= ch <= '\u9fff' for ch in str(text or ''))


def detect_suspicious_final(text: str) -> str | None:
    value = strip_model_prefix(str(text or '').strip())
    if not value:
        return None
    lowered = value.lower()
    for keyword in SUSPICIOUS_FINAL_KEYWORDS:
        if keyword in lowered:
            return keyword
    return None


def parse_message_meta(meta_value: object) -> dict[str, Any]:
    if isinstance(meta_value, dict):
        return dict(meta_value)
    if not meta_value:
        return {}
    try:
        parsed = json.loads(str(meta_value))
    except Exception:
        return {}
    return dict(parsed) if isinstance(parsed, dict) else {}


def build_suspicious_meta(*, existing_meta: object, request_id: str, reason: str) -> str:
    meta = parse_message_meta(existing_meta)
    suspicious = dict(meta.get('suspiciousFinal') or {}) if isinstance(meta.get('suspiciousFinal'), dict) else {}
    suspicious.update({
        'flagged': True,
        'reason': reason,
        'requestId': request_id,
        'recoveryAttempted': False,
        'recoverySucceeded': False,
    })
    meta['suspiciousFinal'] = suspicious
    return json.dumps(meta, ensure_ascii=False)


def mark_recovery_meta(*, existing_meta: object, succeeded: bool, recovered_text: str = '') -> str:
    meta = parse_message_meta(existing_meta)
    suspicious = dict(meta.get('suspiciousFinal') or {}) if isinstance(meta.get('suspiciousFinal'), dict) else {}
    suspicious['recoveryAttempted'] = True
    suspicious['recoverySucceeded'] = succeeded
    if succeeded and recovered_text:
        suspicious['recoveredText'] = recovered_text
    meta['suspiciousFinal'] = suspicious
    return json.dumps(meta, ensure_ascii=False)


def select_preview_recovery_text(*, final_text: str, preview_text: str) -> str:
    final_value = strip_model_prefix(str(final_text or '').strip())
    preview_value = strip_model_prefix(str(preview_text or '').strip())
    if not final_value or not preview_value:
        return ''
    if preview_value == final_value:
        return ''
    if not contains_chinese(preview_value):
        return ''
    if len(preview_value) <= len(final_value) + 12:
        return ''
    lowered_preview = preview_value.lower()
    if any(keyword in lowered_preview for keyword in SUSPICIOUS_FINAL_KEYWORDS):
        return ''
    return preview_value
