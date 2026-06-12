from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..services.chat_service import ChatService
from ..services.events_bus import EventsBus
from ..services.request_deduper import RequestDeduper
from ..store import MessageStore, RecoveryStore, SessionStore
from ..store.db import connect
from ..utils.suspicious_reply import (
    detect_suspicious_final,
    parse_message_meta,
)


_LOG = logging.getLogger(__name__)

_DEFAULT_AGENTS_ROOT = Path('/root/.openclaw/agents')
_RECOVERY_SOURCE = 'openclaw_transcript'
_DISPLAY_MODEL_PREFIX_RE = re.compile(
    r'^\s*\[(?:gpt-[^\]]+|o\d[^\]]*|\{model\})\]\s*',
    re.IGNORECASE,
)
_RECOVERY_MESSAGE_PREFIX_RE = re.compile(r'^\s*\[恢复消息\]\s*', re.IGNORECASE)


class TranscriptRecoveryService:
    def __init__(
        self,
        *,
        sessions: SessionStore,
        messages: MessageStore,
        chat_service: ChatService,
        events_bus: EventsBus,
        recoveries: RecoveryStore,
        request_deduper: RequestDeduper | None = None,
        agents_root: Path | None = None,
        recovery_timeout_seconds: float = 60.0,
        scan_interval_seconds: float = 30.0,
        scan_limit: int = 500,
    ) -> None:
        self.sessions = sessions
        self.messages = messages
        self.chat_service = chat_service
        self.events_bus = events_bus
        self.recoveries = recoveries
        self.request_deduper = request_deduper
        self.agents_root = (agents_root or _DEFAULT_AGENTS_ROOT).expanduser()
        self.recovery_timeout_seconds = max(15.0, float(recovery_timeout_seconds))
        self.scan_interval_seconds = max(10.0, float(scan_interval_seconds))
        self.scan_limit = max(50, int(scan_limit))

    def ensure_schema(self) -> None:
        self.recoveries.ensure_schema()

    async def run_loop(self) -> None:
        while True:
            try:
                await self.scan_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                _LOG.exception('[alicechat.recovery] scan_failed')
            await asyncio.sleep(self.scan_interval_seconds)

    async def scan_once(self) -> int:
        candidates = self._list_candidates()
        recovered = 0
        for candidate in candidates:
            if await self._recover_candidate(candidate):
                recovered += 1
        if recovered:
            _LOG.info('[alicechat.recovery] recovered_count=%s', recovered)
        return recovered

    async def recover_session_once(
        self,
        session_id: str,
        *,
        after_message_id: str = '',
        min_age_seconds: float = 15.0,
    ) -> bool:
        candidates = [
            item
            for item in self._list_candidates(min_age_seconds=min_age_seconds)
            if str(item.get('sessionId') or '').strip() == str(session_id or '').strip()
        ]
        if after_message_id:
            filtered: list[dict] = []
            for item in candidates:
                user_message = self.messages.find_message_by_client_message_id(
                    str(item.get('sessionId') or '').strip(),
                    str(item.get('clientMessageId') or '').strip(),
                )
                if user_message and str(user_message.get('id') or '').strip() == str(after_message_id).strip():
                    filtered.append(item)
            if filtered:
                candidates = filtered
        recovered = False
        for candidate in candidates:
            if await self._recover_candidate(candidate):
                recovered = True
        return recovered

    def sync_session_from_transcript(
        self,
        session_id: str,
        *,
        before_message_id: str = '',
        after_message_id: str = '',
        limit: int = 20,
        recent_user_limit: int = 3,
        reconcile_tail: bool = False,
        tail_limit: int = 5,
        allow_tail_delete: bool = False,
    ) -> dict[str, Any]:
        resolved_session_id = str(session_id or '').strip()
        page_limit = max(1, min(int(limit or 20), 100))
        actions: list[dict[str, Any]] = []
        if not resolved_session_id:
            return {'ok': False, 'changed': False, 'reason': 'missing_session_id', 'actions': actions}

        transcript_path, transcript_messages = self._resolve_session_transcript(resolved_session_id)
        if transcript_path is None:
            return {'ok': True, 'changed': False, 'reason': 'missing_transcript', 'actions': actions}
        if not transcript_messages:
            return {'ok': True, 'changed': False, 'reason': 'empty_transcript', 'actions': actions}

        imported_before = 0
        if str(before_message_id or '').strip():
            imported_before = self._backfill_session_before_from_transcript(
                session_id=resolved_session_id,
                before_message_id=str(before_message_id or '').strip(),
                limit=page_limit,
                transcript_path=transcript_path,
                transcript_messages=transcript_messages,
            )
            if imported_before:
                actions.append({'type': 'backfill_before', 'count': imported_before})

        imported_after = 0
        should_recover_gaps = bool(str(after_message_id or '').strip()) or bool(str(before_message_id or '').strip())
        if should_recover_gaps:
            imported_after = self._recover_missing_after_recent_users_from_transcript(
                session_id=resolved_session_id,
                limit=page_limit,
                user_limit=recent_user_limit,
                transcript_path=transcript_path,
                transcript_messages=transcript_messages,
            )
            if imported_after:
                actions.append({'type': 'recover_recent_user_gaps', 'count': imported_after})

        tail_result: dict[str, Any] | None = None
        if reconcile_tail:
            local_tail = self.messages.list_session_messages_page(
                resolved_session_id,
                limit=max(3, min(int(tail_limit or 5), 20)),
            )['messages']
            tail_result = self._reconcile_transcript_tail_window(
                session_id=resolved_session_id,
                transcript_path=transcript_path,
                transcript_messages=transcript_messages,
                local_tail=local_tail,
                limit=tail_limit,
                allow_delete=allow_tail_delete,
            )
            actions.extend(list(tail_result.get('actions') or []))

        changed = bool(imported_before or imported_after or (tail_result or {}).get('changed'))
        if changed:
            self.sessions.touch(resolved_session_id)
        reason = 'synced' if changed else ((tail_result or {}).get('reason') or 'nothing_to_sync')
        return {'ok': True, 'changed': changed, 'reason': str(reason), 'actions': actions}

    async def reconcile_session_tail(
        self,
        session_id: str,
        *,
        tail_limit: int = 5,
        min_age_seconds: float | None = None,
    ) -> dict[str, Any]:
        resolved_session_id = str(session_id or '').strip()
        if not resolved_session_id:
            return {'ok': False, 'changed': False, 'reason': 'missing_session_id', 'actions': []}

        page_limit = max(3, min(int(tail_limit or 5), 20))
        local_tail = self.messages.list_session_messages_page(
            resolved_session_id,
            limit=page_limit,
        )['messages']
        user_message = self._latest_user_in_messages(local_tail)
        if user_message is None:
            return {'ok': True, 'changed': False, 'reason': 'no_tail_user', 'actions': []}

        user_created_at = float(user_message.get('createdAt') or 0)
        age_seconds = (
            self.recovery_timeout_seconds
            if min_age_seconds is None
            else max(0.0, float(min_age_seconds))
        )
        if user_created_at > 0 and time.time() - user_created_at < age_seconds:
            return {'ok': True, 'changed': False, 'reason': 'latest_user_too_young', 'actions': []}

        client_message_id = self._client_message_id_for_user(user_message)
        if client_message_id and self.request_deduper is not None:
            record = await self.request_deduper.get(resolved_session_id, client_message_id)
            if record is not None and record.status == 'running':
                return {'ok': True, 'changed': False, 'reason': 'request_running', 'actions': []}

        session = self.sessions.get_session(resolved_session_id)
        session_key = self._extract_session_key(getattr(session, 'route_key', '') if session else '')
        if not session_key:
            return {'ok': True, 'changed': False, 'reason': 'missing_session_key', 'actions': []}
        transcript_path = self._resolve_transcript_path(session_key)
        if transcript_path is None:
            return {'ok': True, 'changed': False, 'reason': 'missing_transcript', 'actions': []}
        transcript_messages = self._load_transcript_messages(transcript_path)
        if not transcript_messages:
            return {'ok': True, 'changed': False, 'reason': 'empty_transcript', 'actions': []}

        tail_sync = self._reconcile_transcript_tail_window(
            session_id=resolved_session_id,
            transcript_path=transcript_path,
            transcript_messages=transcript_messages,
            local_tail=local_tail,
            limit=page_limit,
            allow_delete=False,
        )
        if tail_sync.get('changed'):
            self.sessions.touch(resolved_session_id)
            return tail_sync

        user_index = self._find_latest_user_index_in_transcript(
            transcript_messages,
            role='user',
            text=str(user_message.get('text') or ''),
            created_at=user_created_at,
        )
        if user_index < 0:
            return {'ok': True, 'changed': False, 'reason': 'user_not_matched', 'actions': []}

        recovered_body = self._build_recovery_body_from_transcript_messages(
            transcript_messages,
            anchor_index=user_index,
        )
        if not recovered_body:
            return {'ok': True, 'changed': False, 'reason': 'no_transcript_assistant_after_user', 'actions': []}

        existing_assistants = self._assistant_messages_after_user(
            resolved_session_id,
            user_created_at,
            limit=6,
        )
        equivalent = next(
            (
                item
                for item in existing_assistants
                if self._normalize_compare_text(str(item.get('text') or ''))
                == self._normalize_compare_text(recovered_body)
            ),
            None,
        )
        if equivalent is not None:
            deleted = self._soft_delete_duplicate_assistants(
                existing_assistants,
                keep_message_id=str(equivalent.get('id') or ''),
            )
            return {
                'ok': True,
                'changed': bool(deleted),
                'reason': 'assistant_already_present',
                'actions': deleted,
            }

        replace_target = next(
            (item for item in existing_assistants if self._is_reconcile_replaceable_assistant(item)),
            None,
        )
        actions: list[dict[str, Any]] = []
        recovery_key = self._build_tail_reconcile_key(
            session_id=resolved_session_id,
            user_message=user_message,
            transcript_item=transcript_messages[user_index + 1],
            recovered_body=recovered_body,
        )
        previous_recovery = self.recoveries.get(recovery_key)
        if previous_recovery and str(previous_recovery.get('status') or '') == 'recovered':
            return {'ok': True, 'changed': False, 'reason': 'already_recovered', 'actions': []}

        meta = {
            'recovered': True,
            'recoverySource': _RECOVERY_SOURCE,
            'recoveryMode': 'tail_reconcile',
            'recoveryKey': recovery_key,
            'recoveryUserMessageId': str(user_message.get('id') or ''),
            'transcriptPath': str(transcript_path),
        }

        if replace_target is not None:
            original_text = str(replace_target.get('text') or '')
            updated_meta = parse_message_meta(replace_target.get('meta'))
            updated_meta['transcriptRecovery'] = {
                **meta,
                'replacedMessageId': str(replace_target.get('id') or ''),
                'originalText': original_text,
            }
            updated = self.chat_service.update_message_content(
                message_id=str(replace_target.get('id') or ''),
                text=recovered_body,
                raw_text=recovered_body,
                meta=updated_meta,
            )
            if updated is None:
                return {'ok': True, 'changed': False, 'reason': 'replace_failed', 'actions': []}
            self.recoveries.mark(
                recovery_key=recovery_key,
                session_id=resolved_session_id,
                client_message_id=client_message_id,
                user_message_id=str(user_message.get('id') or ''),
                source=_RECOVERY_SOURCE,
                status='recovered',
                reason='tail_reconcile_replace',
                message_id=str(updated.get('id') or ''),
                meta=updated_meta,
            )
            actions.append({'type': 'replace_assistant', 'messageId': str(updated.get('id') or '')})
            actions.extend(
                self._soft_delete_duplicate_assistants(
                    existing_assistants,
                    keep_message_id=str(updated.get('id') or ''),
                )
            )
            self.sessions.touch(resolved_session_id)
            return {'ok': True, 'changed': True, 'reason': 'replaced_assistant', 'actions': actions}

        if existing_assistants:
            return {'ok': True, 'changed': False, 'reason': 'non_replaceable_assistant_exists', 'actions': []}

        created = self._first_assistant_created_at_after_user(
            transcript_messages,
            anchor_index=user_index,
        )
        if self._transcript_item_already_present(
            resolved_session_id,
            role='assistant',
            text=recovered_body,
            created_at=created or 0,
        ):
            return {'ok': True, 'changed': False, 'reason': 'assistant_already_present', 'actions': []}
        message_id = self._build_transcript_backfill_message_id(
            session_id=resolved_session_id,
            transcript_item=transcript_messages[user_index + 1],
        )
        if self.messages.get_message(message_id) is not None:
            return {'ok': True, 'changed': False, 'reason': 'message_id_already_exists', 'actions': []}
        persisted = self.messages.create_message(
            session_id=resolved_session_id,
            role='assistant',
            text=recovered_body,
            raw_text=recovered_body,
            attachments=[],
            source='transcript_reconcile',
            meta=json.dumps(meta, ensure_ascii=False),
            message_id=message_id,
            created_at=created or None,
        )
        self.recoveries.mark(
            recovery_key=recovery_key,
            session_id=resolved_session_id,
            client_message_id=client_message_id,
            user_message_id=str(user_message.get('id') or ''),
            source=_RECOVERY_SOURCE,
            status='recovered',
            reason='tail_reconcile_insert',
            message_id=str(persisted.get('id') or ''),
            meta=meta,
        )
        self.sessions.touch(resolved_session_id)
        return {
            'ok': True,
            'changed': True,
            'reason': 'inserted_assistant',
            'actions': [{'type': 'insert_assistant', 'messageId': str(persisted.get('id') or '')}],
        }

    def _reconcile_transcript_tail_window(
        self,
        *,
        session_id: str,
        transcript_path: Path,
        transcript_messages: list[dict[str, Any]],
        local_tail: list[dict],
        limit: int,
        allow_delete: bool = False,
    ) -> dict[str, Any]:
        window_limit = max(1, min(int(limit or 5), 20))
        transcript_tail = [
            item
            for item in transcript_messages
            if str(item.get('role') or '') in {'user', 'assistant'}
        ][-window_limit:]
        local_visible = self._build_local_visible_messages(local_tail)[-window_limit:]
        if not transcript_tail or not local_visible:
            return {'ok': True, 'changed': False, 'reason': 'tail_sync_empty_window', 'actions': []}

        local_keys = [self._compare_key(item) for item in local_visible]
        transcript_keys = [self._compare_key(item) for item in transcript_tail]
        if local_keys == transcript_keys:
            return {'ok': True, 'changed': False, 'reason': 'tail_already_synced', 'actions': []}

        local_key_set = set(local_keys)
        transcript_key_set = set(transcript_keys)
        if not local_key_set.intersection(transcript_key_set):
            return {'ok': True, 'changed': False, 'reason': 'tail_no_overlap', 'actions': []}

        actions: list[dict[str, Any]] = []
        matched_local_by_transcript_index = self._ordered_tail_matches(
            transcript_keys=transcript_keys,
            local_keys=local_keys,
        )
        consumed_local_indexes = set(matched_local_by_transcript_index.values())

        if allow_delete:
            for local_index, message in enumerate(local_visible):
                if local_index in consumed_local_indexes:
                    continue
                if str(message.get('role') or '') != 'assistant':
                    continue
                if not self._is_reconcile_replaceable_assistant(message):
                    continue
                if self._is_transcript_imported_assistant(message):
                    continue
                deleted = self.messages.soft_delete_message(
                    str(message.get('id') or ''),
                    deleted_by='tail_reconcile_extra',
                )
                if deleted is not None:
                    actions.append({
                        'type': 'delete_extra',
                        'messageId': str(message.get('id') or ''),
                        'role': str(message.get('role') or ''),
                    })

        for transcript_index, item in enumerate(transcript_tail):
            if transcript_index in matched_local_by_transcript_index:
                continue
            if str(item.get('role') or '') != 'assistant':
                continue
            if self._transcript_item_already_present(
                session_id,
                role='assistant',
                text=str(item.get('text') or ''),
                created_at=float(item.get('createdAt') or 0),
            ):
                continue
            message_id = self._build_transcript_backfill_message_id(
                session_id=session_id,
                transcript_item=item,
            )
            if self.messages.get_message(message_id) is not None:
                continue
            meta = {
                'transcriptBackfill': {
                    'source': _RECOVERY_SOURCE,
                    'mode': 'tail_window_sync',
                    'transcriptPath': str(transcript_path),
                    'transcriptRecordId': str(item.get('recordId') or ''),
                    'transcriptMessageId': str(item.get('transcriptMessageId') or ''),
                    'transcriptIndex': int(item.get('transcriptIndex') or 0),
                },
            }
            persisted = self.messages.create_message(
                session_id=session_id,
                role=str(item.get('role') or 'assistant'),
                text=str(item.get('text') or ''),
                raw_text=str(item.get('text') or ''),
                attachments=[],
                source='transcript_reconcile',
                meta=json.dumps(meta, ensure_ascii=False),
                message_id=message_id,
                created_at=float(item.get('createdAt') or 0) or None,
            )
            actions.append({
                'type': 'insert_missing',
                'messageId': str(persisted.get('id') or ''),
                'role': str(item.get('role') or ''),
            })

        return {
            'ok': True,
            'changed': bool(actions),
            'reason': 'tail_window_synced' if actions else 'tail_already_synced',
            'actions': actions,
        }

    def _ordered_tail_matches(
        self,
        *,
        transcript_keys: list[tuple[str, str]],
        local_keys: list[tuple[str, str]],
    ) -> dict[int, int]:
        if not transcript_keys or not local_keys:
            return {}
        rows = len(transcript_keys)
        cols = len(local_keys)
        dp = [[0] * (cols + 1) for _ in range(rows + 1)]
        for row in range(rows - 1, -1, -1):
            for col in range(cols - 1, -1, -1):
                if transcript_keys[row] == local_keys[col]:
                    dp[row][col] = 1 + dp[row + 1][col + 1]
                else:
                    dp[row][col] = max(dp[row + 1][col], dp[row][col + 1])

        matches: dict[int, int] = {}
        row = 0
        col = 0
        while row < rows and col < cols:
            if transcript_keys[row] == local_keys[col]:
                matches[row] = col
                row += 1
                col += 1
            elif dp[row][col + 1] >= dp[row + 1][col]:
                col += 1
            else:
                row += 1
        return matches

    def backfill_session_before(
        self,
        session_id: str,
        *,
        before_message_id: str = '',
        limit: int = 20,
    ) -> int:
        resolved_session_id = str(session_id or '').strip()
        anchor_message_id = str(before_message_id or '').strip()
        page_limit = max(1, min(int(limit or 20), 100))
        if not resolved_session_id or not anchor_message_id:
            return 0

        transcript_path, transcript_messages = self._resolve_session_transcript(resolved_session_id)
        if transcript_path is None:
            return 0
        if not transcript_messages:
            return 0

        return self._backfill_session_before_from_transcript(
            session_id=resolved_session_id,
            before_message_id=anchor_message_id,
            limit=page_limit,
            transcript_path=transcript_path,
            transcript_messages=transcript_messages,
        )

    def _backfill_session_before_from_transcript(
        self,
        *,
        session_id: str,
        before_message_id: str,
        limit: int,
        transcript_path: Path,
        transcript_messages: list[dict[str, Any]],
    ) -> int:
        page_limit = max(1, min(int(limit or 20), 100))
        local_messages = self.messages.list_session_messages(session_id, limit=5000)
        local_visible = self._build_local_visible_messages(local_messages)
        if not local_visible:
            return 0
        anchor_index = next(
            (index for index, item in enumerate(local_visible) if item['id'] == before_message_id),
            -1,
        )
        if anchor_index < 0:
            return 0

        local_window = local_visible[anchor_index : anchor_index + 12]
        overlap_start, overlap_run = self._find_overlap_start(
            transcript_messages,
            local_window,
        )
        if overlap_start < 0:
            return 0

        min_required_run = 1 if len(local_window) <= 1 else min(3, len(local_window))
        if overlap_run < min_required_run:
            return 0

        import_candidates = transcript_messages[max(0, overlap_start - page_limit) : overlap_start]
        if not import_candidates:
            return 0

        imported = 0
        for item in import_candidates:
            if self._transcript_item_already_present(
                session_id,
                role=str(item.get('role') or ''),
                text=str(item.get('text') or ''),
                created_at=float(item.get('createdAt') or 0),
            ):
                continue
            message_id = self._build_transcript_backfill_message_id(
                session_id=session_id,
                transcript_item=item,
            )
            if self.messages.get_message(message_id) is not None:
                continue
            meta = {
                'transcriptBackfill': {
                    'source': _RECOVERY_SOURCE,
                    'transcriptPath': str(transcript_path),
                    'transcriptRecordId': str(item.get('recordId') or ''),
                    'transcriptMessageId': str(item.get('transcriptMessageId') or ''),
                    'transcriptIndex': int(item.get('transcriptIndex') or 0),
                },
            }
            self.messages.create_message(
                session_id=session_id,
                role=str(item.get('role') or 'assistant'),
                text=str(item.get('text') or ''),
                raw_text=str(item.get('text') or ''),
                attachments=[],
                source='transcript_backfill',
                meta=json.dumps(meta, ensure_ascii=False),
                message_id=message_id,
                created_at=float(item.get('createdAt') or 0) or None,
            )
            imported += 1

        if imported > 0:
            self.sessions.touch(session_id)
        return imported

    def recover_missing_after_recent_users(
        self,
        session_id: str,
        *,
        limit: int = 20,
        user_limit: int = 3,
    ) -> int:
        resolved_session_id = str(session_id or '').strip()
        page_limit = max(1, min(int(limit or 20), 100))
        recent_user_limit = max(1, min(int(user_limit or 3), 10))
        if not resolved_session_id:
            return 0

        transcript_path, transcript_messages = self._resolve_session_transcript(resolved_session_id)
        if transcript_path is None:
            return 0
        if not transcript_messages:
            return 0

        return self._recover_missing_after_recent_users_from_transcript(
            session_id=resolved_session_id,
            limit=page_limit,
            user_limit=recent_user_limit,
            transcript_path=transcript_path,
            transcript_messages=transcript_messages,
        )

    def _recover_missing_after_recent_users_from_transcript(
        self,
        *,
        session_id: str,
        limit: int,
        user_limit: int,
        transcript_path: Path,
        transcript_messages: list[dict[str, Any]],
    ) -> int:
        page_limit = max(1, min(int(limit or 20), 100))
        recent_user_limit = max(1, min(int(user_limit or 3), 10))
        local_messages = self.messages.list_session_messages(session_id, limit=5000)
        local_users = [
            item
            for item in local_messages
            if str(item.get('role') or '').strip() == 'user'
            and str(item.get('text') or '').strip()
        ][-recent_user_limit:]
        if not local_users:
            return 0

        imported = 0
        for index, user_message in enumerate(local_users):
            remaining = page_limit - imported
            if remaining <= 0:
                break
            next_user = local_users[index + 1] if index + 1 < len(local_users) else None
            user_index = self._find_latest_user_index_in_transcript(
                transcript_messages,
                role='user',
                text=str(user_message.get('text') or ''),
                created_at=float(user_message.get('createdAt') or 0),
            )
            if user_index < 0:
                continue
            imported += self._recover_assistant_gap_after_user(
                session_id=session_id,
                user_message=user_message,
                next_user_message=next_user,
                transcript_path=transcript_path,
                transcript_messages=transcript_messages,
                user_index=user_index,
                limit=remaining,
            )

        if imported > 0:
            self.sessions.touch(session_id)
        return imported

    def _recover_assistant_gap_after_user(
        self,
        *,
        session_id: str,
        user_message: dict,
        next_user_message: dict | None,
        transcript_path: Path,
        transcript_messages: list[dict[str, Any]],
        user_index: int,
        limit: int,
    ) -> int:
        if user_index < 0:
            return 0
        assistant_items = self._assistant_items_after_transcript_user(
            transcript_messages,
            anchor_index=user_index,
        )
        if not assistant_items:
            return 0

        user_created_at = float(user_message.get('createdAt') or 0)
        next_user_created_at = float((next_user_message or {}).get('createdAt') or 0)
        local_assistants = self._assistant_messages_between_users(
            session_id,
            after_created_at=user_created_at,
            before_created_at=next_user_created_at if next_user_created_at > 0 else None,
            limit=20,
        )
        transcript_texts = {
            self._normalize_compare_text(str(item.get('text') or ''))
            for item in assistant_items
        }
        blocking_assistants = [
            item
            for item in local_assistants
            if not self._is_reconcile_replaceable_assistant(item)
            and self._normalize_compare_text(str(item.get('text') or '')) not in transcript_texts
        ]
        if blocking_assistants:
            return 0

        replace_target = next(
            (item for item in local_assistants if self._is_reconcile_replaceable_assistant(item)),
            None,
        )
        if replace_target is not None:
            recovered_body = self._body_from_transcript_assistant_items(assistant_items)
            if not recovered_body:
                return 0
            if self._normalize_compare_text(str(replace_target.get('text') or '')) == self._normalize_compare_text(recovered_body):
                return 0
            meta = parse_message_meta(replace_target.get('meta'))
            meta['transcriptRecovery'] = {
                'source': _RECOVERY_SOURCE,
                'mode': 'recent_user_gap_replace',
                'transcriptPath': str(transcript_path),
                'recoveryUserMessageId': str(user_message.get('id') or ''),
                'beforeUserMessageId': str((next_user_message or {}).get('id') or ''),
                'replacedMessageId': str(replace_target.get('id') or ''),
                'originalText': str(replace_target.get('text') or ''),
            }
            updated = self.chat_service.update_message_content(
                message_id=str(replace_target.get('id') or ''),
                text=recovered_body,
                raw_text=recovered_body,
                meta=meta,
            )
            return 1 if updated is not None else 0

        imported = 0
        for item in assistant_items:
            if imported >= max(1, int(limit or 1)):
                break
            if self._transcript_item_already_present(
                session_id,
                role='assistant',
                text=str(item.get('text') or ''),
                created_at=float(item.get('createdAt') or 0),
            ):
                continue
            message_id = self._build_transcript_backfill_message_id(
                session_id=session_id,
                transcript_item=item,
            )
            if self.messages.get_message(message_id) is not None:
                continue
            meta = {
                'transcriptBackfill': {
                    'source': _RECOVERY_SOURCE,
                    'mode': 'recent_user_gap',
                    'transcriptPath': str(transcript_path),
                    'transcriptRecordId': str(item.get('recordId') or ''),
                    'transcriptMessageId': str(item.get('transcriptMessageId') or ''),
                    'transcriptIndex': int(item.get('transcriptIndex') or 0),
                    'recoveryUserMessageId': str(user_message.get('id') or ''),
                    'beforeUserMessageId': str((next_user_message or {}).get('id') or ''),
                },
            }
            self.messages.create_message(
                session_id=session_id,
                role='assistant',
                text=str(item.get('text') or ''),
                raw_text=str(item.get('text') or ''),
                attachments=[],
                source='transcript_backfill',
                meta=json.dumps(meta, ensure_ascii=False),
                message_id=message_id,
                created_at=float(item.get('createdAt') or 0) or None,
            )
            imported += 1
        return imported

    def _assistant_items_after_transcript_user(
        self,
        transcript_messages: list[dict[str, Any]],
        *,
        anchor_index: int,
    ) -> list[dict[str, Any]]:
        if anchor_index < 0 or anchor_index >= len(transcript_messages):
            return []
        items: list[dict[str, Any]] = []
        seen: set[str] = set()
        for item in transcript_messages[anchor_index + 1 :]:
            role = str(item.get('role') or '')
            if role == 'user':
                break
            if role != 'assistant':
                continue
            content_text = str(item.get('text') or '').strip()
            if not content_text:
                continue
            normalized = self._normalize_compare_text(content_text)
            if normalized in seen:
                continue
            seen.add(normalized)
            items.append(item)
        return items

    def _body_from_transcript_assistant_items(self, items: list[dict[str, Any]]) -> str:
        body = '\n\n'.join(
            str(item.get('text') or '').strip()
            for item in items
            if str(item.get('text') or '').strip()
        ).strip()
        if len(body) > 12000:
            body = body[:12000].rstrip() + '\n\n[恢复内容已截断]'
        return body

    def recover_missing_after_latest_user(
        self,
        session_id: str,
        *,
        limit: int = 20,
    ) -> int:
        resolved_session_id = str(session_id or '').strip()
        page_limit = max(1, min(int(limit or 20), 100))
        if not resolved_session_id:
            return 0

        latest_user_message = self.messages.get_latest_session_message_by_role(
            resolved_session_id,
            'user',
        )
        if latest_user_message is None:
            return 0

        session = self.sessions.get_session(resolved_session_id)
        session_key = self._extract_session_key(getattr(session, 'route_key', '') if session else '')
        if not session_key:
            return 0
        transcript_path = self._resolve_transcript_path(session_key)
        if transcript_path is None:
            return 0

        transcript_messages = self._load_transcript_messages(transcript_path)
        if not transcript_messages:
            return 0

        user_index = self._find_latest_user_index_in_transcript(
            transcript_messages,
            role='user',
            text=str(latest_user_message.get('text') or ''),
            created_at=float(latest_user_message.get('createdAt') or 0),
        )

        replaced_existing = self._replace_suspicious_assistant_after_user(
            session_id=resolved_session_id,
            user_message=latest_user_message,
            transcript_path=transcript_path,
            transcript_messages=transcript_messages,
            user_index=user_index,
        )
        if replaced_existing:
            self.sessions.touch(resolved_session_id)
            return 1

        if user_index < 0:
            return 0

        imported = 0
        for item in transcript_messages[user_index + 1 :]:
            if str(item.get('role') or '') == 'user':
                break
            if str(item.get('role') or '') != 'assistant':
                continue
            if self._transcript_item_already_present(
                resolved_session_id,
                role='assistant',
                text=str(item.get('text') or ''),
                created_at=float(item.get('createdAt') or 0),
            ):
                continue
            message_id = self._build_transcript_backfill_message_id(
                session_id=resolved_session_id,
                transcript_item=item,
            )
            if self.messages.get_message(message_id) is not None:
                continue
            meta = {
                'transcriptBackfill': {
                    'source': _RECOVERY_SOURCE,
                    'transcriptPath': str(transcript_path),
                    'transcriptRecordId': str(item.get('recordId') or ''),
                    'transcriptMessageId': str(item.get('transcriptMessageId') or ''),
                    'transcriptIndex': int(item.get('transcriptIndex') or 0),
                    'recoveredAfterLatestUser': True,
                },
            }
            self.messages.create_message(
                session_id=resolved_session_id,
                role='assistant',
                text=str(item.get('text') or ''),
                raw_text=str(item.get('text') or ''),
                attachments=[],
                source='transcript_backfill',
                meta=json.dumps(meta, ensure_ascii=False),
                message_id=message_id,
                created_at=float(item.get('createdAt') or 0) or None,
            )
            imported += 1
            if imported >= page_limit:
                break

        if imported > 0:
            self.sessions.touch(resolved_session_id)
        return imported

    def _replace_suspicious_assistant_after_user(
        self,
        *,
        session_id: str,
        user_message: dict,
        transcript_path: Path,
        transcript_messages: list[dict[str, Any]],
        user_index: int,
    ) -> bool:
        user_created_at = float(user_message.get('createdAt') or 0)
        if user_created_at <= 0:
            return False
        existing = self.messages.get_first_assistant_after(session_id, user_created_at)
        if existing is None:
            return False
        suspicious_reason = self._detect_existing_suspicious_reason(existing)
        if not suspicious_reason:
            return False
        if user_index < 0:
            return False
        recovered_body = self._build_recovery_body_from_transcript_messages(
            transcript_messages,
            anchor_index=user_index,
        )
        if not recovered_body:
            return False
        existing_text = str(existing.get('text') or '').strip()
        if self._normalize_compare_text(existing_text) == self._normalize_compare_text(recovered_body):
            return False

        meta = parse_message_meta(existing.get('meta'))
        suspicious_meta = dict(meta.get('suspiciousFinal') or {}) if isinstance(meta.get('suspiciousFinal'), dict) else {}
        suspicious_meta.update({
            'flagged': True,
            'reason': suspicious_meta.get('reason') or suspicious_reason,
            'recoveryAttempted': True,
            'recoverySucceeded': True,
            'recoveredText': recovered_body,
        })
        meta['suspiciousFinal'] = suspicious_meta
        meta['transcriptRecovery'] = {
            'source': _RECOVERY_SOURCE,
            'transcriptPath': str(transcript_path),
            'replacedSuspiciousAssistant': True,
            'originalText': existing_text,
            'userMessageId': str(user_message.get('id') or ''),
        }
        updated = self.chat_service.update_message_content(
            message_id=str(existing.get('id') or ''),
            text=recovered_body,
            raw_text=recovered_body,
            meta=meta,
        )
        if updated is None:
            return False
        _LOG.warning(
            '[alicechat.recovery] replaced_suspicious_assistant sessionId=%s userMessageId=%s assistantMessageId=%s reason=%s transcript=%s',
            session_id,
            str(user_message.get('id') or ''),
            str(existing.get('id') or ''),
            suspicious_reason,
            transcript_path,
        )
        return True

    def _build_recovery_body_from_transcript_messages(
        self,
        transcript_messages: list[dict[str, Any]],
        *,
        anchor_index: int,
    ) -> str:
        return self._body_from_transcript_assistant_items(
            self._assistant_items_after_transcript_user(
                transcript_messages,
                anchor_index=anchor_index,
            )
        )

    def _latest_user_in_messages(self, messages: list[dict]) -> dict | None:
        for item in reversed(messages or []):
            if str(item.get('role') or '').strip() == 'user':
                return item
        return None

    def _client_message_id_for_user(self, user_message: dict) -> str:
        meta = parse_message_meta(user_message.get('meta'))
        return str(meta.get('clientMessageId') or '').strip()

    def _is_transcript_imported_assistant(self, message: dict) -> bool:
        if str(message.get('role') or '').strip() != 'assistant':
            return False
        source = str(message.get('source') or '').strip()
        if source in {'transcript_backfill', 'transcript_reconcile'}:
            return True
        meta = parse_message_meta(message.get('meta'))
        return isinstance(meta.get('transcriptBackfill'), dict) or isinstance(meta.get('transcriptRecovery'), dict)

    def _assistant_messages_after_user(
        self,
        session_id: str,
        user_created_at: float,
        *,
        limit: int = 6,
    ) -> list[dict]:
        return self._assistant_messages_between_users(
            session_id,
            after_created_at=user_created_at,
            before_created_at=None,
            limit=limit,
        )

    def _assistant_messages_between_users(
        self,
        session_id: str,
        *,
        after_created_at: float,
        before_created_at: float | None = None,
        limit: int = 6,
    ) -> list[dict]:
        if after_created_at <= 0:
            return []
        self.messages.ensure_schema()
        with connect(self.messages.db) as conn:
            before_clause = ''
            params: list[object] = [str(session_id), float(after_created_at)]
            if before_created_at is not None and float(before_created_at) > 0:
                before_clause = 'AND created_at < ?'
                params.append(float(before_created_at))
            params.append(int(max(1, limit)))
            rows = conn.execute(
                f"""
                SELECT *
                FROM messages
                WHERE session_id=?
                  AND deleted_at IS NULL
                  AND role='assistant'
                  AND created_at > ?
                  {before_clause}
                ORDER BY created_at ASC, id ASC
                LIMIT ?
                """,
                tuple(params),
            ).fetchall()
            return [self.messages._row_to_message(row) for row in rows]

    def _is_reconcile_replaceable_assistant(self, message: dict) -> bool:
        text = str(message.get('text') or '').strip()
        source = str(message.get('source') or '').strip()
        meta = parse_message_meta(message.get('meta'))
        if source in {'recovery', 'transcript_backfill', 'transcript_reconcile'}:
            return True
        if text.startswith('[恢复消息]'):
            return True
        if text.startswith('❌ 回复失败') or text.startswith('回复失败'):
            return True
        if self._detect_existing_suspicious_reason(message):
            return True
        transcript_recovery = meta.get('transcriptRecovery')
        if isinstance(transcript_recovery, dict) and transcript_recovery.get('recoverySucceeded') is False:
            return True
        suspicious = meta.get('suspiciousFinal')
        return isinstance(suspicious, dict) and bool(suspicious.get('flagged'))

    def _soft_delete_duplicate_assistants(
        self,
        candidates: list[dict],
        *,
        keep_message_id: str,
    ) -> list[dict[str, Any]]:
        keep_id = str(keep_message_id or '').strip()
        actions: list[dict[str, Any]] = []
        if not keep_id:
            return actions
        seen_texts: set[str] = set()
        keep_message = next((item for item in candidates if str(item.get('id') or '') == keep_id), None)
        if keep_message is not None:
            seen_texts.add(self._normalize_compare_text(str(keep_message.get('text') or '')))
        for item in candidates:
            message_id = str(item.get('id') or '').strip()
            if not message_id or message_id == keep_id:
                continue
            normalized = self._normalize_compare_text(str(item.get('text') or ''))
            duplicate_text = normalized and normalized in seen_texts
            replaceable = self._is_reconcile_replaceable_assistant(item)
            if not duplicate_text and not replaceable:
                continue
            deleted = self.messages.soft_delete_message(
                message_id,
                deleted_by='tail_reconcile_duplicate',
            )
            if deleted is not None:
                actions.append({'type': 'delete_duplicate', 'messageId': message_id})
            if normalized:
                seen_texts.add(normalized)
        return actions

    def _build_tail_reconcile_key(
        self,
        *,
        session_id: str,
        user_message: dict,
        transcript_item: dict[str, Any],
        recovered_body: str,
    ) -> str:
        raw = '|'.join(
            [
                'tail_reconcile',
                str(session_id or '').strip(),
                str(user_message.get('id') or '').strip(),
                str(transcript_item.get('recordId') or '').strip(),
                str(transcript_item.get('transcriptMessageId') or '').strip(),
                str(transcript_item.get('transcriptIndex') or ''),
                self._normalize_compare_text(recovered_body),
            ]
        )
        return hashlib.sha1(raw.encode('utf-8')).hexdigest()

    def _first_assistant_created_at_after_user(
        self,
        transcript_messages: list[dict[str, Any]],
        *,
        anchor_index: int,
    ) -> float:
        if anchor_index < 0:
            return 0.0
        for item in transcript_messages[anchor_index + 1 :]:
            role = str(item.get('role') or '')
            if role == 'user':
                return 0.0
            if role == 'assistant':
                return float(item.get('createdAt') or 0)
        return 0.0

    def _list_candidates(self, *, min_age_seconds: float | None = None) -> list[dict]:
        self.ensure_schema()

        age_seconds = self.recovery_timeout_seconds if min_age_seconds is None else max(0.0, float(min_age_seconds))
        older_than = time.time() - age_seconds
        with connect(self.messages.db) as conn:
            rows = conn.execute(
                """
                SELECT seq, type, ts, payload_json
                FROM events
                WHERE type IN ('assistant.message.started', 'assistant.message.completed', 'assistant.message.failed')
                ORDER BY seq DESC
                LIMIT ?
                """,
                (int(self.scan_limit),),
            ).fetchall()

        pending: dict[tuple[str, str], dict] = {}
        terminal: set[tuple[str, str]] = set()
        for row in reversed(rows):
            try:
                payload = json.loads(row['payload_json'] or '{}')
            except Exception:
                continue
            key = (
                str(payload.get('sessionId') or '').strip(),
                str(payload.get('clientMessageId') or '').strip(),
            )
            if not key[0] or not key[1]:
                continue
            row_type = str(row['type'] or '')
            if row_type == 'assistant.message.started':
                if key not in terminal and float(row['ts'] or 0) <= older_than:
                    pending[key] = {
                        'sessionId': key[0],
                        'clientMessageId': key[1],
                        'requestId': str(payload.get('requestId') or '').strip(),
                        'assistantMessageId': str(payload.get('messageId') or '').strip(),
                        'startedTs': float(row['ts'] or 0),
                    }
                continue
            terminal.add(key)
            pending.pop(key, None)
        return list(pending.values())

    async def _recover_candidate(self, candidate: dict) -> bool:
        session_id = str(candidate.get('sessionId') or '').strip()
        client_message_id = str(candidate.get('clientMessageId') or '').strip()
        request_id = str(candidate.get('requestId') or '').strip()
        if not session_id or not client_message_id:
            return False

        recovery_key = f'{session_id}:{client_message_id}'
        if self.recoveries.get(recovery_key):
            return False

        if self.request_deduper is not None:
            record = await self.request_deduper.get(session_id, client_message_id)
            if record is not None and record.status == 'running':
                return False

        user_message = self.messages.find_message_by_client_message_id(session_id, client_message_id)
        if user_message is None:
            return False

        if self.messages.has_assistant_after(session_id, float(user_message.get('createdAt') or 0)):
            self.recoveries.mark(
                recovery_key=recovery_key,
                session_id=session_id,
                client_message_id=client_message_id,
                user_message_id=str(user_message.get('id') or ''),
                request_id=request_id,
                source=_RECOVERY_SOURCE,
                status='skipped_existing',
                reason='assistant_exists_after_user',
            )
            return False

        session = self.sessions.get_session(session_id)
        session_key = self._extract_session_key(getattr(session, 'route_key', '') if session else '')
        if not session_key:
            return False

        transcript_path = self._resolve_transcript_path(session_key)
        if transcript_path is None:
            return False

        recovered_body = self._extract_recovery_body(
            transcript_path=transcript_path,
            user_text=str(user_message.get('text') or ''),
            user_created_at=float(user_message.get('createdAt') or 0),
        )
        if not recovered_body:
            return False

        user_created_at = float(user_message.get('createdAt') or 0)
        if self.messages.has_assistant_after(session_id, user_created_at):
            self.recoveries.mark(
                recovery_key=recovery_key,
                session_id=session_id,
                client_message_id=client_message_id,
                user_message_id=str(user_message.get('id') or ''),
                request_id=request_id,
                source=_RECOVERY_SOURCE,
                status='skipped_existing',
                reason='assistant_exists_after_user',
            )
            return False
        if self._has_equivalent_assistant_after_user(
            session_id,
            user_created_at=user_created_at,
            text=recovered_body,
        ):
            self.recoveries.mark(
                recovery_key=recovery_key,
                session_id=session_id,
                client_message_id=client_message_id,
                user_message_id=str(user_message.get('id') or ''),
                request_id=request_id,
                source=_RECOVERY_SOURCE,
                status='skipped_existing',
                reason='equivalent_assistant_exists_after_user',
            )
            return False

        recovery_text = f'[恢复消息]\n\n{recovered_body}'
        meta = {
            'recovered': True,
            'recoverySource': _RECOVERY_SOURCE,
            'recoveryKey': recovery_key,
            'recoveryRequestId': request_id,
            'recoveryUserMessageId': str(user_message.get('id') or ''),
            'transcriptPath': str(transcript_path),
        }
        persisted_messages = self.chat_service.persist_assistant_message(
            session_id=session_id,
            reply=recovery_text,
            raw_reply=recovery_text,
            images=[],
            meta=json.dumps(meta, ensure_ascii=False),
            source='recovery',
        )
        if not persisted_messages:
            return False
        persisted = persisted_messages[-1]
        self.recoveries.mark(
            recovery_key=recovery_key,
            session_id=session_id,
            client_message_id=client_message_id,
            user_message_id=str(user_message.get('id') or ''),
            request_id=request_id,
            source=_RECOVERY_SOURCE,
            status='recovered',
            message_id=str(persisted.get('id') or ''),
            meta=meta,
        )
        await self.events_bus.publish(
            'assistant.message.completed',
            {
                'sessionId': session_id,
                'clientMessageId': client_message_id,
                'requestId': request_id,
                'messageId': persisted.get('id') or '',
                'message': persisted,
            },
        )
        _LOG.warning(
            '[alicechat.recovery] recovered sessionId=%s clientMessageId=%s requestId=%s transcript=%s',
            session_id,
            client_message_id,
            request_id,
            transcript_path,
        )
        return True

    def _extract_session_key(self, route_key: str) -> str:
        value = str(route_key or '').strip()
        if '|' not in value:
            return ''
        _, session_key = value.split('|', 1)
        return session_key.strip() if session_key.strip().startswith('agent:') else ''

    def _resolve_session_transcript(self, session_id: str) -> tuple[Path | None, list[dict[str, Any]]]:
        session = self.sessions.get_session(str(session_id or '').strip())
        session_key = self._extract_session_key(getattr(session, 'route_key', '') if session else '')
        if not session_key:
            return None, []
        transcript_path = self._resolve_transcript_path(session_key)
        if transcript_path is None:
            return None, []
        return transcript_path, self._load_transcript_messages(transcript_path)

    def _detect_existing_suspicious_reason(self, message: dict) -> str:
        meta = parse_message_meta(message.get('meta'))
        suspicious = meta.get('suspiciousFinal')
        if isinstance(suspicious, dict) and suspicious.get('flagged'):
            reason = str(suspicious.get('reason') or '').strip()
            if reason:
                return reason
        return str(detect_suspicious_final(str(message.get('text') or '')) or '').strip()

    def _load_transcript_messages(self, transcript_path: Path) -> list[dict[str, Any]]:
        try:
            lines = transcript_path.read_text(encoding='utf-8', errors='ignore').splitlines()
        except Exception:
            _LOG.exception('[alicechat.recovery] transcript_read_failed path=%s', transcript_path)
            return []

        items: list[dict[str, Any]] = []
        for index, raw in enumerate(lines):
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except Exception:
                continue
            if record.get('type') != 'message':
                continue
            message = record.get('message') or {}
            role = str(message.get('role') or '').strip()
            if role not in {'user', 'assistant'}:
                continue
            text = self._extract_transcript_visible_text(role, message.get('content')).strip()
            if not text:
                continue
            items.append(
                {
                    'role': role,
                    'text': text,
                    'normalizedText': self._normalize_compare_text(text),
                    'createdAt': self._resolve_transcript_message_created_at(record, message),
                    'recordId': str(record.get('id') or '').strip(),
                    'transcriptMessageId': str(message.get('id') or '').strip(),
                    'transcriptIndex': index,
                }
            )
        return items

    def _build_local_visible_messages(self, messages: list[dict]) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for message in messages:
            role = str(message.get('role') or '').strip()
            if role not in {'user', 'assistant'}:
                continue
            text = str(message.get('text') or '').strip()
            if not text:
                continue
            items.append(
                {
                    'id': str(message.get('id') or '').strip(),
                    'role': role,
                    'text': text,
                    'normalizedText': self._normalize_compare_text(text),
                    'createdAt': float(message.get('createdAt') or 0),
                    'source': str(message.get('source') or ''),
                    'meta': message.get('meta') or '',
                }
            )
        return items

    def _find_overlap_start(
        self,
        transcript_messages: list[dict[str, Any]],
        local_window: list[dict[str, Any]],
    ) -> tuple[int, int]:
        if not transcript_messages or not local_window:
            return -1, 0
        best_index = -1
        best_run = 0
        first_key = self._compare_key(local_window[0])
        for index, item in enumerate(transcript_messages):
            if self._compare_key(item) != first_key:
                continue
            run = 0
            while (
                index + run < len(transcript_messages)
                and run < len(local_window)
                and self._compare_key(transcript_messages[index + run]) == self._compare_key(local_window[run])
            ):
                run += 1
            if run > best_run:
                best_index = index
                best_run = run
            if best_run == len(local_window):
                break
        return best_index, best_run

    def _find_latest_user_index_in_transcript(
        self,
        transcript_messages: list[dict[str, Any]],
        *,
        role: str,
        text: str,
        created_at: float,
    ) -> int:
        target_key = (
            str(role or '').strip(),
            self._normalize_compare_text(text),
        )
        candidates: list[tuple[int, float]] = []
        for index, item in enumerate(transcript_messages):
            if self._compare_key(item) != target_key:
                continue
            item_created_at = float(item.get('createdAt') or 0)
            distance = (
                abs(item_created_at - float(created_at))
                if created_at > 0 and item_created_at > 0
                else 0.0
            )
            candidates.append((index, distance))
        if not candidates:
            return -1
        if created_at > 0:
            candidates.sort(key=lambda item: (item[1], -item[0]))
            return candidates[0][0]
        return candidates[-1][0]

    def _compare_key(self, item: dict[str, Any]) -> tuple[str, str]:
        return (
            str(item.get('role') or '').strip(),
            str(item.get('normalizedText') or self._normalize_compare_text(str(item.get('text') or ''))),
        )

    def _normalize_compare_text(self, text: str) -> str:
        value = str(text or '').strip()
        value = _RECOVERY_MESSAGE_PREFIX_RE.sub('', value, count=1)
        value = _DISPLAY_MODEL_PREFIX_RE.sub('', value.strip(), count=1)
        return re.sub(r'\s+', ' ', value.strip())

    def _has_equivalent_assistant_after_user(
        self,
        session_id: str,
        *,
        user_created_at: float,
        text: str,
    ) -> bool:
        target = self._normalize_compare_text(text)
        if not target or user_created_at <= 0:
            return False
        for item in self._assistant_messages_after_user(
            session_id,
            user_created_at,
            limit=20,
        ):
            if self._normalize_compare_text(str(item.get('text') or '')) == target:
                return True
        return False

    def _resolve_transcript_message_created_at(self, record: dict, message: dict) -> float:
        message_ts = message.get('timestamp')
        if isinstance(message_ts, (int, float)):
            value = float(message_ts)
            return value / 1000.0 if value > 10_000_000_000 else value
        return self._record_timestamp(record)

    def _transcript_item_already_present(
        self,
        session_id: str,
        *,
        role: str,
        text: str,
        created_at: float,
    ) -> bool:
        exact = self.messages.find_equivalent_message(
            session_id,
            role=role,
            text=text,
            created_at=created_at if created_at > 0 else None,
        )
        if exact is not None:
            return True

        normalized_text = self._normalize_compare_text(text)
        if not normalized_text:
            return False
        self.messages.ensure_schema()
        with connect(self.messages.db) as conn:
            params: list[object] = [str(session_id), str(role or '')]
            created_at_clause = ''
            if created_at > 0:
                created_at_clause = 'AND ABS(created_at - ?) <= ?'
                params.extend([float(created_at), 120.0])
            rows = conn.execute(
                f"""
                SELECT text
                FROM messages
                WHERE session_id=?
                  AND deleted_at IS NULL
                  AND role=?
                  {created_at_clause}
                ORDER BY created_at ASC, id ASC
                """,
                tuple(params),
            ).fetchall()
        return any(self._normalize_compare_text(str(row['text'] or '')) == normalized_text for row in rows)

    def _build_transcript_backfill_message_id(
        self,
        *,
        session_id: str,
        transcript_item: dict[str, Any],
    ) -> str:
        raw = '|'.join(
            [
                str(session_id or '').strip(),
                str(transcript_item.get('recordId') or '').strip(),
                str(transcript_item.get('transcriptMessageId') or '').strip(),
                str(transcript_item.get('role') or '').strip(),
                str(transcript_item.get('createdAt') or ''),
                str(transcript_item.get('text') or ''),
            ]
        )
        digest = hashlib.sha1(raw.encode('utf-8')).hexdigest()[:16]
        return f'msg_tx_{digest}'

    def _resolve_transcript_path(self, session_key: str) -> Path | None:
        match = re.match(r'^agent:([^:]+):', str(session_key or '').strip())
        if not match:
            return None
        agent = match.group(1)
        manifest_path = self.agents_root / agent / 'sessions' / 'sessions.json'
        if not manifest_path.exists():
            return None
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        except Exception:
            _LOG.exception('[alicechat.recovery] manifest_read_failed path=%s', manifest_path)
            return None
        entry = manifest.get(session_key)
        if not isinstance(entry, dict):
            return None
        session_file = str(entry.get('sessionFile') or '').strip()
        if not session_file:
            return None
        path = Path(session_file).expanduser()
        return path if path.exists() else None

    def _extract_recovery_body(self, *, transcript_path: Path, user_text: str, user_created_at: float = 0) -> str:
        user_needle = str(user_text or '').strip()
        if not user_needle:
            return ''
        try:
            lines = transcript_path.read_text(encoding='utf-8', errors='ignore').splitlines()
        except Exception:
            _LOG.exception('[alicechat.recovery] transcript_read_failed path=%s', transcript_path)
            return ''

        records: list[dict] = []
        for raw in lines:
            raw = raw.strip()
            if not raw:
                continue
            try:
                records.append(json.loads(raw))
            except Exception:
                continue

        anchor_index = -1
        for idx, record in enumerate(records):
            if record.get('type') != 'message':
                continue
            message = record.get('message') or {}
            if str(message.get('role') or '') != 'user':
                continue
            content_text = self._extract_transcript_visible_text('user', message.get('content'))
            if content_text.strip() == user_needle:
                anchor_index = idx

        if anchor_index < 0:
            trajectory_path = transcript_path.with_suffix('.trajectory.jsonl')
            if self._trajectory_mentions_user(trajectory_path, user_needle):
                return self._extract_tail_assistant_text(records, user_created_at=user_created_at)
            _LOG.info(
                '[alicechat.recovery] skip_unanchored_tail_recovery transcript=%s user=%r',
                transcript_path,
                user_needle[:120],
            )
            return ''
        transcript_messages = self._load_transcript_messages(transcript_path)
        return self._build_recovery_body_from_transcript_messages(
            transcript_messages,
            anchor_index=self._find_latest_user_index_in_transcript(
                transcript_messages,
                role='user',
                text=user_needle,
                created_at=user_created_at,
            ),
        )

    def _trajectory_mentions_user(self, trajectory_path: Path, user_text: str) -> bool:
        if not trajectory_path.exists():
            return False
        needle = str(user_text or '').strip()
        if not needle:
            return False
        try:
            for raw in trajectory_path.read_text(encoding='utf-8', errors='ignore').splitlines():
                if needle in raw:
                    return True
        except Exception:
            _LOG.exception('[alicechat.recovery] trajectory_read_failed path=%s', trajectory_path)
        return False

    def _extract_tail_assistant_text(self, records: list[dict], *, user_created_at: float = 0) -> str:
        assistant_texts: list[tuple[str, float]] = []
        for record in records:
            if record.get('type') != 'message':
                continue
            message = record.get('message') or {}
            if str(message.get('role') or '') != 'assistant':
                continue
            content_text = self._extract_text_content(message.get('content')).strip()
            if content_text:
                assistant_texts.append((content_text, self._record_timestamp(record)))
        if not assistant_texts:
            return ''
        body, body_ts = assistant_texts[-1]
        if user_created_at and body_ts and body_ts <= float(user_created_at):
            return ''
        body = body.strip()
        if len(body) > 12000:
            body = body[:12000].rstrip() + '\n\n[恢复内容已截断]'
        return body

    def _record_timestamp(self, record: dict) -> float:
        raw = str(record.get('timestamp') or record.get('ts') or '').strip()
        if not raw:
            return 0.0
        try:
            if raw.endswith('Z'):
                return datetime.fromisoformat(raw.replace('Z', '+00:00')).timestamp()
            return datetime.fromisoformat(raw).timestamp()
        except Exception:
            return 0.0

    def _extract_text_content(self, content: object) -> str:
        if isinstance(content, str):
            return content
        if not isinstance(content, list):
            return ''
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if str(item.get('type') or '') != 'text':
                continue
            text = str(item.get('text') or '').strip()
            if text:
                parts.append(text)
        return '\n\n'.join(parts).strip()

    def _extract_transcript_visible_text(self, role: str, content: object) -> str:
        text = self._extract_text_content(content).strip()
        if str(role or '').strip() != 'user':
            return text
        return self._extract_visible_user_message_text(text)

    def _extract_visible_user_message_text(self, text: str) -> str:
        value = str(text or '').strip()
        if not value:
            return ''
        for marker in ('[User Message]', 'Current user request:'):
            if marker in value:
                value = value.rsplit(marker, 1)[-1].strip()
                break
        if value.startswith('System: '):
            value = self._strip_system_background_prefix(value)
        if value.startswith('[System Guidance]') or value.startswith('OpenClaw runtime context for this turn:'):
            return ''
        if value.startswith('Conversation info (untrusted metadata):'):
            return ''
        return value

    def _strip_system_background_prefix(self, text: str) -> str:
        lines = str(text or '').splitlines()
        index = 0
        while index < len(lines):
            line = lines[index].strip()
            if not line:
                index += 1
                continue
            if not line.startswith('System: '):
                break
            index += 1
        remainder = '\n'.join(lines[index:]).strip()
        return remainder or str(text or '').strip()
