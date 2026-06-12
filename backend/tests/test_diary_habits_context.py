from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from backend.app.services.chat_service import ChatService
from backend.app.services.diary_service import DiaryService
from backend.app.services.habits_service import HabitsService
from backend.app.store import DiaryStore, HabitsStore, MessageStore, MusicHistoryStore, SessionStore, TodoStore
from backend.app.store.db import DbConfig


class DiaryHabitsContextTest(unittest.TestCase):
    def _stores(self, tmpdir: Path) -> tuple[DbConfig, HabitsStore, HabitsService]:
        db = DbConfig(tmpdir / "test.sqlite3")
        habits_store = HabitsStore(db)
        habits_service = HabitsService(store=habits_store)
        return db, habits_store, habits_service

    def test_build_diary_snapshot_summarizes_due_habits_for_date(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            _, habits_store, habits_service = self._stores(Path(raw_tmpdir))
            daily_done = habits_store.create_habit({"id": "habit:done", "title": "早睡", "frequency": "daily"})
            daily_pending = habits_store.create_habit({"id": "habit:pending", "title": "喝水", "frequency": "daily"})
            weekly_due = habits_store.create_habit({
                "id": "habit:weekly",
                "title": "周四复盘",
                "frequency": "weekly",
                "weekdays": [4],
            })
            habits_store.create_habit({
                "id": "habit:not_due",
                "title": "周五整理",
                "frequency": "weekly",
                "weekdays": [5],
            })
            habits_store.upsert_instance(daily_done["id"], "2026-06-04", "completed")
            habits_store.upsert_instance(daily_pending["id"], "2026-06-04", "pending")
            habits_store.upsert_instance(weekly_due["id"], "2026-06-04", "expired")

            snapshot = habits_service.build_diary_snapshot("2026-06-04")

            self.assertEqual(
                snapshot["summary"],
                {
                    "due": 3,
                    "completed": 1,
                    "pending": 1,
                    "expired": 1,
                    "completionRate": 1 / 3,
                },
            )
            self.assertEqual(
                [(item["title"], item["status"]) for item in snapshot["items"]],
                [("早睡", "completed"), ("喝水", "pending"), ("周四复盘", "expired")],
            )
            self.assertEqual(snapshot["items"][0]["weekly"], {"done": 1, "total": 1})

    def test_diary_context_includes_habits_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmpdir:
            tmpdir = Path(raw_tmpdir)
            db, habits_store, habits_service = self._stores(tmpdir)
            habit = habits_store.create_habit({"id": "habit:done", "title": "早睡", "frequency": "daily"})
            habits_store.upsert_instance(habit["id"], "2026-06-04", "completed")
            sessions = SessionStore(db)
            messages = MessageStore(db)
            service = DiaryService(
                diary_store=DiaryStore(db),
                message_store=messages,
                music_history_store=MusicHistoryStore(db),
                todo_store=TodoStore(db),
                chat_service=ChatService(sessions=sessions, messages=messages),
                habits_service=habits_service,
            )

            context = service._collect_context(agent_id="alice", date="2026-06-04")

            self.assertEqual(context["habits"]["summary"]["due"], 1)
            self.assertEqual(context["habits"]["summary"]["completed"], 1)
            self.assertEqual(context["habits"]["items"][0]["title"], "早睡")


if __name__ == "__main__":
    unittest.main()
