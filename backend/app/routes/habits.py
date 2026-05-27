from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException

from ..app_context import AppContext
from ..auth import verify_app_password

_TZ = ZoneInfo("Asia/Shanghai")


def _today_str() -> str:
    return datetime.now(_TZ).date().isoformat()


def _week_start() -> str:
    d = datetime.now(_TZ).date()
    monday = d - timedelta(days=d.weekday())
    return monday.isoformat()


def _month_start() -> str:
    return datetime.now(_TZ).date().replace(day=1).isoformat()


def _parse_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD") from exc


def create_habits_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get("/api/habits")
    async def list_habits() -> dict:
        context.habits_service.refresh_daily()
        snapshot = context.habits_service.get_full_snapshot()
        return {"ok": True, **snapshot}

    @router.post("/api/habits")
    async def create_habit(body: dict) -> dict:
        title = str(body.get("title") or "").strip()
        if not title:
            raise HTTPException(status_code=400, detail="title is required")
        habit = context.habits_service.create_habit(body)
        return {"ok": True, "habit": habit}

    @router.put("/api/habits/{habit_id}")
    async def update_habit(habit_id: str, body: dict) -> dict:
        existing = context.habits_store.get_habit(habit_id)
        if existing is None:
            raise HTTPException(status_code=404, detail=f"habit not found: {habit_id}")
        updated = context.habits_store.update_habit(habit_id, body)
        if updated is None:
            raise HTTPException(status_code=500, detail="update failed")
        context.habits_service.reconcile_today(updated)
        enriched = context.habits_service._enrich_one(updated)
        return {"ok": True, "habit": enriched}

    @router.delete("/api/habits/{habit_id}")
    async def delete_habit(habit_id: str) -> dict:
        deleted = context.habits_store.delete_habit(habit_id)
        if not deleted:
            raise HTTPException(status_code=404, detail=f"habit not found: {habit_id}")
        return {"ok": True, "deleted": True}

    @router.post("/api/habits/{habit_id}/toggle")
    async def toggle_habit(habit_id: str) -> dict:
        habit = context.habits_store.get_habit(habit_id)
        if habit is None:
            raise HTTPException(status_code=404, detail=f"habit not found: {habit_id}")
        today = _today_str()
        instance = context.habits_store.get_instance(habit_id, today)
        if instance is None:
            # No instance yet, create and complete
            context.habits_store.upsert_instance(habit_id, today, "completed")
        else:
            context.habits_store.toggle_instance(habit_id, today)
        enriched = context.habits_service._enrich_one(habit)
        return {"ok": True, "habit": enriched}

    @router.post("/api/habits/{habit_id}/instances/{date_value}/complete")
    async def complete_habit_instance(habit_id: str, date_value: str) -> dict:
        habit = context.habits_store.get_habit(habit_id)
        if habit is None:
            raise HTTPException(status_code=404, detail=f"habit not found: {habit_id}")
        target_date = _parse_date(date_value)
        updated = context.habits_service.set_instance_completed(habit, target_date)
        return {"ok": True, "habit": updated}

    @router.post("/api/habits/{habit_id}/instances/{date_value}/reopen")
    async def reopen_habit_instance(habit_id: str, date_value: str) -> dict:
        habit = context.habits_store.get_habit(habit_id)
        if habit is None:
            raise HTTPException(status_code=404, detail=f"habit not found: {habit_id}")
        target_date = _parse_date(date_value)
        updated = context.habits_service.reopen_instance(habit, target_date)
        return {"ok": True, "habit": updated}

    @router.post("/api/habits/refresh")
    async def refresh_habits() -> dict:
        result = context.habits_service.refresh_daily()
        return {"ok": True, **result}

    @router.get("/api/habits/stats")
    async def get_habits_stats() -> dict:
        habits = context.habits_store.list_habits(active_only=True)
        today = _today_str()
        ws = _week_start()
        ms = _month_start()
        stats_list = []
        for h in habits:
            s = context.habits_store.compute_stats(h["id"], week_start=ws, month_start=ms, today=today)
            streak = context.habits_store.compute_streak(h["id"], today)
            stats_list.append({
                "habitId": h["id"],
                "title": h["title"],
                "frequency": h["frequency"],
                "stats": s,
                "streak": streak,
            })
        return {"ok": True, "habits": stats_list}

    return router
