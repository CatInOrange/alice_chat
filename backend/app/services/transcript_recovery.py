from __future__ import annotations

import asyncio
import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path

from ..services.chat_service import ChatService
from ..services.events_bus import EventsBus
from ..store import MessageStore, RecoveryStore, SessionStore
from ..store.db import connect


_LOG = logging.getLogger(__name__)

_DEFAULT_AGENTS_ROOT = Path('/root/.openclaw/agents')
_RECOVERY_SOURCE = 'openclaw_transcript'


class TranscriptRecoveryService:
    def __init__(
        self,
        *,
        sessions: SessionStore,
        messages: MessageStore,
        chat_service: ChatService,
        events_bus: EventsBus,
        recoveries: RecoveryStore,
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

    def _list_candidates(self, *, min_age_seconds: float | None = None) -> list[dict]:
        self.ensure_schema()
        import time

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
            content_text = self._extract_text_content(message.get('content'))
            if content_text.strip() == user_needle:
                anchor_index = idx

        if anchor_index < 0:
            trajectory_path = transcript_path.with_suffix('.trajectory.jsonl')
            if self._trajectory_mentions_user(trajectory_path, user_needle):
                return self._extract_tail_assistant_text(records)
            return self._extract_tail_assistant_text(records, user_created_at=user_created_at)

        parts: list[str] = []
        seen: set[str] = set()
        for record in records[anchor_index + 1:]:
            if record.get('type') != 'message':
                continue
            message = record.get('message') or {}
            role = str(message.get('role') or '')
            if role == 'user':
                break
            if role != 'assistant':
                continue
            content_text = self._extract_text_content(message.get('content')).strip()
            if not content_text:
                continue
            if content_text in seen:
                continue
            seen.add(content_text)
            parts.append(content_text)

        body = '\n\n'.join(parts).strip()
        if len(body) > 12000:
            body = body[:12000].rstrip() + '\n\n[恢复内容已截断]'
        return body

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
        if user_created_at and body_ts and body_ts < float(user_created_at):
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
