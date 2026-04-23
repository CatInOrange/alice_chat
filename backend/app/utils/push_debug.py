from __future__ import annotations


def is_push_debug_enabled() -> bool:
    return False


def log_push_debug(*args, **kwargs) -> None:
    return None
