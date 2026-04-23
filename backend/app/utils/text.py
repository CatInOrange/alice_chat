from __future__ import annotations

"""Text utilities shared by legacy and FastAPI backends."""

import re


_DIRECTIVE_PATTERN = re.compile(r"\[(?:expr|expression|motion|act|exp):[^\]]+\]", re.IGNORECASE)


def strip_stage_directives(text: str) -> str:
    """Remove inline stage directives like `[expr:Happy]` from chat text."""

    cleaned = _DIRECTIVE_PATTERN.sub("", text or "")
    return cleaned.strip()
