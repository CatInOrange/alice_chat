from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import load_config
from .services import ChatService, EventsBus, MusicService, PushService, RequestDeduper
from .store import MessageStore, MusicStore, PushDeviceStore, SessionStore


@dataclass(slots=True)
class AppContext:
    session_store: SessionStore
    message_store: MessageStore
    music_store: MusicStore
    events_bus: EventsBus
    chat_service: ChatService
    music_service: MusicService
    request_deduper: RequestDeduper
    push_device_store: PushDeviceStore
    push_service: PushService
    uploads_dir: Path
    config: dict


def create_app_context(*, uploads_dir: Path) -> AppContext:
    session_store = SessionStore()
    message_store = MessageStore()
    music_store = MusicStore()
    events_bus = EventsBus()
    chat_service = ChatService(sessions=session_store, messages=message_store)
    music_service = MusicService(store=music_store, config=load_config())
    request_deduper = RequestDeduper()
    push_device_store = PushDeviceStore()

    uploads_dir = uploads_dir.resolve()
    uploads_dir.mkdir(parents=True, exist_ok=True)

    return AppContext(
        session_store=session_store,
        message_store=message_store,
        music_store=music_store,
        events_bus=events_bus,
        chat_service=chat_service,
        music_service=music_service,
        request_deduper=request_deduper,
        push_device_store=push_device_store,
        push_service=PushService(push_device_store, load_config()),
        uploads_dir=uploads_dir,
        config=load_config(),
    )
