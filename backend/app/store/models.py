from __future__ import annotations

"""Domain models for persistence.

We keep these models intentionally small and JSON-friendly because:
- Messages are sent to the frontend almost as-is.
- Attachments need to be compatible with the existing frontend schema.

Note: This is not a full DDD model layer; it is a pragmatic data contract layer.
"""

from dataclasses import dataclass


@dataclass(slots=True)
class Session:
    id: str
    name: str
    route_key: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class Message:
    id: str
    session_id: str
    role: str
    text: str
    attachments: list[dict]
    source: str
    meta: str
    created_at: float


@dataclass(slots=True)
class FileRecord:
    id: str
    kind: str
    filename: str
    mime_type: str
    url: str
    size: int
    created_at: float


@dataclass(slots=True)
class Event:
    seq: int
    type: str
    ts: float
    payload: dict
