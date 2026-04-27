from __future__ import annotations

from abc import ABC, abstractmethod


class TtsBackend(ABC):
    def __init__(self, config: dict):
        self.config = config

    @abstractmethod
    def synthesize(self, text: str, overrides: dict | None = None) -> tuple[bytes, str]:
        raise NotImplementedError
