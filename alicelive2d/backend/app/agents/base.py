from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Callable

StreamEmitter = Callable[[dict], None]


@dataclass(slots=True)
class ChatAttachment:
    """Represents an image attachment in a chat message.

    Supports multiple sources:
    - url: HTTP/HTTPS URL to an image
    - base64: Base64-encoded image data
    - path: Local file path (server-side only)
    """

    type: str  # "url", "base64", "path"
    data: str  # URL, base64 string, or file path
    media_type: str | None = None  # e.g., "image/jpeg", "image/png"

    def to_openai_content(self) -> dict:
        """Convert to OpenAI Vision API content format."""
        if self.type == "url":
            return {"type": "image_url", "image_url": {"url": self.data}}
        elif self.type == "base64":
            media_type = self.media_type or "image/png"
            return {"type": "image_url", "image_url": {"url": f"data:{media_type};base64,{self.data}"}}
        else:
            raise ValueError(f"Unsupported attachment type for OpenAI: {self.type}")


@dataclass(slots=True)
class ChatRequest:
    user_text: str
    agent: str | None = None
    session_name: str | None = None
    model_config: dict | None = None
    attachments: list[ChatAttachment] = field(default_factory=list)
    prior_messages: list[dict] = field(default_factory=list)
    extra_system_prompts: list[str] = field(default_factory=list)
    context: dict = field(default_factory=dict)


class AgentBackend(ABC):
    def __init__(self, provider_config: dict):
        self.provider_config = provider_config

    @abstractmethod
    def send_chat(self, request: ChatRequest) -> dict:
        raise NotImplementedError

    @abstractmethod
    def stream_chat(self, request: ChatRequest, emit: StreamEmitter) -> dict:
        raise NotImplementedError
