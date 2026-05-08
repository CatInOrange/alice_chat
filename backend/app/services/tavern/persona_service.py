from __future__ import annotations

from typing import Any

from ...store.tavern import TavernStore


class TavernPersonaService:
    def __init__(self, store: TavernStore):
        self.store = store

    def resolve_for_chat(self, chat: dict[str, Any] | None) -> dict[str, Any]:
        chat = chat or {}
        persona_id = str(chat.get('personaId') or '').strip()
        persona = self.store.get_persona(persona_id) if persona_id else None
        if persona is not None:
            return persona
        persona = self.store.get_default_persona()
        if persona is not None:
            return persona
        return {
            'id': '',
            'name': 'User',
            'description': '',
            'metadata': {},
            'isDefault': False,
        }
