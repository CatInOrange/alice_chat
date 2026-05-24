from __future__ import annotations

import json
import time
import uuid
from typing import Any

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


class HabitsStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS habits (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT DEFAULT '',
                    frequency TEXT NOT NULL DEFAULT 'daily',
                    weekdays TEXT DEFAULT '[]',
                    reminder_time TEXT DEFAULT '',
                    active INTEGER NOT NULL DEFAULT 1,
                    color_value INTEGER DEFAULT 0,
                    icon_code_point INTEGER DEFAULT 0,
                    sort_order INTEGER DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS habit_instances (
                    id TEXT PRIMARY KEY,
                    habit_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    completed_at REAL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (habit_id) REFERENCES habits(id)
                );
                CREATE UNIQUE INDEX IF NOT EXISTS idx_habit_instances_unique
                    ON habit_instances (habit_id, date);
                """
            )
            conn.commit()

    # ── Habits CRUD ──────────────────────────────────────────

    def list_habits(self, *, active_only: bool = False) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            if active_only:
                rows = conn.execute(
                    "SELECT * FROM habits WHERE active = 1 ORDER BY sort_order ASC, created_at ASC"
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM habits ORDER BY sort_order ASC, created_at ASC"
                ).fetchall()
        return [_habit_row(row) for row in rows]

    def get_habit(self, habit_id: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT * FROM habits WHERE id = ? LIMIT 1", (habit_id,)
            ).fetchone()
        if row is None:
            return None
        return _habit_row(row)

    def create_habit(self, habit: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        habit_id = str(habit.get("id") or f"habit:{uuid.uuid4().hex[:12]}")
        ts = _now()
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO habits (id, title, description, frequency, weekdays,
                                    reminder_time, active, color_value, icon_code_point,
                                    sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    habit_id,
                    _norm_str(habit.get("title"), ""),
                    _norm_str(habit.get("description"), ""),
                    _norm_frequency(habit.get("frequency")),
                    _norm_weekdays_json(habit.get("weekdays")),
                    _norm_str(habit.get("reminderTime"), ""),
                    1 if habit.get("active") is not False else 0,
                    int(habit.get("colorValue") or 0),
                    int(habit.get("iconCodePoint") or 0),
                    int(habit.get("sortOrder") or 0),
                    ts,
                    ts,
                ),
            )
            conn.commit()
        return self.get_habit(habit_id)

    def update_habit(self, habit_id: str, updates: dict[str, Any]) -> dict[str, Any] | None:
        self.ensure_schema()
        existing = self.get_habit(habit_id)
        if existing is None:
            return None
        ts = _now()
        fields = []
        values = []
        for key, col in [
            ("title", "title"),
            ("description", "description"),
            ("frequency", "frequency"),
            ("reminderTime", "reminder_time"),
            ("active", "active"),
            ("colorValue", "color_value"),
            ("iconCodePoint", "icon_code_point"),
            ("sortOrder", "sort_order"),
        ]:
            if key in updates:
                fields.append(f"{col} = ?")
                if key == "title":
                    values.append(_norm_str(updates[key], ""))
                elif key == "description":
                    values.append(_norm_str(updates[key], ""))
                elif key == "frequency":
                    values.append(_norm_frequency(updates[key]))
                elif key == "reminderTime":
                    values.append(_norm_str(updates[key], ""))
                elif key == "active":
                    values.append(1 if updates[key] else 0)
                elif key == "weekdays":
                    # handled separately
                    pass
                else:
                    values.append(updates[key])
        if "weekdays" in updates:
            fields.append("weekdays = ?")
            values.append(_norm_weekdays_json(updates["weekdays"]))
        fields.append("updated_at = ?")
        values.append(ts)
        values.append(habit_id)
        with connect(self.db) as conn:
            conn.execute(
                f"UPDATE habits SET {', '.join(fields)} WHERE id = ?",
                values,
            )
            conn.commit()
        return self.get_habit(habit_id)

    def delete_habit(self, habit_id: str) -> bool:
        self.ensure_schema()
        with connect(self.db) as conn:
            conn.execute("DELETE FROM habit_instances WHERE habit_id = ?", (habit_id,))
            cur = conn.execute("DELETE FROM habits WHERE id = ?", (habit_id,))
            conn.commit()
            return cur.rowcount > 0

    # ── Instances ────────────────────────────────────────────

    def get_instance(self, habit_id: str, date: str) -> dict[str, Any] | None:
        self.ensure_schema()
        with connect(self.db) as conn:
            row = conn.execute(
                "SELECT * FROM habit_instances WHERE habit_id = ? AND date = ? LIMIT 1",
                (habit_id, date),
            ).fetchone()
        if row is None:
            return None
        return _instance_row(row)

    def get_instances_for_date(self, date: str) -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT * FROM habit_instances WHERE date = ?",
                (date,),
            ).fetchall()
        return [_instance_row(row) for row in rows]

    def get_instances(self, habit_id: str, *, since: str = "", until: str = "") -> list[dict[str, Any]]:
        self.ensure_schema()
        with connect(self.db) as conn:
            if since and until:
                rows = conn.execute(
                    "SELECT * FROM habit_instances WHERE habit_id = ? AND date >= ? AND date <= ? ORDER BY date ASC",
                    (habit_id, since, until),
                ).fetchall()
            elif since:
                rows = conn.execute(
                    "SELECT * FROM habit_instances WHERE habit_id = ? AND date >= ? ORDER BY date ASC",
                    (habit_id, since),
                ).fetchall()
            elif until:
                rows = conn.execute(
                    "SELECT * FROM habit_instances WHERE habit_id = ? AND date <= ? ORDER BY date ASC",
                    (habit_id, until),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM habit_instances WHERE habit_id = ? ORDER BY date ASC",
                    (habit_id,),
                ).fetchall()
        return [_instance_row(row) for row in rows]

    def upsert_instance(self, habit_id: str, date: str, status: str = "pending") -> dict[str, Any]:
        self.ensure_schema()
        inst_id = f"inst:{habit_id}:{date}"
        ts = _now()
        completed_at = ts if status == "completed" else None
        with connect(self.db) as conn:
            conn.execute(
                """
                INSERT INTO habit_instances (id, habit_id, date, status, completed_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(habit_id, date) DO UPDATE SET
                    status = excluded.status,
                    completed_at = excluded.completed_at
                """,
                (inst_id, habit_id, date, status, completed_at, ts),
            )
            conn.commit()
        return self.get_instance(habit_id, date)

    def toggle_instance(self, habit_id: str, date: str) -> dict[str, Any] | None:
        existing = self.get_instance(habit_id, date)
        if existing is None:
            return None
        new_status = "completed" if existing["status"] != "completed" else "pending"
        return self.upsert_instance(habit_id, date, new_status)

    def expire_instance(self, habit_id: str, date: str) -> bool:
        self.ensure_schema()
        existing = self.get_instance(habit_id, date)
        if existing is None or existing["status"] != "pending":
            return False
        self.upsert_instance(habit_id, date, "expired")
        return True

    # ── Stats ────────────────────────────────────────────────

    def compute_stats(self, habit_id: str, week_start: str, month_start: str, today: str) -> dict[str, Any]:
        weekly_instances = self.get_instances(habit_id, since=week_start, until=today)
        monthly_instances = self.get_instances(habit_id, since=month_start, until=today)

        def _agg(instances: list[dict]) -> dict:
            total = len(instances)
            completed = sum(1 for i in instances if i["status"] == "completed")
            return {"done": completed, "total": total}

        return {
            "weekly": _agg(weekly_instances),
            "monthly": _agg(monthly_instances),
        }

    def compute_streak(self, habit_id: str, today: str) -> int:
        self.ensure_schema()
        streak = 0
        with connect(self.db) as conn:
            rows = conn.execute(
                "SELECT date, status FROM habit_instances WHERE habit_id = ? AND date <= ? ORDER BY date DESC",
                (habit_id, today),
            ).fetchall()
        for row in rows:
            if row["status"] == "completed":
                streak += 1
            elif row["status"] in ("pending",):
                # Today might be pending, don't break streak for it
                if row["date"] == today:
                    continue
                break
            else:
                break
        return streak


# ── Helpers ──────────────────────────────────────────────────

def _habit_row(row) -> dict[str, Any]:
    weekdays_raw = row["weekdays"] or "[]"
    try:
        weekdays = json.loads(weekdays_raw)
    except Exception:
        weekdays = []
    return {
        "id": row["id"],
        "title": row["title"],
        "description": row["description"] or "",
        "frequency": row["frequency"] or "daily",
        "weekdays": weekdays if isinstance(weekdays, list) else [],
        "reminderTime": row["reminder_time"] or "",
        "active": bool(row["active"]),
        "colorValue": row["color_value"] or 0,
        "iconCodePoint": row["icon_code_point"] or 0,
        "sortOrder": row["sort_order"] or 0,
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def _instance_row(row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "habitId": row["habit_id"],
        "date": row["date"],
        "status": row["status"] or "pending",
        "completedAt": row["completed_at"],
        "createdAt": row["created_at"],
    }


def _norm_str(value, default: str = "") -> str:
    return str(value or default).strip()


def _norm_frequency(value) -> str:
    v = str(value or "").strip().lower()
    return v if v in ("daily", "weekly") else "daily"


def _norm_weekdays_json(value) -> str:
    if isinstance(value, list):
        cleaned = [int(d) for d in value if isinstance(d, (int, float)) and 1 <= int(d) <= 7]
        return json.dumps(cleaned)
    try:
        parsed = json.loads(str(value or "[]"))
        if isinstance(parsed, list):
            cleaned = [int(d) for d in parsed if isinstance(d, (int, float)) and 1 <= int(d) <= 7]
            return json.dumps(cleaned)
    except Exception:
        pass
    return "[]"
