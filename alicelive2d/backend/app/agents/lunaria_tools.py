from __future__ import annotations

from typing import Protocol

from .base import ChatRequest


class LunariaTool(Protocol):
    def definition(self) -> dict:
        raise NotImplementedError

    def invoke(self, *, arguments: dict, request: ChatRequest) -> dict:
        raise NotImplementedError


def get_lunaria_tools(provider_config: dict) -> list[LunariaTool]:
    return []
