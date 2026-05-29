from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from backend.app.services.chat_service import ChatService
from backend.app.services.events_bus import EventsBus
from backend.app.services.transcript_recovery import TranscriptRecoveryService
from backend.app.store import MessageStore, RecoveryStore, SessionStore
from backend.app.store.db import DbConfig


def _write_jsonl(path: Path, records: list[dict]) -> None:
    path.write_text(
        '\n'.join(json.dumps(record, ensure_ascii=False) for record in records),
        encoding='utf-8',
    )


class TranscriptRecoveryTextSelectionTest(unittest.TestCase):
    def _service(self, tmpdir: Path) -> TranscriptRecoveryService:
        db = DbConfig(tmpdir / 'test.sqlite3')
        sessions = SessionStore(db)
        messages = MessageStore(db)
        return TranscriptRecoveryService(
            sessions=sessions,
            messages=messages,
            chat_service=ChatService(sessions=sessions, messages=messages),
            events_bus=EventsBus(),
            recoveries=RecoveryStore(db),
            agents_root=tmpdir / 'agents',
            recovery_timeout_seconds=15.0,
            scan_interval_seconds=10.0,
        )

    def test_extract_recovery_body_requires_user_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            transcript_path = tmpdir / 'session.jsonl'
            _write_jsonl(
                transcript_path,
                [
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:00Z',
                        'message': {'role': 'assistant', 'content': 'unrelated tail'},
                    },
                ],
            )

            body = self._service(tmpdir)._extract_recovery_body(
                transcript_path=transcript_path,
                user_text='missing user',
                user_created_at=1_779_753_600.0,
            )

            self.assertEqual(body, '')

    def test_extract_recovery_body_allows_trajectory_anchored_tail(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            transcript_path = tmpdir / 'session.jsonl'
            _write_jsonl(
                transcript_path,
                [
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:10Z',
                        'message': {'role': 'assistant', 'content': 'recovered tail'},
                    },
                ],
            )
            transcript_path.with_suffix('.trajectory.jsonl').write_text(
                '{"event":"input","text":"missing user"}\n',
                encoding='utf-8',
            )

            body = self._service(tmpdir)._extract_recovery_body(
                transcript_path=transcript_path,
                user_text='missing user',
                user_created_at=1_779_753_600.0,
            )

            self.assertEqual(body, 'recovered tail')

    def test_reconcile_tail_inserts_missing_without_deleting_imported_messages(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            service = self._service(tmpdir)
            session_key = 'agent:yulinglong:alicechat:user:contact:session'
            transcript_path = tmpdir / 'agents' / 'yulinglong' / 'sessions' / 'session.jsonl'
            transcript_path.parent.mkdir(parents=True)
            (transcript_path.parent / 'sessions.json').write_text(
                json.dumps({session_key: {'sessionFile': str(transcript_path)}}),
                encoding='utf-8',
            )
            service.sessions.create_session_with_id(
                session_id='s1',
                name='s1',
                route_key=f'alicechat-channel|{session_key}',
            )
            _write_jsonl(
                transcript_path,
                [
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:01Z', 'message': {'role': 'user', 'content': 'u1'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:02Z', 'message': {'role': 'assistant', 'content': 'a1'}},
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:03Z',
                        'message': {
                            'role': 'user',
                            'content': '[System Guidance]\nTodo reading and editing are available through tool calls.\n\n[User Message]\nu2',
                        },
                    },
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:04Z', 'message': {'role': 'assistant', 'content': 'a2'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:05Z', 'message': {'role': 'assistant', 'content': 'a3'}},
                ],
            )
            service.messages.create_message(session_id='s1', role='user', text='u1', created_at=1_779_753_601)
            service.messages.create_message(
                session_id='s1',
                role='assistant',
                text='⚠️ 🛠️ search failed',
                source='recovery',
                created_at=1_779_753_601.5,
            )
            service.messages.create_message(session_id='s1', role='user', text='u2', created_at=1_779_753_603)
            service.messages.create_message(session_id='s1', role='assistant', text='a2', created_at=1_779_753_604)
            service.messages.create_message(
                session_id='s1',
                role='assistant',
                text='local extra',
                source='transcript_reconcile',
                created_at=1_779_753_605,
            )

            result = __import__('asyncio').run(
                service.reconcile_session_tail('s1', tail_limit=5, min_age_seconds=0)
            )

            self.assertTrue(result['changed'])
            self.assertEqual(result['reason'], 'tail_window_synced')
            messages = service.messages.list_session_messages_page('s1', limit=10)['messages']
            self.assertEqual(
                [(item['role'], item['text']) for item in messages],
                [
                    ('user', 'u1'),
                    ('assistant', '⚠️ 🛠️ search failed'),
                    ('assistant', 'a1'),
                    ('user', 'u2'),
                    ('assistant', 'a2'),
                    ('assistant', 'local extra'),
                    ('assistant', 'a3'),
                ],
            )

    def test_reconcile_tail_does_not_delete_without_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            service = self._service(tmpdir)
            session_key = 'agent:yulinglong:alicechat:user:contact:session'
            transcript_path = tmpdir / 'agents' / 'yulinglong' / 'sessions' / 'session.jsonl'
            transcript_path.parent.mkdir(parents=True)
            (transcript_path.parent / 'sessions.json').write_text(
                json.dumps({session_key: {'sessionFile': str(transcript_path)}}),
                encoding='utf-8',
            )
            service.sessions.create_session_with_id(
                session_id='s1',
                name='s1',
                route_key=f'alicechat-channel|{session_key}',
            )
            _write_jsonl(
                transcript_path,
                [
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:01Z', 'message': {'role': 'user', 'content': 'old user'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:02Z', 'message': {'role': 'assistant', 'content': 'old reply'}},
                ],
            )
            service.messages.create_message(session_id='s1', role='user', text='new local user', created_at=1)

            result = __import__('asyncio').run(
                service.reconcile_session_tail('s1', tail_limit=5, min_age_seconds=0)
            )

            self.assertFalse(result['changed'])
            self.assertEqual(result['reason'], 'user_not_matched')
            messages = service.messages.list_session_messages_page('s1', limit=5)['messages']
            self.assertEqual([(item['role'], item['text']) for item in messages], [('user', 'new local user')])

    def test_reconcile_tail_repairs_order_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            service = self._service(tmpdir)
            session_key = 'agent:yulinglong:alicechat:user:contact:session'
            transcript_path = tmpdir / 'agents' / 'yulinglong' / 'sessions' / 'session.jsonl'
            transcript_path.parent.mkdir(parents=True)
            (transcript_path.parent / 'sessions.json').write_text(
                json.dumps({session_key: {'sessionFile': str(transcript_path)}}),
                encoding='utf-8',
            )
            service.sessions.create_session_with_id(
                session_id='s1',
                name='s1',
                route_key=f'alicechat-channel|{session_key}',
            )
            _write_jsonl(
                transcript_path,
                [
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:01Z', 'message': {'role': 'user', 'content': 'u1'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:02Z', 'message': {'role': 'assistant', 'content': 'a1'}},
                ],
            )
            service.messages.create_message(session_id='s1', role='assistant', text='a1', created_at=1_779_753_601)
            service.messages.create_message(session_id='s1', role='user', text='u1', created_at=1_779_753_602)

            result = __import__('asyncio').run(
                service.reconcile_session_tail('s1', tail_limit=5, min_age_seconds=0)
            )

            self.assertFalse(result['changed'])
            messages = service.messages.list_session_messages_page('s1', limit=5)['messages']
            self.assertEqual(
                [(item['role'], item['text']) for item in messages],
                [('assistant', 'a1'), ('user', 'u1')],
            )

    def test_recent_user_recovery_fills_gap_between_last_three_users(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            service = self._service(tmpdir)
            session_key = 'agent:yulinglong:alicechat:user:contact:session'
            transcript_path = tmpdir / 'agents' / 'yulinglong' / 'sessions' / 'session.jsonl'
            transcript_path.parent.mkdir(parents=True)
            (transcript_path.parent / 'sessions.json').write_text(
                json.dumps({session_key: {'sessionFile': str(transcript_path)}}),
                encoding='utf-8',
            )
            service.sessions.create_session_with_id(
                session_id='s1',
                name='s1',
                route_key=f'alicechat-channel|{session_key}',
            )
            _write_jsonl(
                transcript_path,
                [
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:01Z', 'message': {'role': 'user', 'content': 'u1'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:02Z', 'message': {'role': 'assistant', 'content': 'a1'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:03Z', 'message': {'role': 'user', 'content': 'u2'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:04Z', 'message': {'role': 'assistant', 'content': 'a2'}},
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:05Z',
                        'message': {
                            'role': 'user',
                            'content': 'OpenClaw runtime context for this turn:\nnoise\n\nCurrent user request:\nu3',
                        },
                    },
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:06Z', 'message': {'role': 'assistant', 'content': 'a3'}},
                ],
            )
            service.messages.create_message(session_id='s1', role='user', text='u1', created_at=1_779_753_601)
            service.messages.create_message(session_id='s1', role='assistant', text='a1', created_at=1_779_753_602)
            service.messages.create_message(session_id='s1', role='user', text='u2', created_at=1_779_753_603)
            service.messages.create_message(session_id='s1', role='user', text='u3', created_at=1_779_753_605)

            imported = service.recover_missing_after_recent_users('s1', limit=10, user_limit=3)

            self.assertEqual(imported, 2)
            messages = service.messages.list_session_messages_page('s1', limit=10)['messages']
            self.assertEqual(
                [(item['role'], item['text']) for item in messages],
                [
                    ('user', 'u1'),
                    ('assistant', 'a1'),
                    ('user', 'u2'),
                    ('assistant', 'a2'),
                    ('user', 'u3'),
                    ('assistant', 'a3'),
                ],
            )

    def test_sync_entry_supports_before_backfill_and_recent_gap_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            service = self._service(tmpdir)
            session_key = 'agent:yulinglong:alicechat:user:contact:session'
            transcript_path = tmpdir / 'agents' / 'yulinglong' / 'sessions' / 'session.jsonl'
            transcript_path.parent.mkdir(parents=True)
            (transcript_path.parent / 'sessions.json').write_text(
                json.dumps({session_key: {'sessionFile': str(transcript_path)}}),
                encoding='utf-8',
            )
            service.sessions.create_session_with_id(
                session_id='s1',
                name='s1',
                route_key=f'alicechat-channel|{session_key}',
            )
            _write_jsonl(
                transcript_path,
                [
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:01Z', 'message': {'role': 'user', 'content': 'old user'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:02Z', 'message': {'role': 'assistant', 'content': 'old assistant'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:03Z', 'message': {'role': 'user', 'content': 'u1'}},
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:04Z', 'message': {'role': 'assistant', 'content': 'a1'}},
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:05Z',
                        'message': {
                            'role': 'user',
                            'content': 'System: [2026-05-27 17:09:49 GMT+8] Background task update: done.\n\nu2',
                        },
                    },
                    {'type': 'message', 'timestamp': '2026-05-26T00:00:06Z', 'message': {'role': 'assistant', 'content': 'a2'}},
                ],
            )
            anchor = service.messages.create_message(session_id='s1', role='user', text='u1', created_at=1_779_753_603)
            service.messages.create_message(session_id='s1', role='assistant', text='a1', created_at=1_779_753_604)
            service.messages.create_message(session_id='s1', role='user', text='u2', created_at=1_779_753_605)

            result = service.sync_session_from_transcript(
                's1',
                before_message_id=str(anchor['id']),
                limit=10,
                recent_user_limit=3,
            )

            self.assertTrue(result['changed'])
            messages = service.messages.list_session_messages_page('s1', limit=10)['messages']
            self.assertEqual(
                [(item['role'], item['text']) for item in messages],
                [
                    ('user', 'old user'),
                    ('assistant', 'old assistant'),
                    ('user', 'u1'),
                    ('assistant', 'a1'),
                    ('user', 'u2'),
                    ('assistant', 'a2'),
                ],
            )

    def test_transcript_user_guidance_without_user_message_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            transcript_path = tmpdir / 'session.jsonl'
            _write_jsonl(
                transcript_path,
                [
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:01Z',
                        'message': {
                            'role': 'user',
                            'content': '[System Guidance]\nMusic playback control is available through tool calls.',
                        },
                    },
                    {
                        'type': 'message',
                        'timestamp': '2026-05-26T00:00:02Z',
                        'message': {'role': 'assistant', 'content': 'a1'},
                    },
                ],
            )

            messages = self._service(tmpdir)._load_transcript_messages(transcript_path)

            self.assertEqual([(item['role'], item['text']) for item in messages], [('assistant', 'a1')])


if __name__ == '__main__':
    unittest.main()
