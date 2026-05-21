from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from datetime import datetime, time as dt_time
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
    ) -> dict:
        resolved_agent = str(agent_id or "alice").strip() or "alice"
        resolved_date = str(date or self.today()).strip()
        existing = self.diary_store.get_entry(agent_id=resolved_agent, date=resolved_date)
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

    def _day_bounds(self, date: str) -> tuple[float, float]:
        day = datetime.fromisoformat(date).date()
        start = datetime.combine(day, dt_time.min, tzinfo=_TZ)
        end = datetime.combine(day, dt_time.max, tzinfo=_TZ)
        return start.timestamp(), end.timestamp()

    def _collect_context(self, *, agent_id: str, date: str) -> dict[str, Any]:
        start_ts, end_ts = self._day_bounds(date)
        messages = self._collect_chat_messages(agent_id=agent_id, start_ts=start_ts, end_ts=end_ts)
        todo_payload = self.todo_store.load_snapshot() or {}
        music_history = self.music_history_store.list_day(date=date, limit=120)
        return {
            "date": date,
            "timezone": "Asia/Shanghai",
            "chatMessages": messages,
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
