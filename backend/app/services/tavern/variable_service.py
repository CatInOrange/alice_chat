from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from ...store.tavern import TavernStore


@dataclass(slots=True)
class VariableSnapshot:
    local: dict[str, Any]
    global_: dict[str, Any]


class TavernVariableService:
    def __init__(self, store: TavernStore):
        self.store = store

    def snapshot_for_chat(self, chat: dict[str, Any] | None) -> VariableSnapshot:
        chat = chat or {}
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        local_vars = metadata.get('variables') if isinstance(metadata.get('variables'), dict) else {}
        global_vars = self.store.list_global_variables()
        return VariableSnapshot(local=dict(local_vars), global_=dict(global_vars))

    def get_local_variables(self, chat_id: str) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return {}
        return self.snapshot_for_chat(chat).local

    def set_local_variables(self, chat_id: str, values: dict[str, Any]) -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ValueError('chat not found')
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        metadata['variables'] = dict(values or {})
        updated = self.store.update_chat(chat_id, {'metadata': metadata})
        return dict((updated or chat).get('metadata', {}).get('variables') or {})

    def get_global_variables(self) -> dict[str, Any]:
        return self.store.list_global_variables()

    def set_global_variables(self, values: dict[str, Any]) -> dict[str, Any]:
        existing = self.store.list_global_variables()
        incoming = dict(values or {})
        for key in list(existing.keys()):
            if key not in incoming:
                self.store.delete_global_variable(key)
        for key, value in incoming.items():
            self.store.set_global_variable(str(key), value)
        return self.store.list_global_variables()

    def apply_effects(self, *, chat_id: str, effects: list[Any], request_id: str = '') -> dict[str, Any]:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            return {'local': {}, 'global': {}, 'applied': False}
        metadata = dict(chat.get('metadata') or {}) if isinstance(chat.get('metadata'), dict) else {}
        macro_meta = metadata.get('macroRuntime') if isinstance(metadata.get('macroRuntime'), dict) else {}
        if request_id and str(macro_meta.get('lastAppliedRequestId') or '') == request_id:
            snapshot = self.snapshot_for_chat(chat)
            return {'local': snapshot.local, 'global': snapshot.global_, 'applied': False}

        snapshot = self.snapshot_for_chat(chat)
        local_vars = dict(snapshot.local)
        global_vars = dict(snapshot.global_)

        for effect in effects:
            if isinstance(effect, dict):
                scope = str(effect.get('scope') or '')
                name = str(effect.get('name') or '').strip()
                value = effect.get('value', '')
            else:
                scope = str(getattr(effect, 'scope', '') or '')
                name = str(getattr(effect, 'name', '') or '').strip()
                value = getattr(effect, 'value', '')
            if not name:
                continue
            if scope == 'global':
                global_vars[name] = value
            else:
                local_vars[name] = value

        metadata['variables'] = local_vars
        metadata['macroRuntime'] = {
            **macro_meta,
            'lastAppliedRequestId': request_id,
        }
        self.store.update_chat(chat_id, {'metadata': metadata})
        existing_global = self.store.list_global_variables()
        for key in list(existing_global.keys()):
            if key not in global_vars:
                self.store.delete_global_variable(key)
        for key, value in global_vars.items():
            self.store.set_global_variable(key, value)
        return {'local': local_vars, 'global': global_vars, 'applied': True}
