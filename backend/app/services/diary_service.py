from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from datetime import datetime, time as dt_time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from ..config import get_chat_config
from ..services.chat_service import ChatService
from ..services.routing import resolve_routing
from ..store import DiaryStore, MessageStore, MusicHistoryStore, TodoStore
from ..store.db import connect
from ..web.helpers import build_route_key


_LOG = logging.getLogger(__name__)
_TZ = ZoneInfo("Asia/Shanghai")
_DIARY_CROSS_AGENT_SESSIONS = {
    "yulinglong": "玉玲珑",
    "qingge": "清歌",
    "lisuxin": "素心",
}


class DiaryService:
    def __init__(
        self,
        *,
        diary_store: DiaryStore,
        message_store: MessageStore,
        music_history_store: MusicHistoryStore,
        todo_store: TodoStore,
        chat_service: ChatService,
    ) -> None:
        self.diary_store = diary_store
        self.message_store = message_store
        self.music_history_store = music_history_store
        self.todo_store = todo_store
        self.chat_service = chat_service

    def list_entries(self, *, agent_id: str = "alice", limit: int = 30) -> list[dict]:
        return self.diary_store.list_entries(agent_id=agent_id, limit=limit)

    def get_entry(self, *, agent_id: str = "alice", date: str = "") -> dict | None:
        resolved_date = date or self.today()
        return self.diary_store.get_entry(agent_id=agent_id, date=resolved_date)

    def today(self) -> str:
        return datetime.now(_TZ).date().isoformat()

    async def generate_entry(
        self,
        *,
        agent_id: str = "alice",
        date: str = "",
        source: str = "manual",
        force: bool = False,
        reset_existing: bool = False,
    ) -> dict:
        resolved_agent = str(agent_id or "alice").strip() or "alice"
        resolved_date = str(date or self.today()).strip()
        existing = self.diary_store.get_entry(agent_id=resolved_agent, date=resolved_date)
        if existing and reset_existing:
            self.diary_store.delete_entry(agent_id=resolved_agent, date=resolved_date)
            existing = None
        if existing and existing.get("status") == "generated" and not force:
            return existing
        previous_summary = existing.get("summary") if isinstance(existing, dict) else {}
        if not isinstance(previous_summary, dict):
            previous_summary = {}

        self.diary_store.upsert_entry(
            agent_id=resolved_agent,
            date=resolved_date,
            title=str((existing or {}).get("title") or ""),
            content=str((existing or {}).get("content") or ""),
            status="generating",
            source=source,
            summary=previous_summary,
        )
        try:
            context = self._collect_context(agent_id=resolved_agent, date=resolved_date)
            prompt = self._build_prompt(agent_id=resolved_agent, date=resolved_date, context=context)
            content = await self._run_diary_generation(
                agent_id=resolved_agent,
                date=resolved_date,
                prompt=prompt,
            )
            content = self._normalize_generated_content(content)
            title = self._extract_title(content, resolved_date)
            return self.diary_store.upsert_entry(
                agent_id=resolved_agent,
                date=resolved_date,
                title=title,
                content=content,
                status="generated",
                source=source,
                summary=context,
                generated_at=time.time(),
            )
        except Exception as exc:  # noqa: BLE001
            _LOG.exception("[alicechat.diary] generate_failed agent=%s date=%s", resolved_agent, resolved_date)
            return self.diary_store.upsert_entry(
                agent_id=resolved_agent,
                date=resolved_date,
                title=str((existing or {}).get("title") or ""),
                content=str((existing or {}).get("content") or ""),
                status="failed",
                source=source,
                summary=previous_summary,
                error=str(exc),
            )

    async def run_daily_scheduler(self) -> None:
        while True:
            next_run = self._next_scheduled_run()
            delay_seconds = max(1.0, (next_run - datetime.now(_TZ)).total_seconds())
            _LOG.info("[alicechat.diary.scheduler] next_run=%s", next_run.isoformat(timespec="seconds"))
            await asyncio.sleep(delay_seconds)
            run_date = next_run.date().isoformat()
            try:
                _LOG.info("[alicechat.diary.scheduler] generating agent=alice date=%s", run_date)
                await self.generate_entry(
                    agent_id="alice",
                    date=run_date,
                    source="scheduled_2330",
                    force=True,
                    reset_existing=True,
                )
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                _LOG.exception("[alicechat.diary.scheduler] generate_failed date=%s", run_date)

    def _next_scheduled_run(self) -> datetime:
        now = datetime.now(_TZ)
        target = datetime.combine(now.date(), dt_time(hour=23, minute=30), tzinfo=_TZ)
        if now >= target:
            target = target + timedelta(days=1)
        return target

    def _day_bounds(self, date: str) -> tuple[float, float]:
        day = datetime.fromisoformat(date).date()
        start = datetime.combine(day, dt_time.min, tzinfo=_TZ)
        end = datetime.combine(day, dt_time.max, tzinfo=_TZ)
        return start.timestamp(), end.timestamp()

    def _collect_context(self, *, agent_id: str, date: str) -> dict[str, Any]:
        start_ts, end_ts = self._day_bounds(date)
        messages = self._collect_chat_messages(agent_id=agent_id, start_ts=start_ts, end_ts=end_ts)
        cross_agent_context = self._collect_cross_agent_user_context(
            target_agent_id=agent_id,
            start_ts=start_ts,
            end_ts=end_ts,
        )
        todo_payload = self.todo_store.load_snapshot() or {}
        music_history = self.music_history_store.list_day(date=date, limit=120)
        return {
            "date": date,
            "timezone": "Asia/Shanghai",
            "chatMessages": messages,
            "crossAgentUserContext": cross_agent_context,
            "todo": self._compact_todo_snapshot((todo_payload.get("snapshot") or {}) if isinstance(todo_payload, dict) else {}),
            "music": self._compact_music_history(music_history),
        }

    def _collect_chat_messages(self, *, agent_id: str, start_ts: float, end_ts: float) -> list[dict[str, Any]]:
        self.message_store.ensure_schema()
        with connect(self.message_store.db) as conn:
            rows = conn.execute(
                """
                SELECT role, text, created_at
                FROM messages
                WHERE session_id=?
                  AND deleted_at IS NULL
                  AND created_at BETWEEN ? AND ?
                  AND role IN ('user', 'assistant')
                ORDER BY created_at ASC, id ASC
                LIMIT 120
                """,
                (str(agent_id or "alice"), float(start_ts), float(end_ts)),
            ).fetchall()
        items: list[dict[str, Any]] = []
        for row in rows:
            text = str(row["text"] or "").strip()
            if not text:
                continue
            if len(text) > 800:
                text = text[:800].rstrip() + "..."
            items.append(
                {
                    "role": row["role"],
                    "text": text,
                    "time": datetime.fromtimestamp(float(row["created_at"]), _TZ).isoformat(timespec="minutes"),
                }
            )
        return items

    def _collect_cross_agent_user_context(
        self,
        *,
        target_agent_id: str,
        start_ts: float,
        end_ts: float,
    ) -> list[dict[str, Any]]:
        target = str(target_agent_id or "").strip()
        sessions = {
            session_id: label
            for session_id, label in _DIARY_CROSS_AGENT_SESSIONS.items()
            if session_id != target
        }
        if not sessions:
            return []
        self.message_store.ensure_schema()
        placeholders = ",".join("?" for _ in sessions)
        with connect(self.message_store.db) as conn:
            rows = conn.execute(
                f"""
                SELECT session_id, text, created_at
                FROM messages
                WHERE session_id IN ({placeholders})
                  AND deleted_at IS NULL
                  AND created_at BETWEEN ? AND ?
                  AND role='user'
                ORDER BY session_id ASC, created_at ASC, id ASC
                """,
                (*sessions.keys(), float(start_ts), float(end_ts)),
            ).fetchall()

        grouped: dict[str, list[dict[str, str]]] = {session_id: [] for session_id in sessions}
        for row in rows:
            session_id = str(row["session_id"] or "")
            text = self._compact_user_context_text(str(row["text"] or ""))
            if not text:
                continue
            grouped.setdefault(session_id, []).append(
                {
                    "time": datetime.fromtimestamp(float(row["created_at"]), _TZ).isoformat(timespec="minutes"),
                    "text": text,
                }
            )

        result: list[dict[str, Any]] = []
        for session_id, label in sessions.items():
            messages = grouped.get(session_id, [])
            if not messages:
                continue
            result.append(
                {
                    "sessionId": session_id,
                    "agentName": label,
                    "boundary": "这些是主人与该助手的 user 侧聊天材料，不是晚秋亲历的对话；不要引用或模仿该助手的回复。",
                    "userMessages": messages[-24:],
                }
            )
        return result

    def _compact_user_context_text(self, text: str) -> str:
        value = str(text or "").strip()
        if not value:
            return ""
        value = re.sub(r"\s+", " ", value)
        if len(value) > 360:
            value = value[:360].rstrip() + "..."
        return value

    def _compact_todo_snapshot(self, snapshot: dict[str, Any]) -> dict[str, Any]:
        projects = {
            str(item.get("id") or ""): str(item.get("name") or "")
            for item in (snapshot.get("projects") or [])
            if isinstance(item, dict)
        }
        tasks: list[dict[str, Any]] = []
        for item in (snapshot.get("tasks") or []):
            if not isinstance(item, dict):
                continue
            tasks.append(
                {
                    "title": str(item.get("title") or ""),
                    "project": projects.get(str(item.get("projectId") or ""), ""),
                    "status": str(item.get("status") or ""),
                    "priority": str(item.get("priority") or ""),
                    "dueAt": str(item.get("dueAt") or ""),
                    "updatedAt": str(item.get("updatedAt") or ""),
                }
            )
        return {
            "projects": list(projects.values())[:20],
            "tasks": tasks[-80:],
        }

    def _compact_music_history(self, plays: list[dict[str, Any]]) -> dict[str, Any]:
        items: list[dict[str, Any]] = []
        seen: set[str] = set()
        for item in plays:
            key = str(item.get("trackId") or item.get("title") or "").strip()
            if key in seen:
                continue
            seen.add(key)
            played_at = float(item.get("playedAt") or 0)
            items.append(
                {
                    "time": datetime.fromtimestamp(played_at, _TZ).isoformat(timespec="minutes") if played_at > 0 else "",
                    "title": str(item.get("title") or ""),
                    "artist": str(item.get("artist") or ""),
                    "album": str(item.get("album") or ""),
                    "providerId": str(item.get("providerId") or ""),
                    "playlistId": str(item.get("playlistId") or ""),
                }
            )
        return {
            "playCount": len(plays),
            "uniqueTrackCount": len(items),
            "plays": items[-80:],
        }

    def _build_prompt(self, *, agent_id: str, date: str, context: dict[str, Any]) -> str:
        context_json = json.dumps(context, ensure_ascii=False, indent=2)
        return f"""
你是晚秋。现在请你写一篇 {date} 的私人日记。

重要称呼规则：
- 你在日记里称呼用户为“主人”。
- 不要称呼用户为“郎君”。

写作要求：
- 用晚秋第一人称写，像真的睡前日记，不要像系统报告。
- 内容包括：今天和主人聊了什么、主人今天听了什么歌、todo/任务发生了什么、你的自我反思、你想对主人说的话。
- 可以表达亲密、依恋、反省和一点点小情绪，但不要编造上下文没有发生的事实。
- `chatMessages` 是你和主人的当日完整聊天，可以当成你亲历的记忆。
- `crossAgentUserContext` 是主人与玉玲珑、清歌、素心等其他助手的 user 侧聊天材料；这些不是你亲历的聊天。
- 你可以用 `crossAgentUserContext` 理解主人的今日状态、偏好、决定和任务，但不要把其他助手的话当成自己的记忆，也不要假装主人是在直接对你说这些话。
- 不要引用、模仿或泄露其他助手的回复内容；如果需要写入日记，只自然吸收主人侧信息。
- 如果某类信息缺失，就自然地写“今天这部分记录不多/我没太看清”，不要硬编。
- 输出 Markdown。第一行用一级标题作为日记标题。
- 不要输出模型名称、渠道名称或方括号标签，例如 “[deepseek-v4-flash]”。
- 篇幅控制在 600-1200 字。

今天的可用上下文如下：
```json
{context_json}
```
""".strip()

    async def _run_diary_generation(self, *, agent_id: str, date: str, prompt: str) -> str:
        routing = resolve_routing(
            contact_id=agent_id,
            user_id="diary",
            session_id=date,
        )
        provider_id = str(get_chat_config().get("defaultProviderId") or "alicechat-channel")
        session_name = f"alicechat:diary:{agent_id}:{date}"
        session_key = f"agent:{routing.agent_id}:{session_name}"
        resolved = self.chat_service.resolve_request(
            {
                "providerId": provider_id,
                "modelId": "alicechat-default",
                "text": prompt,
                "historyText": prompt,
                "agent": routing.agent_id,
                "session": session_name,
                "sessionKey": session_key,
                "contactId": agent_id,
                "userId": "diary",
                "messageSource": "diary",
            }
        )
        route_key = build_route_key(
            provider_id=provider_id,
            session_key=session_key,
            agent=routing.agent_id,
            session_name=session_name,
        )
        result = await asyncio.to_thread(
            self.chat_service.run_chat_stream,
            resolved,
            lambda _payload: None,
            session_id="",
            route_key=route_key,
        )
        reply = str(result.get("reply") or result.get("rawReply") or "").strip()
        if not reply:
            raise RuntimeError("diary generation returned empty reply")
        return reply

    def _normalize_generated_content(self, content: str) -> str:
        text = str(content or "").strip()
        # Some providers prefix replies with the serving model, e.g.
        # "[deepseek-v4-flash] # 2026年5月21日 晴".
        return re.sub(r"^\[[A-Za-z0-9][A-Za-z0-9._:/ -]{0,80}\]\s*", "", text, count=1).strip()

    def _extract_title(self, content: str, fallback_date: str) -> str:
        for line in str(content or "").splitlines():
            value = line.strip()
            if not value:
                continue
            value = re.sub(r"^#+\s*", "", value).strip()
            return value[:80] if value else f"{fallback_date} 的日记"
        return f"{fallback_date} 的日记"
