from __future__ import annotations

from pydantic import BaseModel


class CreateSessionBody(BaseModel):
    id: str | None = None
    name: str | None = None


class CreateSessionMessageBody(BaseModel):
    role: str | None = None
    text: str | None = None
    reply: str | None = None
    meta: str | None = None
    source: str | None = None
    attachments: list[dict] | None = None


class UploadMediaResponse(BaseModel):
    ok: bool
    attachment: dict
