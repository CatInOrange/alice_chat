from __future__ import annotations

import json


def format_sse(event: dict, *, event_name: str | None = None, include_id: bool = True) -> str:
    name = event_name or event.get("type") or "message"
    if event_name and "payload" in event:
        payload = event.get("payload")
    else:
        payload = event
    data = json.dumps(payload, ensure_ascii=False)
    parts = []
    if include_id and event.get("seq"):
        parts.append(f"id: {event['seq']}")
    parts.append(f"event: {name}")
    parts.append(f"data: {data}")
    return "\n".join(parts) + "\n\n"
