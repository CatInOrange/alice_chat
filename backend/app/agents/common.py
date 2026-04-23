from __future__ import annotations

import json


def extract_text_from_message_content(content: object) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item.get("content"), str):
                    parts.append(item["content"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(part.strip() for part in parts if part and part.strip()).strip()
    return ""


def truncate_for_log(value: object, max_chars: int = 1200) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    text = str(text)
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "..."
