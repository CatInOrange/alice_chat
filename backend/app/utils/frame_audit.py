from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any

_AUDIT_ENABLED = os.getenv("ALICECHAT_FRAME_AUDIT", "1").strip().lower() not in {"", "0", "false", "no", "off"}
_AUDIT_DIR = Path(os.getenv("ALICECHAT_FRAME_AUDIT_DIR", "/root/.openclaw/AliceChat/data/frame-audit")).expanduser()
_LOCK = threading.Lock()


def is_frame_audit_enabled() -> bool:
    return _AUDIT_ENABLED


def _safe_jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): _safe_jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_safe_jsonable(v) for v in value]
    return repr(value)


def audit_frame(stream: str, direction: str, frame: Any, **meta: Any) -> None:
    if not _AUDIT_ENABLED:
        return

    try:
        _AUDIT_DIR.mkdir(parents=True, exist_ok=True)
        ts = time.time()
        day = time.strftime("%Y%m%d", time.localtime(ts))
        path = _AUDIT_DIR / f"{day}.jsonl"
        record = {
            "id": uuid.uuid4().hex,
            "ts": ts,
            "iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts)),
            "stream": stream,
            "direction": direction,
            "frameType": str((frame or {}).get("type") or meta.get("frameType") or "") if isinstance(frame, dict) else str(meta.get("frameType") or ""),
            "meta": _safe_jsonable(meta),
            "frame": _safe_jsonable(frame),
        }
        line = json.dumps(record, ensure_ascii=False)
        with _LOCK:
            with path.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
    except Exception as exc:
        print(f"[frame_audit] failed to write audit record: {exc}", flush=True)
