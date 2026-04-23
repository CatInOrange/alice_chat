from __future__ import annotations

from dataclasses import dataclass

from ..config import load_config


@dataclass(slots=True)
class RoutingDecision:
    contact_id: str
    agent_id: str
    session_name: str
    session_key: str


def _sanitize_segment(value: str, *, fallback: str) -> str:
    raw = str(value or '').strip().lower()
    if not raw:
        return fallback
    chars = []
    for ch in raw:
        if ch.isalnum() or ch in {'-', '_', ':'}:
            chars.append(ch)
        else:
            chars.append('_')
    sanitized = ''.join(chars).strip('_')
    return sanitized or fallback


def resolve_routing(*, contact_id: str, user_id: str = 'local', session_id: str = '') -> RoutingDecision:
    config = load_config()
    routing = config.get('routing') or {}
    contacts = routing.get('contacts') or {}
    default_agent = _sanitize_segment(str(routing.get('defaultAgent') or 'main'), fallback='main')
    namespace = _sanitize_segment(str(routing.get('sessionNamespace') or 'alicechat'), fallback='alicechat')

    resolved_contact = _sanitize_segment(contact_id, fallback='assistant')
    resolved_user = _sanitize_segment(user_id, fallback='local')
    resolved_session_id = _sanitize_segment(session_id, fallback='default')
    resolved_agent = _sanitize_segment(str(contacts.get(resolved_contact) or default_agent), fallback=default_agent)

    session_name = f"{namespace}:user_{resolved_user}:contact_{resolved_contact}:session_{resolved_session_id}"
    session_key = f"agent:{resolved_agent}:{session_name}"

    return RoutingDecision(
        contact_id=resolved_contact,
        agent_id=resolved_agent,
        session_name=session_name,
        session_key=session_key,
    )
