from __future__ import annotations

import asyncio
import logging
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from ..store.habits import HabitsStore

_LOG = logging.getLogger(__name__)
_TZ = ZoneInfo("Asia/Shanghai")


def _today_str() -> str:
    return datetime.now(_TZ).date().isoformat()


def _week_start(today: date | None = None) -> str:
    d = today or datetime.now(_TZ).date()
    monday = d - timedelta(days=d.weekday())
    return monday.isoformat()


def _month_start(today: date | None = None) -> str:
    d = today or datetime.now(_TZ).date()
    return d.replace(day=1).isoformat()


def _is_active_day(habit: dict, today: date | None = None) -> bool:
    if not habit.get("active"):
        return False
    freq = habit.get("frequency", "daily")
    if freq == "daily":
        return True
    if freq == "weekly":
        d = today or datetime.now(_TZ).date()
        weekday = d.isoweekday()  # 1=Mon, 7=Sun
        return weekday in (habit.get("weekdays") or [])
    return False


class HabitsService:
    def __init__(self, store: HabitsStore) -> None:
        self.store = store

    # ── Daily refresh ────────────────────────────────────────

    def refresh_daily(self) -> dict[str, Any]:
        today = _today_str()
        yesterday = (datetime.now(_TZ).date() - timedelta(days=1)).isoformat()
        habits = self.store.list_habits(active_only=True)

        expired_count = 0
        created_count = 0

        for habit in habits:
            # Expire yesterday's pending instance
            if self.store.expire_instance(habit["id"], yesterday):
                expired_count += 1

            # Create today's instance if active
            if _is_active_day(habit):
                existing = self.store.get_instance(habit["id"], today)
                if existing is None:
                    self.store.upsert_instance(habit["id"], today, "pending")
                    created_count += 1

        _LOG.info(
            "Habits daily refresh: %d habits, %d expired, %d created",
            len(habits),
            expired_count,
            created_count,
        )
        return {
            "habitsCount": len(habits),
            "expiredCount": expired_count,
            "createdCount": created_count,
        }

    # ── Full snapshot for API ─────────────────────────────────

    def get_full_snapshot(self) -> dict[str, Any]:
        today = _today_str()
        habits = self.store.list_habits()
        enriched = []
        for habit in habits:
            instance = self.store.get_instance(habit["id"], today)
            stats = self.store.compute_stats(
                habit["id"],
                week_start=_week_start(),
                month_start=_month_start(),
                today=today,
            )
            streak = self.store.compute_streak(habit["id"], today)
            enriched.append({
                **habit,
                "todayInstance": instance,
                "stats": stats,
                "streak": streak,
            })
        return {"habits": enriched}

    # ── Create with auto instance ─────────────────────────────

    def create_habit(self, payload: dict[str, Any]) -> dict[str, Any]:
        habit = self.store.create_habit(payload)
        today = _today_str()
        if _is_active_day(habit):
            self.store.upsert_instance(habit["id"], today, "pending")
        return self._enrich_one(habit, today)

    # ── Helpers ───────────────────────────────────────────────

    def _enrich_one(self, habit: dict, today: str | None = None) -> dict:
        today = today or _today_str()
        instance = self.store.get_instance(habit["id"], today)
        stats = self.store.compute_stats(
            habit["id"],
            week_start=_week_start(),
            month_start=_month_start(),
            today=today,
        )
        streak = self.store.compute_streak(habit["id"], today)
        return {
            **habit,
            "todayInstance": instance,
            "stats": stats,
            "streak": streak,
        }

    # ── Daily scheduler (like diary's run_daily_scheduler) ────

    async def run_daily_scheduler(self) -> None:
        _LOG.info("Habits daily scheduler started")
        while True:
            try:
                now = datetime.now(_TZ)
                # Next run at 00:01 tomorrow
                next_run = now.replace(hour=0, minute=1, second=0, microsecond=0)
                if now >= next_run:
                    next_run += timedelta(days=1)
                wait_seconds = (next_run - now).total_seconds()
                _LOG.info("Habits next daily refresh at %s (in %.0fs)", next_run.isoformat(), wait_seconds)
                await asyncio.sleep(wait_seconds)
                self.refresh_daily()
            except asyncio.CancelledError:
                _LOG.info("Habits daily scheduler cancelled")
                break
            except Exception:
                _LOG.exception("Habits daily scheduler error")
                await asyncio.sleep(60)
