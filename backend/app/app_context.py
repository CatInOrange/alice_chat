from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import load_config
from .services import ChatService, EventsBus, RequestDeduper
from .store import MessageStore, SessionStore


@dataclass(slots=True)
class AppContext:
    session_store: SessionStore
    message_store: MessageStore
    events_bus: EventsBus
    chat_service: ChatService
    request_deduper: RequestDeduper
    uploads_dir: Path
    config: dict


def create_app_context(*, uploads_dir: Path) -> AppContext:
    session_store = SessionStore()
    message_store = MessageStore()
    events_bus = EventsBus()
    chat_service = ChatService(sessions=session_store, messages=message_store)
    request_deduper = RequestDeduper()

    uploads_dir = uploads_dir.resolve()
    uploads_dir.mkdir(parents=True, exist_ok=True)

    return AppContext(
        session_store=session_store,
        message_store=message_store,
        events_bus=events_bus,
        chat_service=chat_service,
        request_deduper=request_deduper,
        uploads_dir=uploads_dir,
        config=load_config(),
    )
