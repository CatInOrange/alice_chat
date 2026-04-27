from __future__ import annotations

from fastapi import HTTPException

from ..config import get_cors_config
from ..store import SessionStore


def session_to_api(session: object) -> dict:
    return {
        "id": getattr(session, "id"),
        "name": getattr(session, "name"),
        "createdAt": float(getattr(session, "created_at")),
        "updatedAt": float(getattr(session, "updated_at")),
    }


def build_route_key(*, provider_id: str, session_key: str = "", agent: str = "", session_name: str = "") -> str:
    resolved_provider_id = str(provider_id or "").strip()
    resolved_session_key = str(session_key or "").strip()
    resolved_agent = str(agent or "").strip()
    resolved_session_name = str(session_name or "").strip()
    if resolved_session_key:
        return f"{resolved_provider_id}|{resolved_session_key}"
    return f"{resolved_provider_id}|agent:{resolved_agent}|session:{resolved_session_name}"


def build_push_route_key(frame: dict) -> str:
    provider_id = str(frame.get("providerId") or frame.get("provider") or "live2d-channel").strip()
    session_key = str(frame.get("sessionKey") or "").strip()
    agent = str(frame.get("agent") or "").strip()
    session_name = str(frame.get("session") or frame.get("conversationLabel") or "").strip()
    return build_route_key(provider_id=provider_id, session_key=session_key, agent=agent, session_name=session_name)


def build_session_label(frame: dict) -> str:
    session_name = str(frame.get("session") or frame.get("conversationLabel") or "").strip()
    agent = str(frame.get("agent") or "").strip()
    parts = [part for part in [session_name, agent] if part]
    return " / ".join(parts) if parts else "Push 会话"


def build_allowed_origins() -> tuple[list[str], str | None]:
    cors_config = get_cors_config()
    origins = [str(item).strip() for item in (cors_config.get("origins") or []) if str(item).strip()]
    origin_regex = str(cors_config.get("originRegex") or "").strip() or None
    if origins or origin_regex:
        return origins, origin_regex
    return (
        [
            "http://127.0.0.1:18080",
            "http://localhost:18080",
            "http://tauri.localhost",
            "https://tauri.localhost",
            "tauri://localhost",
            "file://",
            "null",
        ],
        r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
    )


def require_existing_session(session_store: SessionStore, session_id: str) -> str:
    resolved = str(session_id or "").strip()
    if not resolved:
        raise HTTPException(status_code=400, detail="missing session id")
    if not session_store.exists(resolved):
        raise HTTPException(status_code=404, detail="unknown session id")
    return resolved
