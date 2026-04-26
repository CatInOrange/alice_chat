from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import quote

from .config import ROOT


def build_protected_media_url(path: str) -> str:
    return f"/api/media/file?path={quote(path, safe='')}"


def is_local_absolute_path(path: str) -> bool:
    value = str(path or '').strip()
    if not value:
        return False
    if value.startswith('/'):
        return True
    return os.name == 'nt' and len(value) >= 3 and value[1] == ':' and value[2] in {'\\', '/'}


def normalize_attachment_url(url: str) -> str:
    value = str(url or '').strip()
    if not value:
        return value
    lower = value.lower()
    if lower.startswith(('http://', 'https://')):
        return value
    if value.startswith('/api/') or value.startswith('/uploads/'):
        return value
    if is_local_absolute_path(value):
        return build_protected_media_url(value)
    if value.startswith('media/') or value.startswith('./media/'):
        media_root = ROOT.parent / 'media'
        relative = value[2:] if value.startswith('./') else value
        return build_protected_media_url(str((media_root / relative.removeprefix('media/')).resolve()))
    return value


def normalize_attachment_payload(attachment: dict) -> dict:
    normalized = dict(attachment or {})
    meta = normalized.get('meta')
    normalized_meta = dict(meta) if isinstance(meta, dict) else {}
    raw_url = str(normalized.get('url') or normalized.get('data') or '').strip()
    normalized_url = normalize_attachment_url(raw_url)
    if raw_url and raw_url != normalized_url and 'rawUrl' not in normalized_meta:
        normalized_meta['rawUrl'] = raw_url
    if normalized_url:
        normalized['url'] = normalized_url
    normalized['meta'] = normalized_meta
    normalized.pop('data', None)
    return normalized
