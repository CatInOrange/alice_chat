from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .services import ChatService, EventsBus, PushService, TtsService
from .store import MessageStore, SessionStore


@dataclass(slots=True)
class AppContext:
    session_store: SessionStore
    message_store: MessageStore
    events_bus: EventsBus
    chat_service: ChatService
    tts_service: TtsService
    push_service: PushService
    uploads_dir: Path


def create_app_context(*, uploads_dir: Path) -> AppContext:
    session_store = SessionStore()
    message_store = MessageStore()
    events_bus = EventsBus()
    chat_service = ChatService(sessions=session_store, messages=message_store)
    tts_service = TtsService()
    push_service = PushService(tts=tts_service)

    uploads_dir = uploads_dir.resolve()
    uploads_dir.mkdir(parents=True, exist_ok=True)

    return AppContext(
        session_store=session_store,
        message_store=message_store,
        events_bus=events_bus,
        chat_service=chat_service,
        tts_service=tts_service,
        push_service=push_service,
        uploads_dir=uploads_dir,
    )
