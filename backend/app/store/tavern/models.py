from __future__ import annotations

from dataclasses import dataclass


@dataclass(slots=True)
class TavernCharacterRecord:
    id: str
    name: str
    description: str
    personality: str
    scenario: str
    first_message: str
    example_dialogues: str
    avatar_path: str
    tags_json: str
    source_type: str
    source_name: str
    raw_json: str
    metadata_json: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernChatRecord:
    id: str
    character_id: str
    title: str
    preset_id: str
    persona_id: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernMessageRecord:
    id: str
    chat_id: str
    role: str
    content: str
    thought: str
    metadata_json: str
    created_at: float


@dataclass(slots=True)
class TavernPresetRecord:
    id: str
    name: str
    provider: str
    model: str
    temperature: float
    top_p: float
    top_k: int
    min_p: float
    typical_p: float
    repetition_penalty: float
    max_tokens: int
    stop_sequences_json: str
    prompt_order_id: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernPromptBlockRecord:
    id: str
    name: str
    enabled: int
    content: str
    kind: str
    injection_mode: str
    depth: int | None
    role_scope: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernPromptOrderRecord:
    id: str
    name: str
    items_json: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernWorldBookRecord:
    id: str
    name: str
    description: str
    enabled: int
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernWorldBookEntryRecord:
    id: str
    worldbook_id: str
    keys_json: str
    secondary_keys_json: str
    content: str
    enabled: int
    priority: int
    recursive: int
    constant: int
    insertion_position: str
    group_name: str
    created_at: float
    updated_at: float


@dataclass(slots=True)
class TavernCharacterLoreBindingRecord:
    id: str
    character_id: str
    worldbook_id: str
    enabled: int
    priority_override: int | None
    created_at: float
    updated_at: float
