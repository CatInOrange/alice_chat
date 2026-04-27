from __future__ import annotations

from importlib import import_module

__all__ = ["ChatService", "EventsBus", "PushService", "TtsService"]


def __getattr__(name: str):
    if name == "ChatService":
        return import_module(".chat_service", __name__).ChatService
    if name == "EventsBus":
        return import_module(".events_bus", __name__).EventsBus
    if name == "PushService":
        return import_module(".push_service", __name__).PushService
    if name == "TtsService":
        return import_module(".tts_service", __name__).TtsService
    raise AttributeError(name)
