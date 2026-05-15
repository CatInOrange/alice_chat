from __future__ import annotations

import json
import re
from typing import Any


SUSPICIOUS_FINAL_KEYWORDS = (
    'apply patch failed',
    'command failed',
    'tool failed',
    'approval required',
    'exit code',
)

SUSPICIOUS_FINAL_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            r'^(?:[⚠️📝\s]+)?edit:\s+in\s+.+?\s+failed\s*$',
            re.IGNORECASE,
        ),
        'edit_failed',
    ),
)

RECOVERABLE_NOISE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r'^(?:analyzing|loading|thinking|working|processing)\b.*$', re.IGNORECASE),
    re.compile(r'^(?:done|ok|completed|finished)\.?$', re.IGNORECASE),
    re.compile(r'^(?:\/approve\b|openclaw\b|flutter\b|git\b|grep\b|sed\b).*$'),
)

MIN_RECOVERABLE_PREVIEW_LENGTH = 24


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
    for pattern, reason in SUSPICIOUS_FINAL_PATTERNS:
        if pattern.match(value):
            return reason
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


def is_recoverable_preview_candidate(text: str) -> bool:
    value = strip_model_prefix(str(text or '').strip())
    if not value:
        return False
    if not contains_chinese(value):
        return False
    if len(value) < MIN_RECOVERABLE_PREVIEW_LENGTH:
        return False
    lowered = value.lower()
    if any(keyword in lowered for keyword in SUSPICIOUS_FINAL_KEYWORDS):
        return False
    if any(pattern.match(value) for pattern, _reason in SUSPICIOUS_FINAL_PATTERNS):
        return False
    if any(pattern.match(value) for pattern in RECOVERABLE_NOISE_PATTERNS):
        return False
    return True


def select_preview_recovery_text(*, final_text: str, preview_text: str, fallback_preview_text: str = '') -> str:
    final_value = strip_model_prefix(str(final_text or '').strip())
    candidates = [
        strip_model_prefix(str(preview_text or '').strip()),
        strip_model_prefix(str(fallback_preview_text or '').strip()),
    ]
    for candidate in candidates:
        if not final_value or not candidate:
            continue
        if candidate == final_value:
            continue
        if not is_recoverable_preview_candidate(candidate):
            continue
        if len(candidate) <= len(final_value) + 12:
            continue
        return candidate
    return ''
