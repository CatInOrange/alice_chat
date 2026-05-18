from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import load_config
from .services import ChatService, EventsBus, MusicService, PushService, RequestDeduper, TranscriptRecoveryService
from .services.tavern import TavernService, TavernStreamingService
from .store import MessageStore, MusicStore, PushDeviceStore, RecoveryStore, SessionStore, TodoStore
from .store.tavern import TavernStore


@dataclass(slots=True)
class AppContext:
    session_store: SessionStore
    message_store: MessageStore
    music_store: MusicStore
    recovery_store: RecoveryStore
    events_bus: EventsBus
    chat_service: ChatService
    recovery_service: TranscriptRecoveryService
    music_service: MusicService
    request_deduper: RequestDeduper
    push_device_store: PushDeviceStore
    todo_store: TodoStore
    push_service: PushService
    tavern_store: TavernStore
    tavern_service: TavernService
    tavern_streaming_service: TavernStreamingService
    uploads_dir: Path
    config: dict


def create_app_context(*, uploads_dir: Path) -> AppContext:
    session_store = SessionStore()
    message_store = MessageStore()
    music_store = MusicStore()
    recovery_store = RecoveryStore()
    events_bus = EventsBus()
    chat_service = ChatService(sessions=session_store, messages=message_store)
    recovery_service = TranscriptRecoveryService(
        sessions=session_store,
        messages=message_store,
        chat_service=chat_service,
        events_bus=events_bus,
        recoveries=recovery_store,
    )
    music_service = MusicService(store=music_store, config=load_config())
    request_deduper = RequestDeduper()
    push_device_store = PushDeviceStore()
    todo_store = TodoStore()
    tavern_store = TavernStore()
    tavern_service = TavernService(store=tavern_store, uploads_dir=uploads_dir)
    tavern_streaming_service = TavernStreamingService(tavern_service)

    uploads_dir = uploads_dir.resolve()
    uploads_dir.mkdir(parents=True, exist_ok=True)

    return AppContext(
        session_store=session_store,
        message_store=message_store,
        music_store=music_store,
        recovery_store=recovery_store,
        events_bus=events_bus,
        chat_service=chat_service,
        recovery_service=recovery_service,
        music_service=music_service,
        request_deduper=request_deduper,
        push_device_store=push_device_store,
        todo_store=todo_store,
        push_service=PushService(push_device_store, load_config()),
        tavern_store=tavern_store,
        tavern_service=tavern_service,
        tavern_streaming_service=tavern_streaming_service,
        uploads_dir=uploads_dir,
        config=load_config(),
    )
