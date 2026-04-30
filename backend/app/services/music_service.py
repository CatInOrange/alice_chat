from __future__ import annotations

from dataclasses import dataclass

from ..store import MusicStore


@dataclass(slots=True)
class MusicStateResult:
    payload: dict


class MusicService:
    def __init__(self, *, store: MusicStore | None = None):
        self.store = store or MusicStore()

    def load_state(self) -> MusicStateResult:
        return MusicStateResult(payload=self.store.load_state())

    def save_state(self, payload: dict) -> MusicStateResult:
        return MusicStateResult(payload=self.store.save_state(payload))
