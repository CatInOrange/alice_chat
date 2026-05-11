from __future__ import annotations

import base64
import binascii
import json
import time
import uuid
from typing import Any

from ..db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


class TavernStore:
    """Persistence entry point for Tavern resources."""

    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            try:
                columns = {
                    str(row[1])
                    for row in conn.execute("PRAGMA table_info(tavern_presets)").fetchall()
                }
                if 'context_length' not in columns:
                    conn.execute(
                        "ALTER TABLE tavern_presets ADD COLUMN context_length INTEGER NOT NULL DEFAULT 0"
                    )
                    conn.commit()
            except Exception:
                pass
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS tavern_characters (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    personality TEXT NOT NULL DEFAULT '',
                    scenario TEXT NOT NULL DEFAULT '',
                    first_message TEXT NOT NULL DEFAULT '',
                    example_dialogues TEXT NOT NULL DEFAULT '',
                    avatar_path TEXT NOT NULL DEFAULT '',
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    alternate_greetings_json TEXT NOT NULL DEFAULT '[]',
                    creator_notes TEXT NOT NULL DEFAULT '',
                    system_prompt TEXT NOT NULL DEFAULT '',
                    post_history_instructions TEXT NOT NULL DEFAULT '',
                    creator TEXT NOT NULL DEFAULT '',
                    character_version TEXT NOT NULL DEFAULT '',
                    extensions_json TEXT NOT NULL DEFAULT '{}',
                    source_type TEXT NOT NULL DEFAULT 'json',
                    source_name TEXT NOT NULL DEFAULT '',
                    raw_json TEXT NOT NULL DEFAULT '{}',
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_chats (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    preset_id TEXT NOT NULL DEFAULT '',
                    persona_id TEXT NOT NULL DEFAULT '',
                    author_note_enabled INTEGER NOT NULL DEFAULT 0,
                    author_note TEXT NOT NULL DEFAULT '',
                    author_note_depth INTEGER NOT NULL DEFAULT 4,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_messages (
                    id TEXT PRIMARY KEY,
                    chat_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    thought TEXT NOT NULL DEFAULT '',
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_tavern_messages_chat_created
                ON tavern_messages(chat_id, created_at);

                CREATE TABLE IF NOT EXISTS tavern_presets (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    provider TEXT NOT NULL DEFAULT '',
                    model TEXT NOT NULL DEFAULT '',
                    temperature REAL NOT NULL DEFAULT 1.0,
                    top_p REAL NOT NULL DEFAULT 1.0,
                    frequency_penalty REAL NOT NULL DEFAULT 0.0,
                    presence_penalty REAL NOT NULL DEFAULT 0.0,
                    top_k INTEGER NOT NULL DEFAULT 0,
                    top_a REAL NOT NULL DEFAULT 0.0,
                    min_p REAL NOT NULL DEFAULT 0.0,
                    typical_p REAL NOT NULL DEFAULT 1.0,
                    repetition_penalty REAL NOT NULL DEFAULT 1.0,
                    max_tokens INTEGER NOT NULL DEFAULT 0,
                    context_length INTEGER NOT NULL DEFAULT 0,
                    stop_sequences_json TEXT NOT NULL DEFAULT '[]',
                    prompt_order_id TEXT NOT NULL DEFAULT '',
                    story_string TEXT NOT NULL DEFAULT '',
                    chat_start TEXT NOT NULL DEFAULT '',
                    example_separator TEXT NOT NULL DEFAULT '',
                    story_string_position TEXT NOT NULL DEFAULT 'in_prompt',
                    story_string_depth INTEGER NOT NULL DEFAULT 1,
                    story_string_role TEXT NOT NULL DEFAULT 'system',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_prompt_blocks (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    content TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT 'custom',
                    injection_mode TEXT NOT NULL DEFAULT 'position',
                    depth INTEGER,
                    role_scope TEXT NOT NULL DEFAULT 'global',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );


                CREATE TABLE IF NOT EXISTS tavern_prompt_orders (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    items_json TEXT NOT NULL DEFAULT '[]',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_worldbooks (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    scope TEXT NOT NULL DEFAULT 'local',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_worldbook_entries (
                    id TEXT PRIMARY KEY,
                    worldbook_id TEXT NOT NULL,
                    keys_json TEXT NOT NULL DEFAULT '[]',
                    secondary_keys_json TEXT NOT NULL DEFAULT '[]',
                    content TEXT NOT NULL DEFAULT '',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    priority INTEGER NOT NULL DEFAULT 0,
                    recursive INTEGER NOT NULL DEFAULT 0,
                    constant INTEGER NOT NULL DEFAULT 0,
                    prevent_recursion INTEGER NOT NULL DEFAULT 0,
                    secondary_logic TEXT NOT NULL DEFAULT 'and_any',
                    scan_depth INTEGER NOT NULL DEFAULT 0,
                    case_sensitive INTEGER NOT NULL DEFAULT 0,
                    match_whole_words INTEGER NOT NULL DEFAULT 0,
                    match_character_description INTEGER NOT NULL DEFAULT 0,
                    match_character_personality INTEGER NOT NULL DEFAULT 0,
                    match_scenario INTEGER NOT NULL DEFAULT 0,
                    use_group_scoring INTEGER NOT NULL DEFAULT 0,
                    group_weight INTEGER NOT NULL DEFAULT 100,
                    group_override INTEGER NOT NULL DEFAULT 0,
                    delay_until_recursion INTEGER NOT NULL DEFAULT 0,
                    probability INTEGER NOT NULL DEFAULT 100,
                    ignore_budget INTEGER NOT NULL DEFAULT 0,
                    character_filter_names_json TEXT NOT NULL DEFAULT '[]',
                    character_filter_tags_json TEXT NOT NULL DEFAULT '[]',
                    character_filter_exclude INTEGER NOT NULL DEFAULT 0,
                    sticky INTEGER NOT NULL DEFAULT 0,
                    cooldown INTEGER NOT NULL DEFAULT 0,
                    delay INTEGER NOT NULL DEFAULT 0,
                    insertion_position TEXT NOT NULL DEFAULT 'before_chat_history',
                    group_name TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_tavern_worldbook_entries_book
                ON tavern_worldbook_entries(worldbook_id, updated_at DESC);

                CREATE TABLE IF NOT EXISTS tavern_character_lore_bindings (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    worldbook_id TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    priority_override INTEGER,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_personas (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    is_default INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS tavern_global_variables (
                    key TEXT PRIMARY KEY,
                    value_json TEXT NOT NULL DEFAULT '""',
                    updated_at REAL NOT NULL
                );
                """
            )
            self._ensure_column(conn, 'tavern_characters', 'alternate_greetings_json', "TEXT NOT NULL DEFAULT '[]'")
            self._ensure_column(conn, 'tavern_characters', 'creator_notes', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_characters', 'system_prompt', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_characters', 'post_history_instructions', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_characters', 'creator', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_characters', 'character_version', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_characters', 'extensions_json', "TEXT NOT NULL DEFAULT '{}' ")
            self._ensure_column(conn, 'tavern_chats', 'author_note_enabled', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_chats', 'author_note', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_chats', 'author_note_depth', "INTEGER NOT NULL DEFAULT 4")
            self._ensure_column(conn, 'tavern_chats', 'metadata_json', "TEXT NOT NULL DEFAULT '{}' ")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'prevent_recursion', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'secondary_logic', "TEXT NOT NULL DEFAULT 'and_any'")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'scan_depth', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'case_sensitive', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'match_whole_words', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'match_character_description', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'match_character_personality', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'match_scenario', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'use_group_scoring', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'group_weight', "INTEGER NOT NULL DEFAULT 100")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'group_override', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'delay_until_recursion', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'probability', "INTEGER NOT NULL DEFAULT 100")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'ignore_budget', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'character_filter_names_json', "TEXT NOT NULL DEFAULT '[]'")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'character_filter_tags_json', "TEXT NOT NULL DEFAULT '[]'")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'character_filter_exclude', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'sticky', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'cooldown', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbook_entries', 'delay', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_worldbooks', 'scope', "TEXT NOT NULL DEFAULT 'local'")
            self._ensure_column(conn, 'tavern_presets', 'story_string', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_presets', 'chat_start', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_presets', 'example_separator', "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, 'tavern_presets', 'story_string_position', "TEXT NOT NULL DEFAULT 'in_prompt'")
            self._ensure_column(conn, 'tavern_presets', 'story_string_depth', "INTEGER NOT NULL DEFAULT 1")
            self._ensure_column(conn, 'tavern_presets', 'story_string_role', "TEXT NOT NULL DEFAULT 'system'")
            self._ensure_column(conn, 'tavern_presets', 'frequency_penalty', "REAL NOT NULL DEFAULT 0.0")
            self._ensure_column(conn, 'tavern_presets', 'presence_penalty', "REAL NOT NULL DEFAULT 0.0")
            self._ensure_column(conn, 'tavern_presets', 'top_a', "REAL NOT NULL DEFAULT 0.0")
            self._ensure_column(conn, 'tavern_presets', 'thinking_enabled', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_presets', 'show_thinking', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_presets', 'thinking_budget', "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, 'tavern_presets', 'reasoning_effort', "TEXT NOT NULL DEFAULT ''")
            conn.commit()
        self._ensure_seed_data()

    def _ensure_column(self, conn, table: str, column: str, spec: str) -> None:
        existing = {
            str(row['name'])
            for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
        }
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {spec}")

    def _ensure_seed_data(self) -> None:
        with connect(self.db) as conn:
            row = conn.execute("SELECT COUNT(1) AS c FROM tavern_prompt_orders").fetchone()
            count = int(row['c']) if row is not None else 0
            if count != 0:
                return
            now = _now()
            order_id = 'tav_po_default'
            items = [
                {'identifier': 'main', 'enabled': True, 'order_index': 0, 'position': 'after_system'},
                {'identifier': 'personaDescription', 'enabled': True, 'order_index': 10, 'position': 'after_system'},
                {'identifier': 'charDescription', 'enabled': True, 'order_index': 20, 'position': 'before_character'},
                {'identifier': 'charPersonality', 'enabled': True, 'order_index': 30, 'position': 'before_character'},
                {'identifier': 'scenario', 'enabled': True, 'order_index': 40, 'position': 'after_character'},
                {'identifier': 'worldInfoBefore', 'enabled': True, 'order_index': 50, 'position': 'before_chat_history'},
                {'identifier': 'dialogueExamples', 'enabled': True, 'order_index': 60, 'position': 'before_example_messages'},
                {'identifier': 'summaries', 'enabled': True, 'order_index': 70, 'position': 'before_chat_history'},
                {'identifier': 'chatHistory', 'enabled': True, 'order_index': 80, 'position': 'before_last_user'},
                {'identifier': 'worldInfoAfter', 'enabled': True, 'order_index': 90, 'position': 'after_character'},
                {'identifier': 'postHistoryInstructions', 'enabled': True, 'order_index': 100, 'position': 'after_chat_history'},
            ]
            conn.execute(
                "INSERT INTO tavern_prompt_orders(id,name,items_json,created_at,updated_at) VALUES(?,?,?,?,?)",
                (order_id, '默认 Tavern Prompt Order', json.dumps(items, ensure_ascii=False), now, now),
            )
            conn.execute(
                """
                INSERT INTO tavern_presets(
                  id,name,provider,model,temperature,top_p,frequency_penalty,presence_penalty,top_k,top_a,min_p,typical_p,repetition_penalty,max_tokens,stop_sequences_json,prompt_order_id,story_string,chat_start,example_separator,story_string_position,story_string_depth,story_string_role,thinking_enabled,show_thinking,thinking_budget,reasoning_effort,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    'tav_preset_default', '默认 Tavern Preset', '', '', 1.0, 1.0, 0.0, 0.0, 0, 0.0, 0.0, 1.0, 1.0, 0,
                    json.dumps([], ensure_ascii=False), order_id,
                    "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{char}}'s personality: {{personality}}\n{{/if}}{{#if scenario}}Scenario: {{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}",
                    '***',
                    '***',
                    'in_prompt',
                    1,
                    'system',
                    0,
                    0,
                    0,
                    '',
                    now,
                    now,
                ),
            )
            conn.commit()

    # Character
    def import_character_json(self, *, filename: str, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        character_id = _new_id('tav_char')
        record = self._build_character_record(
            filename=filename,
            payload=payload,
            source_type='json',
            character_id=character_id,
            now=now,
        )

        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO tavern_characters(
                    id, name, description, personality, scenario,
                    first_message, example_dialogues, avatar_path, tags_json,
                    alternate_greetings_json, creator_notes, system_prompt, post_history_instructions,
                    creator, character_version, extensions_json,
                    source_type, source_name, raw_json, metadata_json,
                    created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    record['id'], record['name'], record['description'], record['personality'],
                    record['scenario'], record['firstMessage'], record['exampleDialogues'],
                    record['avatarPath'], json.dumps(record['tags'], ensure_ascii=False),
                    json.dumps(record['alternateGreetings'], ensure_ascii=False), record['creatorNotes'],
                    record['systemPrompt'], record['postHistoryInstructions'],
                    record['creator'], record['characterVersion'], json.dumps(record['extensions'], ensure_ascii=False),
                    record['sourceType'], record['sourceName'],
                    json.dumps(record['rawJson'], ensure_ascii=False),
                    json.dumps(record['metadata'], ensure_ascii=False), now, now,
                ),
            )
            self._import_embedded_character_book(
                conn,
                character_id=character_id,
                payload=payload,
                now=now,
            )
            conn.commit()
        return record

    def import_character_png(self, *, filename: str, png_bytes: bytes) -> dict[str, Any]:
        self.ensure_schema()
        payload = self.extract_character_card_from_png(png_bytes)
        now = _now()
        character_id = _new_id('tav_char')
        record = self._build_character_record(
            filename=filename,
            payload=payload,
            source_type='png',
            character_id=character_id,
            now=now,
        )

        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO tavern_characters(
                    id, name, description, personality, scenario,
                    first_message, example_dialogues, avatar_path, tags_json,
                    alternate_greetings_json, creator_notes, system_prompt, post_history_instructions,
                    creator, character_version, extensions_json,
                    source_type, source_name, raw_json, metadata_json,
                    created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    record['id'], record['name'], record['description'], record['personality'],
                    record['scenario'], record['firstMessage'], record['exampleDialogues'],
                    record['avatarPath'], json.dumps(record['tags'], ensure_ascii=False),
                    json.dumps(record['alternateGreetings'], ensure_ascii=False), record['creatorNotes'],
                    record['systemPrompt'], record['postHistoryInstructions'],
                    record['creator'], record['characterVersion'], json.dumps(record['extensions'], ensure_ascii=False),
                    record['sourceType'], record['sourceName'],
                    json.dumps(record['rawJson'], ensure_ascii=False),
                    json.dumps(record['metadata'], ensure_ascii=False), now, now,
                ),
            )
            self._import_embedded_character_book(
                conn,
                character_id=character_id,
                payload=payload,
                now=now,
            )
            conn.commit()
        return record

    def extract_character_card_from_png(self, png_bytes: bytes) -> dict[str, Any]:
        raw_text = self._extract_png_text_chunk(png_bytes, 'ccv3') or self._extract_png_text_chunk(png_bytes, 'chara')
        if not raw_text:
            raise ValueError('png metadata does not contain any character data')
        try:
            decoded = base64.b64decode(raw_text)
        except binascii.Error as exc:
            raise ValueError('png character metadata is not valid base64') from exc
        try:
            payload = json.loads(decoded.decode('utf-8'))
        except Exception as exc:
            raise ValueError('png character metadata is not valid json') from exc
        if not isinstance(payload, dict):
            raise ValueError('png character metadata must decode to a json object')
        return payload

    def list_characters(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_characters ORDER BY updated_at DESC").fetchall()
            return [self._row_to_character(row) for row in rows]

    def get_character(self, character_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_characters WHERE id=? LIMIT 1", (character_id,)).fetchone()
            return self._row_to_character(row) if row is not None else None

    def delete_character(self, character_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            existing = conn.execute(
                "SELECT id FROM tavern_characters WHERE id=? LIMIT 1",
                (character_id,),
            ).fetchone()
            if existing is None:
                return False
            chat_rows = conn.execute(
                "SELECT id FROM tavern_chats WHERE character_id=?",
                (character_id,),
            ).fetchall()
            chat_ids = [row['id'] for row in chat_rows]
            if chat_ids:
                placeholders = ','.join('?' for _ in chat_ids)
                conn.execute(
                    f"DELETE FROM tavern_messages WHERE chat_id IN ({placeholders})",
                    tuple(chat_ids),
                )
                conn.execute(
                    f"DELETE FROM tavern_chats WHERE id IN ({placeholders})",
                    tuple(chat_ids),
                )
            conn.execute(
                "DELETE FROM tavern_character_lore_bindings WHERE character_id=?",
                (character_id,),
            )
            conn.execute("DELETE FROM tavern_characters WHERE id=?", (character_id,))
            conn.commit()
        return True

    def update_character_import_fields(self, character_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        current = self.get_character(character_id)
        if current is None:
            return None
        updated_at = _now()
        with connect(self.db) as conn:
            conn.execute(
                """
                UPDATE tavern_characters
                SET avatar_path=?, metadata_json=?, updated_at=?
                WHERE id=?
                """,
                (
                    str(payload.get('avatarPath', current['avatarPath']) or '').strip(),
                    json.dumps(payload.get('metadata', current['metadata']) or {}, ensure_ascii=False),
                    updated_at,
                    character_id,
                ),
            )
            conn.commit()
        return self.get_character(character_id)

    # Worldbook
    def create_worldbook(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        scope = str(payload.get('scope') or 'local').strip().lower()
        if scope not in {'global', 'local'}:
            scope = 'local'
        record = {
            'id': _new_id('tav_wb'),
            'name': str(payload.get('name') or '').strip() or '未命名世界书',
            'description': str(payload.get('description') or '').strip(),
            'scope': scope,
            'enabled': bool(payload.get('enabled', True)),
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_worldbooks(id,name,description,scope,enabled,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                (record['id'], record['name'], record['description'], record['scope'], 1 if record['enabled'] else 0, now, now),
            )
            conn.commit()
        return record

    def list_worldbooks(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_worldbooks ORDER BY updated_at DESC").fetchall()
            return [self._row_to_worldbook(row) for row in rows]

    def get_worldbook(self, worldbook_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_worldbooks WHERE id=? LIMIT 1", (worldbook_id,)).fetchone()
            return self._row_to_worldbook(row) if row is not None else None

    def update_worldbook(self, worldbook_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        current = self.get_worldbook(worldbook_id)
        if current is None:
            return None
        updated = {
            'name': str(payload.get('name', current['name']) or '').strip() or current['name'],
            'description': str(payload.get('description', current['description']) or '').strip(),
            'scope': str(payload.get('scope', current.get('scope') or 'local') or 'local').strip().lower() or 'local',
            'enabled': bool(payload.get('enabled', current['enabled'])),
            'updatedAt': _now(),
        }
        if updated['scope'] not in {'global', 'local'}:
            updated['scope'] = 'local'
        with connect(self.db) as conn:
            conn.execute(
                "UPDATE tavern_worldbooks SET name=?, description=?, scope=?, enabled=?, updated_at=? WHERE id=?",
                (updated['name'], updated['description'], updated['scope'], 1 if updated['enabled'] else 0, updated['updatedAt'], worldbook_id),
            )
            conn.commit()
        return self.get_worldbook(worldbook_id)

    def delete_worldbook(self, worldbook_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            conn.execute("DELETE FROM tavern_worldbook_entries WHERE worldbook_id=?", (worldbook_id,))
            cursor = conn.execute("DELETE FROM tavern_worldbooks WHERE id=?", (worldbook_id,))
            conn.commit()
            return cursor.rowcount > 0

    def create_worldbook_entry(self, worldbook_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        record = {
            'id': _new_id('tav_wbe'),
            'worldbookId': worldbook_id,
            'keys': self._normalize_string_list(payload.get('keys')),
            'secondaryKeys': self._normalize_string_list(payload.get('secondaryKeys')),
            'content': str(payload.get('content') or '').strip(),
            'enabled': bool(payload.get('enabled', True)),
            'priority': int(payload.get('priority') or 0),
            'recursive': bool(payload.get('recursive', False)),
            'constant': bool(payload.get('constant', False)),
            'preventRecursion': bool(payload.get('preventRecursion', False)),
            'secondaryLogic': self._normalize_secondary_logic(payload.get('secondaryLogic')),
            'scanDepth': max(0, int(payload.get('scanDepth') or 0)),
            'caseSensitive': bool(payload.get('caseSensitive', False)),
            'matchWholeWords': bool(payload.get('matchWholeWords', False)),
            'matchCharacterDescription': bool(payload.get('matchCharacterDescription', False)),
            'matchCharacterPersonality': bool(payload.get('matchCharacterPersonality', False)),
            'matchScenario': bool(payload.get('matchScenario', False)),
            'useGroupScoring': bool(payload.get('useGroupScoring', False)),
            'groupWeight': max(1, int(payload.get('groupWeight') or 100)),
            'groupOverride': bool(payload.get('groupOverride', False)),
            'delayUntilRecursion': max(0, int(payload.get('delayUntilRecursion') or 0)),
            'probability': min(100, max(0, int(payload.get('probability') or 100))),
            'ignoreBudget': bool(payload.get('ignoreBudget', False)),
            'characterFilterNames': self._normalize_string_list(payload.get('characterFilterNames')),
            'characterFilterTags': self._normalize_string_list(payload.get('characterFilterTags')),
            'characterFilterExclude': bool(payload.get('characterFilterExclude', False)),
            'sticky': max(0, int(payload.get('sticky') or 0)),
            'cooldown': max(0, int(payload.get('cooldown') or 0)),
            'delay': max(0, int(payload.get('delay') or 0)),
            'insertionPosition': str(payload.get('insertionPosition') or 'before_chat_history').strip() or 'before_chat_history',
            'groupName': str(payload.get('groupName') or '').strip(),
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO tavern_worldbook_entries(
                  id,worldbook_id,keys_json,secondary_keys_json,content,enabled,
                  priority,recursive,constant,prevent_recursion,secondary_logic,scan_depth,
                  case_sensitive,match_whole_words,match_character_description,
                  match_character_personality,match_scenario,use_group_scoring,group_weight,group_override,
                  delay_until_recursion,probability,ignore_budget,character_filter_names_json,character_filter_tags_json,
                  character_filter_exclude,sticky,cooldown,delay,insertion_position,group_name,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    record['id'], worldbook_id, json.dumps(record['keys'], ensure_ascii=False),
                    json.dumps(record['secondaryKeys'], ensure_ascii=False), record['content'],
                    1 if record['enabled'] else 0, record['priority'], 1 if record['recursive'] else 0,
                    1 if record['constant'] else 0, 1 if record['preventRecursion'] else 0,
                    record['secondaryLogic'], record['scanDepth'], 1 if record['caseSensitive'] else 0,
                    1 if record['matchWholeWords'] else 0, 1 if record['matchCharacterDescription'] else 0,
                    1 if record['matchCharacterPersonality'] else 0, 1 if record['matchScenario'] else 0,
                    1 if record['useGroupScoring'] else 0, record['groupWeight'], 1 if record['groupOverride'] else 0,
                    record['delayUntilRecursion'], record['probability'], 1 if record['ignoreBudget'] else 0,
                    json.dumps(record['characterFilterNames'], ensure_ascii=False), json.dumps(record['characterFilterTags'], ensure_ascii=False),
                    1 if record['characterFilterExclude'] else 0, record['sticky'], record['cooldown'], record['delay'], record['insertionPosition'], record['groupName'], now, now,
                ),
            )
            conn.commit()
        return record

    def list_worldbook_entries(self, worldbook_id: str) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM tavern_worldbook_entries WHERE worldbook_id=? ORDER BY priority DESC, updated_at DESC",
                (worldbook_id,),
            ).fetchall()
            return [self._row_to_worldbook_entry(row) for row in rows]

    def update_worldbook_entry(self, entry_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_worldbook_entries WHERE id=? LIMIT 1", (entry_id,)).fetchone()
            if current is None:
                return None
            keys = self._normalize_string_list(payload.get('keys')) if 'keys' in payload else self._load_json(current['keys_json'], default=[])
            secondary = self._normalize_string_list(payload.get('secondaryKeys')) if 'secondaryKeys' in payload else self._load_json(current['secondary_keys_json'], default=[])
            updated_at = _now()
            conn.execute(
                """
                UPDATE tavern_worldbook_entries
                SET keys_json=?, secondary_keys_json=?, content=?, enabled=?, priority=?, recursive=?, constant=?, prevent_recursion=?, secondary_logic=?, scan_depth=?, case_sensitive=?, match_whole_words=?, match_character_description=?, match_character_personality=?, match_scenario=?, use_group_scoring=?, group_weight=?, group_override=?, delay_until_recursion=?, probability=?, ignore_budget=?, character_filter_names_json=?, character_filter_tags_json=?, character_filter_exclude=?, sticky=?, cooldown=?, delay=?, insertion_position=?, group_name=?, updated_at=?
                WHERE id=?
                """,
                (
                    json.dumps(keys, ensure_ascii=False),
                    json.dumps(secondary, ensure_ascii=False),
                    str(payload.get('content', current['content']) or '').strip(),
                    1 if bool(payload.get('enabled', bool(current['enabled']))) else 0,
                    int(payload.get('priority', current['priority']) or 0),
                    1 if bool(payload.get('recursive', bool(current['recursive']))) else 0,
                    1 if bool(payload.get('constant', bool(current['constant']))) else 0,
                    1 if bool(payload.get('preventRecursion', bool(current['prevent_recursion']))) else 0,
                    self._normalize_secondary_logic(payload.get('secondaryLogic', current['secondary_logic'])),
                    max(0, int(payload.get('scanDepth', current['scan_depth']) or 0)),
                    1 if bool(payload.get('caseSensitive', bool(current['case_sensitive']))) else 0,
                    1 if bool(payload.get('matchWholeWords', bool(current['match_whole_words']))) else 0,
                    1 if bool(payload.get('matchCharacterDescription', bool(current['match_character_description']))) else 0,
                    1 if bool(payload.get('matchCharacterPersonality', bool(current['match_character_personality']))) else 0,
                    1 if bool(payload.get('matchScenario', bool(current['match_scenario']))) else 0,
                    1 if bool(payload.get('useGroupScoring', bool(current['use_group_scoring']))) else 0,
                    max(1, int(payload.get('groupWeight', current['group_weight']) or 100)),
                    1 if bool(payload.get('groupOverride', bool(current['group_override']))) else 0,
                    max(0, int(payload.get('delayUntilRecursion', current['delay_until_recursion']) or 0)),
                    min(100, max(0, int(payload.get('probability', current['probability']) or 100))),
                    1 if bool(payload.get('ignoreBudget', bool(current['ignore_budget']))) else 0,
                    json.dumps(self._normalize_string_list(payload.get('characterFilterNames')) if 'characterFilterNames' in payload else self._load_json(current['character_filter_names_json'], default=[]), ensure_ascii=False),
                    json.dumps(self._normalize_string_list(payload.get('characterFilterTags')) if 'characterFilterTags' in payload else self._load_json(current['character_filter_tags_json'], default=[]), ensure_ascii=False),
                    1 if bool(payload.get('characterFilterExclude', bool(current['character_filter_exclude']))) else 0,
                    max(0, int(payload.get('sticky', current['sticky']) or 0)),
                    max(0, int(payload.get('cooldown', current['cooldown']) or 0)),
                    max(0, int(payload.get('delay', current['delay']) or 0)),
                    str(payload.get('insertionPosition', current['insertion_position']) or 'before_chat_history').strip() or 'before_chat_history',
                    str(payload.get('groupName', current['group_name']) or '').strip(),
                    updated_at,
                    entry_id,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM tavern_worldbook_entries WHERE id=? LIMIT 1", (entry_id,)).fetchone()
            return self._row_to_worldbook_entry(row) if row is not None else None

    # Prompt
    def create_prompt_block(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        record = {
            'id': _new_id('tav_pb'),
            'name': str(payload.get('name') or '').strip() or '未命名 Prompt Block',
            'enabled': bool(payload.get('enabled', True)),
            'content': str(payload.get('content') or '').strip(),
            'kind': str(payload.get('kind') or 'custom').strip() or 'custom',
            'injectionMode': str(payload.get('injectionMode') or 'position').strip() or 'position',
            'depth': int(payload['depth']) if payload.get('depth') is not None else None,
            'roleScope': str(payload.get('roleScope') or 'global').strip() or 'global',
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_prompt_blocks(id,name,enabled,content,kind,injection_mode,depth,role_scope,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    record['id'], record['name'], 1 if record['enabled'] else 0, record['content'],
                    record['kind'], record['injectionMode'], record['depth'], record['roleScope'], now, now,
                ),
            )
            conn.commit()
        return record

    def list_prompt_blocks(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_prompt_blocks ORDER BY updated_at DESC").fetchall()
            return [self._row_to_prompt_block(row) for row in rows]

    def update_prompt_block(self, block_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_prompt_blocks WHERE id=? LIMIT 1", (block_id,)).fetchone()
            if current is None:
                return None
            updated_at = _now()
            conn.execute(
                """
                UPDATE tavern_prompt_blocks
                SET name=?, enabled=?, content=?, kind=?, injection_mode=?, depth=?, role_scope=?, updated_at=?
                WHERE id=?
                """,
                (
                    str(payload.get('name', current['name']) or '').strip() or current['name'],
                    1 if bool(payload.get('enabled', bool(current['enabled']))) else 0,
                    str(payload.get('content', current['content']) or '').strip(),
                    str(payload.get('kind', current['kind']) or 'custom').strip() or 'custom',
                    str(payload.get('injectionMode', current['injection_mode']) or 'position').strip() or 'position',
                    int(payload['depth']) if payload.get('depth') is not None else current['depth'],
                    str(payload.get('roleScope', current['role_scope']) or 'global').strip() or 'global',
                    updated_at,
                    block_id,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM tavern_prompt_blocks WHERE id=? LIMIT 1", (block_id,)).fetchone()
            return self._row_to_prompt_block(row) if row is not None else None

    def delete_prompt_block(self, block_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT id, items_json FROM tavern_prompt_orders").fetchall()
            for row in rows:
                items = self._load_json(row['items_json'], default=[])
                filtered = [item for item in items if str((item or {}).get('blockId') or '').strip() != block_id]
                if len(filtered) != len(items):
                    conn.execute(
                        "UPDATE tavern_prompt_orders SET items_json=?, updated_at=? WHERE id=?",
                        (json.dumps(filtered, ensure_ascii=False), _now(), row['id']),
                    )
            cursor = conn.execute("DELETE FROM tavern_prompt_blocks WHERE id=?", (block_id,))
            conn.commit()
            return cursor.rowcount > 0

    def create_prompt_order(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        items = payload.get('items') if isinstance(payload.get('items'), list) else []
        record = {
            'id': _new_id('tav_po'),
            'name': str(payload.get('name') or '').strip() or '默认 Prompt Order',
            'items': items,
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_prompt_orders(id,name,items_json,created_at,updated_at) VALUES(?,?,?,?,?)",
                (record['id'], record['name'], json.dumps(items, ensure_ascii=False), now, now),
            )
            conn.commit()
        return record

    def list_prompt_orders(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_prompt_orders ORDER BY updated_at DESC").fetchall()
            return [self._row_to_prompt_order(row) for row in rows]

    def get_prompt_order(self, prompt_order_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_prompt_orders WHERE id=? LIMIT 1", (prompt_order_id,)).fetchone()
            return self._row_to_prompt_order(row) if row is not None else None

    def update_prompt_order(self, prompt_order_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        current = self.get_prompt_order(prompt_order_id)
        if current is None:
            return None
        items = payload.get('items') if isinstance(payload.get('items'), list) else current['items']
        updated_at = _now()
        with connect(self.db) as conn:
            conn.execute(
                "UPDATE tavern_prompt_orders SET name=?, items_json=?, updated_at=? WHERE id=?",
                (
                    str(payload.get('name', current['name']) or '').strip() or current['name'],
                    json.dumps(items, ensure_ascii=False),
                    updated_at,
                    prompt_order_id,
                ),
            )
            conn.commit()
        return self.get_prompt_order(prompt_order_id)

    # Preset
    def create_preset(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        record = {
            'id': _new_id('tav_preset'),
            'name': str(payload.get('name') or '').strip() or '默认 Preset',
            'provider': str(payload.get('provider') or '').strip(),
            'model': str(payload.get('model') or '').strip(),
            'temperature': float(payload.get('temperature') or 1.0),
            'topP': float(payload.get('topP') or 1.0),
            'frequencyPenalty': float(payload.get('frequencyPenalty') or 0.0),
            'presencePenalty': float(payload.get('presencePenalty') or 0.0),
            'topK': int(payload.get('topK') or 0),
            'topA': float(payload.get('topA') or 0.0),
            'minP': float(payload.get('minP') or 0.0),
            'typicalP': float(payload.get('typicalP') or 1.0),
            'repetitionPenalty': float(payload.get('repetitionPenalty') or 1.0),
            'maxTokens': int(payload.get('maxTokens') or 0),
            'contextLength': int(payload.get('contextLength') or 0),
            'stopSequences': self._normalize_string_list(payload.get('stopSequences')),
            'promptOrderId': str(payload.get('promptOrderId') or '').strip(),
            'storyString': str(payload.get('storyString') or '').strip(),
            'chatStart': str(payload.get('chatStart') or '').strip(),
            'exampleSeparator': str(payload.get('exampleSeparator') or '').strip(),
            'storyStringPosition': str(payload.get('storyStringPosition') or 'in_prompt').strip() or 'in_prompt',
            'storyStringDepth': int(payload.get('storyStringDepth') or 1),
            'storyStringRole': str(payload.get('storyStringRole') or 'system').strip() or 'system',
            'thinkingEnabled': payload.get('thinkingEnabled') is True,
            'showThinking': payload.get('showThinking') is True,
            'thinkingBudget': int(payload.get('thinkingBudget') or 0),
            'reasoningEffort': str(payload.get('reasoningEffort') or '').strip(),
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO tavern_presets(
                  id,name,provider,model,temperature,top_p,frequency_penalty,presence_penalty,top_k,top_a,min_p,typical_p,repetition_penalty,max_tokens,context_length,stop_sequences_json,prompt_order_id,story_string,chat_start,example_separator,story_string_position,story_string_depth,story_string_role,thinking_enabled,show_thinking,thinking_budget,reasoning_effort,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    record['id'], record['name'], record['provider'], record['model'], record['temperature'],
                    record['topP'], record['frequencyPenalty'], record['presencePenalty'], record['topK'], record['topA'], record['minP'], record['typicalP'], record['repetitionPenalty'],
                    record['maxTokens'], record['contextLength'], json.dumps(record['stopSequences'], ensure_ascii=False),
                    record['promptOrderId'], record['storyString'], record['chatStart'], record['exampleSeparator'],
                    record['storyStringPosition'], record['storyStringDepth'], record['storyStringRole'],
                    1 if record['thinkingEnabled'] else 0, 1 if record['showThinking'] else 0, record['thinkingBudget'], record['reasoningEffort'], now, now,
                ),
            )
            conn.commit()
        return record

    def list_presets(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_presets ORDER BY updated_at DESC").fetchall()
            return [self._row_to_preset(row) for row in rows]

    def update_preset(self, preset_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_presets WHERE id=? LIMIT 1", (preset_id,)).fetchone()
            if current is None:
                return None
            stops = self._normalize_string_list(payload.get('stopSequences')) if 'stopSequences' in payload else self._load_json(current['stop_sequences_json'], default=[])
            updated_at = _now()
            conn.execute(
                """
                UPDATE tavern_presets
                SET name=?, provider=?, model=?, temperature=?, top_p=?, frequency_penalty=?, presence_penalty=?, top_k=?, top_a=?, min_p=?, typical_p=?, repetition_penalty=?, max_tokens=?, context_length=?, stop_sequences_json=?, prompt_order_id=?, story_string=?, chat_start=?, example_separator=?, story_string_position=?, story_string_depth=?, story_string_role=?, thinking_enabled=?, show_thinking=?, thinking_budget=?, reasoning_effort=?, updated_at=?
                WHERE id=?
                """,
                (
                    str(payload.get('name', current['name']) or '').strip() or current['name'],
                    str(payload.get('provider', current['provider']) or '').strip(),
                    str(payload.get('model', current['model']) or '').strip(),
                    float(payload.get('temperature', current['temperature']) or 1.0),
                    float(payload.get('topP', current['top_p']) or 1.0),
                    float(payload.get('frequencyPenalty', current['frequency_penalty']) or 0.0),
                    float(payload.get('presencePenalty', current['presence_penalty']) or 0.0),
                    int(payload.get('topK', current['top_k']) or 0),
                    float(payload.get('topA', current['top_a']) or 0.0),
                    float(payload.get('minP', current['min_p']) or 0.0),
                    float(payload.get('typicalP', current['typical_p']) or 1.0),
                    float(payload.get('repetitionPenalty', current['repetition_penalty']) or 1.0),
                    int(payload.get('maxTokens', current['max_tokens']) or 0),
                    int(payload.get('contextLength', current['context_length']) or 0),
                    json.dumps(stops, ensure_ascii=False),
                    str(payload.get('promptOrderId', current['prompt_order_id']) or '').strip(),
                    str(payload.get('storyString', current['story_string']) or '').strip(),
                    str(payload.get('chatStart', current['chat_start']) or '').strip(),
                    str(payload.get('exampleSeparator', current['example_separator']) or '').strip(),
                    str(payload.get('storyStringPosition', current['story_string_position']) or 'in_prompt').strip() or 'in_prompt',
                    int(payload.get('storyStringDepth', current['story_string_depth']) or 1),
                    str(payload.get('storyStringRole', current['story_string_role']) or 'system').strip() or 'system',
                    1 if payload.get('thinkingEnabled', bool(current['thinking_enabled'])) else 0,
                    1 if payload.get('showThinking', bool(current['show_thinking'])) else 0,
                    int(payload.get('thinkingBudget', current['thinking_budget']) or 0),
                    str(payload.get('reasoningEffort', current['reasoning_effort']) or '').strip(),
                    updated_at,
                    preset_id,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM tavern_presets WHERE id=? LIMIT 1", (preset_id,)).fetchone()
            return self._row_to_preset(row) if row is not None else None

    # Chat
    def create_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        character_id = str(payload.get('characterId') or '').strip()
        title = str(payload.get('title') or '').strip()
        character = self.get_character(character_id) if character_id else None
        if not title and character_id:
            title = str((character or {}).get('name') or '').strip()
        record = {
            'id': _new_id('tav_chat'),
            'characterId': character_id,
            'title': title or '未命名会话',
            'presetId': str(payload.get('presetId') or '').strip(),
            'personaId': str(payload.get('personaId') or '').strip(),
            'authorNoteEnabled': bool(payload.get('authorNoteEnabled', False)),
            'authorNote': str(payload.get('authorNote') or '').strip(),
            'authorNoteDepth': int(payload.get('authorNoteDepth') or 4),
            'metadata': dict(payload.get('metadata') or {}) if isinstance(payload.get('metadata'), dict) else {},
            'createdAt': now,
            'updatedAt': now,
        }
        first_message = str(payload.get('seedFirstMessage') or '').strip()
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_chats(id,character_id,title,preset_id,persona_id,author_note_enabled,author_note,author_note_depth,metadata_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (
                    record['id'], record['characterId'], record['title'], record['presetId'],
                    record['personaId'], 1 if record['authorNoteEnabled'] else 0, record['authorNote'], record['authorNoteDepth'], json.dumps(record['metadata'], ensure_ascii=False), now, now,
                ),
            )
            if first_message:
                conn.execute(
                    "INSERT INTO tavern_messages(id,chat_id,role,content,thought,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)",
                    (
                        _new_id('tav_msg'),
                        record['id'],
                        'assistant',
                        first_message,
                        '',
                        json.dumps({'seeded': 'firstMessage'}, ensure_ascii=False),
                        now,
                    ),
                )
                conn.execute("UPDATE tavern_chats SET updated_at=? WHERE id=?", (now, record['id']))
            conn.commit()
        return record

    def list_chats(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_chats ORDER BY updated_at DESC").fetchall()
            return [self._row_to_chat(row) for row in rows]

    def get_chat(self, chat_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_chats WHERE id=? LIMIT 1", (chat_id,)).fetchone()
            return self._row_to_chat(row) if row is not None else None

    def delete_chat(self, chat_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            existing = conn.execute(
                "SELECT id FROM tavern_chats WHERE id=? LIMIT 1",
                (chat_id,),
            ).fetchone()
            if existing is None:
                return False
            conn.execute("DELETE FROM tavern_messages WHERE chat_id=?", (chat_id,))
            conn.execute("DELETE FROM tavern_chats WHERE id=?", (chat_id,))
            conn.commit()
        return True

    def update_chat(self, chat_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_chats WHERE id=? LIMIT 1", (chat_id,)).fetchone()
            if current is None:
                return None
            updated_at = _now()
            conn.execute(
                """
                UPDATE tavern_chats
                SET title=?, preset_id=?, persona_id=?, author_note_enabled=?, author_note=?, author_note_depth=?, metadata_json=?, updated_at=?
                WHERE id=?
                """,
                (
                    str(payload.get('title', current['title']) or '').strip() or current['title'],
                    str(payload.get('presetId', current['preset_id']) or '').strip(),
                    str(payload.get('personaId', current['persona_id']) or '').strip(),
                    1 if bool(payload.get('authorNoteEnabled', bool(current['author_note_enabled']))) else 0,
                    str(payload.get('authorNote', current['author_note']) or '').strip(),
                    int(payload.get('authorNoteDepth', current['author_note_depth']) or 4),
                    json.dumps((payload.get('metadata', self._load_json(current['metadata_json'], default={})) or {}), ensure_ascii=False),
                    updated_at,
                    chat_id,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM tavern_chats WHERE id=? LIMIT 1", (chat_id,)).fetchone()
            return self._row_to_chat(row) if row is not None else None

    def append_message(self, chat_id: str, *, role: str, content: str, thought: str = '', metadata: dict[str, Any] | None = None) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        record = {
            'id': _new_id('tav_msg'),
            'chatId': chat_id,
            'role': role,
            'content': content,
            'thought': thought,
            'metadata': metadata or {},
            'createdAt': now,
        }
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_messages(id,chat_id,role,content,thought,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)",
                (record['id'], chat_id, role, content, thought, json.dumps(record['metadata'], ensure_ascii=False), now),
            )
            conn.execute("UPDATE tavern_chats SET updated_at=? WHERE id=?", (now, chat_id))
            conn.commit()
        return record

    def list_chat_messages(self, chat_id: str) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT * FROM tavern_messages WHERE chat_id=? ORDER BY created_at ASC", (chat_id,)).fetchall()
            return [self._row_to_message(row) for row in rows]

    def list_character_lore_bindings(self, character_id: str) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM tavern_character_lore_bindings WHERE character_id=? AND enabled=1 ORDER BY updated_at DESC",
                (character_id,),
            ).fetchall()
            return [self._row_to_character_lore_binding(row) for row in rows]

    # Persona
    def create_persona(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        now = _now()
        record = {
            'id': _new_id('tav_persona'),
            'name': str(payload.get('name') or '').strip() or 'User',
            'description': str(payload.get('description') or '').strip(),
            'metadata': dict(payload.get('metadata') or {}) if isinstance(payload.get('metadata'), dict) else {},
            'isDefault': bool(payload.get('isDefault', False)),
            'createdAt': now,
            'updatedAt': now,
        }
        with connect(self.db) as conn:
            if record['isDefault']:
                conn.execute("UPDATE tavern_personas SET is_default=0 WHERE is_default=1")
            conn.execute(
                "INSERT INTO tavern_personas(id,name,description,metadata_json,is_default,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                (
                    record['id'],
                    record['name'],
                    record['description'],
                    json.dumps(record['metadata'], ensure_ascii=False),
                    1 if record['isDefault'] else 0,
                    now,
                    now,
                ),
            )
            conn.commit()
        return record

    def list_personas(self) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM tavern_personas ORDER BY is_default DESC, updated_at DESC"
            ).fetchall()
            return [self._row_to_persona(row) for row in rows]

    def get_persona(self, persona_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_personas WHERE id=? LIMIT 1", (persona_id,)).fetchone()
            return self._row_to_persona(row) if row is not None else None

    def get_default_persona(self) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT * FROM tavern_personas WHERE is_default=1 ORDER BY updated_at DESC LIMIT 1").fetchone()
            if row is None:
                row = conn.execute("SELECT * FROM tavern_personas ORDER BY updated_at DESC LIMIT 1").fetchone()
            return self._row_to_persona(row) if row is not None else None

    def update_persona(self, persona_id: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_personas WHERE id=? LIMIT 1", (persona_id,)).fetchone()
            if current is None:
                return None
            updated_at = _now()
            is_default = bool(payload.get('isDefault', bool(current['is_default'])))
            if is_default:
                conn.execute("UPDATE tavern_personas SET is_default=0 WHERE is_default=1 AND id<>?", (persona_id,))
            conn.execute(
                """
                UPDATE tavern_personas
                SET name=?, description=?, metadata_json=?, is_default=?, updated_at=?
                WHERE id=?
                """,
                (
                    str(payload.get('name', current['name']) or '').strip() or current['name'],
                    str(payload.get('description', current['description']) or '').strip(),
                    json.dumps((payload.get('metadata', self._load_json(current['metadata_json'], default={})) or {}), ensure_ascii=False),
                    1 if is_default else 0,
                    updated_at,
                    persona_id,
                ),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM tavern_personas WHERE id=? LIMIT 1", (persona_id,)).fetchone()
            return self._row_to_persona(row) if row is not None else None

    def delete_persona(self, persona_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            current = conn.execute("SELECT * FROM tavern_personas WHERE id=? LIMIT 1", (persona_id,)).fetchone()
            if current is None:
                return False
            conn.execute("DELETE FROM tavern_personas WHERE id=?", (persona_id,))
            conn.execute("UPDATE tavern_chats SET persona_id='' WHERE persona_id=?", (persona_id,))
            conn.commit()
        return True

    # Global variables
    def list_global_variables(self) -> dict[str, Any]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute("SELECT key, value_json FROM tavern_global_variables ORDER BY key ASC").fetchall()
            return {str(row['key']): self._load_json(str(row['value_json']), default='') for row in rows}

    def get_global_variable(self, key: str, default: Any = '') -> Any:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT value_json FROM tavern_global_variables WHERE key=? LIMIT 1", (key,)).fetchone()
            if row is None:
                return default
            return self._load_json(str(row['value_json']), default=default)

    def set_global_variable(self, key: str, value: Any) -> Any:
        self.ensure_schema()
        now = _now()
        with connect(self.db) as conn:
            conn.execute(
                "INSERT INTO tavern_global_variables(key,value_json,updated_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
                (key, json.dumps(value, ensure_ascii=False), now),
            )
            conn.commit()
        return value

    def delete_global_variable(self, key: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute("SELECT key FROM tavern_global_variables WHERE key=? LIMIT 1", (key,)).fetchone()
            if row is None:
                return False
            conn.execute("DELETE FROM tavern_global_variables WHERE key=?", (key,))
            conn.commit()
        return True

    # Row mapping
    def _row_to_character(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'description': row['description'],
            'personality': row['personality'],
            'scenario': row['scenario'],
            'firstMessage': row['first_message'],
            'exampleDialogues': row['example_dialogues'],
            'avatarPath': row['avatar_path'],
            'tags': self._load_json(row['tags_json'], default=[]),
            'alternateGreetings': self._load_json(row['alternate_greetings_json'], default=[]),
            'creatorNotes': row['creator_notes'],
            'systemPrompt': row['system_prompt'],
            'postHistoryInstructions': row['post_history_instructions'],
            'creator': row['creator'],
            'characterVersion': row['character_version'],
            'extensions': self._load_json(row['extensions_json'], default={}),
            'sourceType': row['source_type'],
            'sourceName': row['source_name'],
            'rawJson': self._load_json(row['raw_json'], default={}),
            'metadata': self._load_json(row['metadata_json'], default={}),
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_worldbook(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'description': row['description'],
            'scope': str(row['scope'] or 'local'),
            'enabled': bool(row['enabled']),
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_worldbook_entry(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'worldbookId': row['worldbook_id'],
            'keys': self._load_json(row['keys_json'], default=[]),
            'secondaryKeys': self._load_json(row['secondary_keys_json'], default=[]),
            'content': row['content'],
            'enabled': bool(row['enabled']),
            'priority': row['priority'],
            'recursive': bool(row['recursive']),
            'constant': bool(row['constant']),
            'preventRecursion': bool(row['prevent_recursion']),
            'secondaryLogic': str(row['secondary_logic'] or 'and_any'),
            'scanDepth': int(row['scan_depth'] or 0),
            'caseSensitive': bool(row['case_sensitive']),
            'matchWholeWords': bool(row['match_whole_words']),
            'matchCharacterDescription': bool(row['match_character_description']),
            'matchCharacterPersonality': bool(row['match_character_personality']),
            'matchScenario': bool(row['match_scenario']),
            'useGroupScoring': bool(row['use_group_scoring']),
            'groupWeight': int(row['group_weight'] or 100),
            'groupOverride': bool(row['group_override']),
            'delayUntilRecursion': int(row['delay_until_recursion'] or 0),
            'probability': int(row['probability'] or 100),
            'ignoreBudget': bool(row['ignore_budget']),
            'characterFilterNames': self._load_json(row['character_filter_names_json'], default=[]),
            'characterFilterTags': self._load_json(row['character_filter_tags_json'], default=[]),
            'characterFilterExclude': bool(row['character_filter_exclude']),
            'sticky': int(row['sticky'] or 0),
            'cooldown': int(row['cooldown'] or 0),
            'delay': int(row['delay'] or 0),
            'insertionPosition': row['insertion_position'],
            'groupName': row['group_name'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_prompt_block(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'enabled': bool(row['enabled']),
            'content': row['content'],
            'kind': row['kind'],
            'injectionMode': row['injection_mode'],
            'depth': row['depth'],
            'roleScope': row['role_scope'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_prompt_order(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'items': self._load_json(row['items_json'], default=[]),
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_preset(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'provider': row['provider'],
            'model': row['model'],
            'temperature': row['temperature'],
            'topP': row['top_p'],
            'frequencyPenalty': row['frequency_penalty'],
            'presencePenalty': row['presence_penalty'],
            'topK': row['top_k'],
            'topA': row['top_a'],
            'minP': row['min_p'],
            'typicalP': row['typical_p'],
            'repetitionPenalty': row['repetition_penalty'],
            'maxTokens': row['max_tokens'],
            'contextLength': row['context_length'],
            'stopSequences': self._load_json(row['stop_sequences_json'], default=[]),
            'promptOrderId': row['prompt_order_id'],
            'storyString': row['story_string'],
            'chatStart': row['chat_start'],
            'exampleSeparator': row['example_separator'],
            'storyStringPosition': row['story_string_position'],
            'storyStringDepth': row['story_string_depth'],
            'storyStringRole': row['story_string_role'],
            'thinkingEnabled': bool(row['thinking_enabled']),
            'showThinking': bool(row['show_thinking']),
            'thinkingBudget': row['thinking_budget'],
            'reasoningEffort': row['reasoning_effort'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_chat(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'characterId': row['character_id'],
            'title': row['title'],
            'presetId': row['preset_id'],
            'personaId': row['persona_id'],
            'authorNoteEnabled': bool(row['author_note_enabled']),
            'authorNote': row['author_note'],
            'authorNoteDepth': row['author_note_depth'],
            'metadata': self._load_json(row['metadata_json'], default={}),
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_persona(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'name': row['name'],
            'description': row['description'],
            'metadata': self._load_json(row['metadata_json'], default={}),
            'isDefault': bool(row['is_default']),
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _row_to_message(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'chatId': row['chat_id'],
            'role': row['role'],
            'content': row['content'],
            'thought': row['thought'],
            'metadata': self._load_json(row['metadata_json'], default={}),
            'createdAt': row['created_at'],
        }

    def _row_to_character_lore_binding(self, row: Any) -> dict[str, Any]:
        return {
            'id': row['id'],
            'characterId': row['character_id'],
            'worldbookId': row['worldbook_id'],
            'enabled': bool(row['enabled']),
            'priorityOverride': row['priority_override'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def _build_character_record(
        self,
        *,
        filename: str,
        payload: dict[str, Any],
        source_type: str,
        character_id: str,
        now: float,
    ) -> dict[str, Any]:
        data_layer = payload.get('data') if isinstance(payload.get('data'), dict) else None
        card_layer = data_layer if data_layer is not None else payload

        def _pick(source: dict[str, Any], *keys: str) -> str:
            for key in keys:
                value = source.get(key)
                if isinstance(value, str) and value.strip():
                    return value.strip()
            return ''

        def _pick_any(*keys: str) -> str:
            if data_layer is not None:
                value = _pick(data_layer, *keys)
                if value:
                    return value
            return _pick(payload, *keys)

        tags = self._normalize_string_list(card_layer.get('tags'))
        alternate_greetings = self._normalize_string_list(card_layer.get('alternate_greetings') or card_layer.get('alternateGreetings'))
        extensions = card_layer.get('extensions') if isinstance(card_layer.get('extensions'), dict) else {}
        metadata = dict(payload)
        if data_layer is not None:
            metadata['cardSpec'] = str(payload.get('spec') or '').strip()
            metadata['cardSpecVersion'] = str(payload.get('spec_version') or '').strip()
            metadata['cardData'] = dict(data_layer)

        return {
            'id': character_id,
            'name': _pick_any('name', 'char_name') or filename.rsplit('.', 1)[0] or character_id,
            'description': _pick_any('description', 'char_description', 'char_persona'),
            'personality': _pick_any('personality'),
            'scenario': _pick_any('scenario', 'world_scenario'),
            'firstMessage': _pick_any('first_mes', 'firstMessage', 'first_message', 'char_greeting'),
            'exampleDialogues': _pick_any('mes_example', 'example_dialogues', 'exampleMessages', 'example_dialogue'),
            'avatarPath': _pick_any('avatar', 'avatar_path'),
            'tags': tags,
            'alternateGreetings': alternate_greetings,
            'creatorNotes': _pick_any('creator_notes', 'creatorcomment'),
            'systemPrompt': _pick_any('system_prompt'),
            'postHistoryInstructions': _pick_any('post_history_instructions'),
            'creator': _pick_any('creator'),
            'characterVersion': _pick_any('character_version'),
            'extensions': extensions,
            'sourceType': source_type,
            'sourceName': filename,
            'rawJson': payload,
            'metadata': metadata,
            'createdAt': now,
            'updatedAt': now,
        }

    def _import_embedded_character_book(self, conn, *, character_id: str, payload: dict[str, Any], now: float) -> None:
        data_layer = payload.get('data') if isinstance(payload.get('data'), dict) else None
        card_layer = data_layer if data_layer is not None else payload
        raw_book = card_layer.get('character_book')
        if not isinstance(raw_book, dict):
            return

        entries = raw_book.get('entries')
        if not isinstance(entries, list) or not entries:
            return

        worldbook_id = _new_id('tav_wb')
        worldbook_name = str(raw_book.get('name') or card_layer.get('name') or 'Embedded Character Book').strip() or 'Embedded Character Book'
        worldbook_description = str(raw_book.get('description') or '').strip()
        conn.execute(
            "INSERT INTO tavern_worldbooks(id,name,description,scope,enabled,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
            (worldbook_id, worldbook_name, worldbook_description, 'local', 1, now, now),
        )

        for raw_entry in entries:
            if not isinstance(raw_entry, dict):
                continue
            entry_id = _new_id('tav_wbe')
            extensions = raw_entry.get('extensions') if isinstance(raw_entry.get('extensions'), dict) else {}
            conn.execute(
                """
                INSERT INTO tavern_worldbook_entries(
                  id,worldbook_id,keys_json,secondary_keys_json,content,enabled,
                  priority,recursive,constant,prevent_recursion,secondary_logic,scan_depth,
                  case_sensitive,match_whole_words,match_character_description,
                  match_character_personality,match_scenario,use_group_scoring,group_weight,group_override,
                  delay_until_recursion,probability,ignore_budget,character_filter_names_json,character_filter_tags_json,
                  character_filter_exclude,sticky,cooldown,delay,insertion_position,group_name,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    entry_id,
                    worldbook_id,
                    json.dumps(self._normalize_string_list(raw_entry.get('keys')), ensure_ascii=False),
                    json.dumps(self._normalize_string_list(raw_entry.get('secondary_keys') or raw_entry.get('secondaryKeys')), ensure_ascii=False),
                    str(raw_entry.get('content') or '').strip(),
                    1 if self._coerce_worldbook_entry_enabled(raw_entry) else 0,
                    self._coerce_int(raw_entry.get('priority'), default=10),
                    1 if self._coerce_bool(raw_entry.get('selective') or raw_entry.get('recursive_scanning') or raw_entry.get('recursive'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('constant'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('prevent_recursion') or raw_entry.get('preventRecursion'), default=False) else 0,
                    self._normalize_secondary_logic(raw_entry.get('selectiveLogic') or raw_entry.get('secondaryLogic') or extensions.get('selective_logic')),
                    max(0, self._coerce_int(extensions.get('scan_depth') if extensions else raw_entry.get('scanDepth'), default=0)),
                    1 if self._coerce_bool(raw_entry.get('caseSensitive') if 'caseSensitive' in raw_entry else extensions.get('case_sensitive'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('matchWholeWords') if 'matchWholeWords' in raw_entry else extensions.get('match_whole_words'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('matchCharacterDescription') if 'matchCharacterDescription' in raw_entry else extensions.get('match_character_description'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('matchCharacterPersonality') if 'matchCharacterPersonality' in raw_entry else extensions.get('match_character_personality'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('matchScenario') if 'matchScenario' in raw_entry else extensions.get('match_scenario'), default=False) else 0,
                    1 if self._coerce_bool(raw_entry.get('useGroupScoring') if 'useGroupScoring' in raw_entry else extensions.get('use_group_scoring'), default=False) else 0,
                    max(1, self._coerce_int(raw_entry.get('groupWeight') if 'groupWeight' in raw_entry else extensions.get('group_weight'), default=100)),
                    1 if self._coerce_bool(raw_entry.get('groupOverride') if 'groupOverride' in raw_entry else extensions.get('group_override'), default=False) else 0,
                    max(0, self._coerce_int(raw_entry.get('delayUntilRecursion') if 'delayUntilRecursion' in raw_entry else extensions.get('delay_until_recursion'), default=0)),
                    min(100, max(0, self._coerce_int(raw_entry.get('probability') if 'probability' in raw_entry else extensions.get('probability'), default=100))),
                    1 if self._coerce_bool(raw_entry.get('ignoreBudget') if 'ignoreBudget' in raw_entry else extensions.get('ignore_budget'), default=False) else 0,
                    json.dumps(self._normalize_string_list(raw_entry.get('characterFilterNames') if 'characterFilterNames' in raw_entry else (extensions.get('character_filter_names') if isinstance(extensions.get('character_filter_names'), list) else [])), ensure_ascii=False),
                    json.dumps(self._normalize_string_list(raw_entry.get('characterFilterTags') if 'characterFilterTags' in raw_entry else (extensions.get('character_filter_tags') if isinstance(extensions.get('character_filter_tags'), list) else [])), ensure_ascii=False),
                    1 if self._coerce_bool(raw_entry.get('characterFilterExclude') if 'characterFilterExclude' in raw_entry else extensions.get('character_filter_exclude'), default=False) else 0,
                    max(0, self._coerce_int(raw_entry.get('sticky'), default=0)),
                    max(0, self._coerce_int(raw_entry.get('cooldown'), default=0)),
                    max(0, self._coerce_int(raw_entry.get('delay'), default=0)),
                    self._map_card_entry_position(raw_entry),
                    str(raw_entry.get('comment') or raw_entry.get('name') or '').strip(),
                    now,
                    now,
                ),
            )

        conn.execute(
            "INSERT INTO tavern_character_lore_bindings(id,character_id,worldbook_id,enabled,priority_override,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
            (_new_id('tav_bind'), character_id, worldbook_id, 1, None, now, now),
        )

    def _extract_png_text_chunk(self, png_bytes: bytes, keyword: str) -> str | None:
        if len(png_bytes) < 8:
            return None
        offset = 8
        target = keyword.lower()
        while offset + 8 <= len(png_bytes):
            length = int.from_bytes(png_bytes[offset:offset + 4], 'big')
            offset += 4
            chunk_type = png_bytes[offset:offset + 4]
            offset += 4
            data_end = offset + length
            if data_end + 4 > len(png_bytes):
                return None
            chunk_data = png_bytes[offset:data_end]
            if chunk_type in (b'tEXt', b'iTXt'):
                parsed = self._parse_png_text_payload(chunk_type, chunk_data)
                if parsed and parsed[0].lower() == target:
                    return parsed[1]
            offset = data_end + 4
        return None

    def _parse_png_text_payload(self, chunk_type: bytes, chunk_data: bytes) -> tuple[str, str] | None:
        try:
            if chunk_type == b'tEXt':
                sep = chunk_data.find(b'\x00')
                if sep <= 0:
                    return None
                return chunk_data[:sep].decode('latin-1'), chunk_data[sep + 1:].decode('latin-1')
            if chunk_type == b'iTXt':
                sep = chunk_data.find(b'\x00')
                if sep <= 0:
                    return None
                keyword = chunk_data[:sep].decode('latin-1')
                pos = sep + 1
                if pos + 2 > len(chunk_data):
                    return None
                compression_flag = chunk_data[pos]
                pos += 2
                lang_end = chunk_data.find(b'\x00', pos)
                if lang_end < 0:
                    return None
                pos = lang_end + 1
                translated_end = chunk_data.find(b'\x00', pos)
                if translated_end < 0:
                    return None
                pos = translated_end + 1
                text_bytes = chunk_data[pos:]
                if compression_flag:
                    return None
                return keyword, text_bytes.decode('utf-8')
        except Exception:
            return None
        return None

    def _coerce_bool(self, value: Any, *, default: bool) -> bool:
        if isinstance(value, bool):
            return value
        if isinstance(value, int):
            return value != 0
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in {'1', 'true', 'yes', 'on'}:
                return True
            if lowered in {'0', 'false', 'no', 'off'}:
                return False
        return default

    def _coerce_int(self, value: Any, *, default: int) -> int:
        try:
            return int(value)
        except Exception:
            return default

    def _coerce_worldbook_entry_enabled(self, raw_entry: dict[str, Any]) -> bool:
        if 'enabled' in raw_entry:
            return self._coerce_bool(raw_entry.get('enabled'), default=True)
        if 'disable' in raw_entry:
            return not self._coerce_bool(raw_entry.get('disable'), default=False)
        return True

    def _map_card_entry_position(self, raw_entry: dict[str, Any]) -> str:
        position = self._coerce_int(raw_entry.get('position'), default=-1)
        insertion = str(raw_entry.get('insertionPosition') or '').strip()
        if insertion:
            return insertion
        mapping = {
            0: 'before_character',
            1: 'after_character',
            2: 'before_example_messages',
            3: 'before_chat_history',
            4: 'before_last_user',
        }
        return mapping.get(position, 'before_chat_history')

    def _normalize_secondary_logic(self, value: Any) -> str:
        normalized = str(value or '').strip().lower()
        aliases = {
            '0': 'and_any',
            '1': 'not_all',
            '2': 'not_any',
            '3': 'and_all',
            'any': 'and_any',
            'all': 'and_all',
            'and': 'and_any',
            'or': 'and_any',
            'not': 'not_any',
            'and_any': 'and_any',
            'and_all': 'and_all',
            'not_any': 'not_any',
            'not_all': 'not_all',
        }
        return aliases.get(normalized, 'and_any')

    def _load_json(self, raw: str, *, default: Any) -> Any:
        try:
            return json.loads(raw or '')
        except Exception:
            return default

    def _normalize_string_list(self, value: Any) -> list[str]:
        if isinstance(value, list):
            return [str(item).strip() for item in value if str(item).strip()]
        if isinstance(value, str):
            return [part.strip() for part in value.split(',') if part.strip()]
        return []
