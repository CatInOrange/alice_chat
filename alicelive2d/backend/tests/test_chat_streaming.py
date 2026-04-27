from __future__ import annotations

import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path

from backend.app.services.chat_service import ChatResolvedRequest
from backend.app.services.chat_streaming import ChatStreamingService


def _parse_sse_frame(frame: str) -> tuple[str, dict]:
    event_name = "message"
    data = ""

    for raw_line in str(frame or "").splitlines():
        line = raw_line.strip()
        if line.startswith("event:"):
            event_name = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            data = line.split(":", 1)[1].strip()

    return event_name, json.loads(data or "{}")


class _FakeSessionStore:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.bound_route_key = ""
        self.current_session_id = ""

    def exists(self, session_id: str) -> bool:
        return session_id == self.session_id

    def bind_route(self, session_id: str, route_key: str) -> None:
        self.bound_route_key = route_key

    def set_current_session_id(self, session_id: str) -> None:
        self.current_session_id = session_id


class _FakeEventsBus:
    def __init__(self):
        self.published: list[tuple[str, dict]] = []

    async def publish(self, event_type: str, payload: dict):
        self.published.append((event_type, payload))
        return {"type": event_type, "payload": payload}


class _FakeChatService:
    def __init__(self, speech_text: str):
        self.speech_text = speech_text

    def resolve_request(self, body: dict) -> ChatResolvedRequest:
        return ChatResolvedRequest(
            model_config={},
            provider={"id": "test-provider", "name": "Test Provider", "type": "lunaria"},
            text=str(body.get("text") or ""),
            history_text=str(body.get("text") or ""),
            agent="",
            session_name="",
            attachments=[],
            assistant_meta="",
            message_source="chat",
        )

    def run_chat_stream(self, resolved: ChatResolvedRequest, emit_delta, *, session_id: str = "", route_key: str = "") -> dict:
        del resolved, session_id, route_key
        time.sleep(0.05)
        emit_delta({"delta": json.dumps({"speech": self.speech_text}, ensure_ascii=False)})
        time.sleep(0.05)
        return {
            "reply": json.dumps({"speech": self.speech_text, "actions": []}, ensure_ascii=False),
            "provider": "test-provider",
            "providerLabel": "Test Provider",
            "model": "fake-model",
            "usage": {},
            "images": [],
        }

    def persist_user_message(self, *, session_id: str, history_text: str, attachments: list, source: str = "chat") -> None:
        del session_id, history_text, attachments, source

    def persist_assistant_message(
        self,
        *,
        session_id: str,
        reply: str,
        raw_reply: str | None = None,
        images: list[dict] | None = None,
        meta: str = "",
        source: str = "chat",
    ) -> dict:
        del raw_reply, images, meta, source
        return {
            "id": "msg_assistant_1",
            "sessionId": session_id,
            "role": "assistant",
            "text": reply,
        }


class _FakeTtsService:
    def __init__(self):
        self.first_started = asyncio.Event()
        self.second_started = asyncio.Event()
        self.release_first = asyncio.Event()
        self.started_texts: list[str] = []

    async def synthesize(self, req) -> tuple[bytes, str]:
        text = str(req.text or "")
        self.started_texts.append(text)

        if text == "这是第一句测试文本。":
            self.first_started.set()
            await self.release_first.wait()
            return b"first", "audio/wav"

        if text == "这里是第二句测试文本。":
            self.second_started.set()
            return b"second", "audio/wav"

        return b"other", "audio/wav"


class _FlushProbeTtsService:
    def __init__(self):
        self.first_finished = asyncio.Event()
        self.second_started = asyncio.Event()
        self.release_second = asyncio.Event()

    async def synthesize(self, req) -> tuple[bytes, str]:
        text = str(req.text or "")
        if text == "这是第一句测试文本。":
            self.first_finished.set()
            return b"first", "audio/wav"

        if text == "这里是第二句测试文本。":
            self.second_started.set()
            await self.release_second.wait()
            return b"second", "audio/wav"

        return b"other", "audio/wav"


class _FastReturnChatService(_FakeChatService):
    def run_chat_stream(self, resolved: ChatResolvedRequest, emit_delta, *, session_id: str = "", route_key: str = "") -> dict:
        del resolved, session_id, route_key
        emit_delta({"delta": json.dumps({"speech": self.speech_text}, ensure_ascii=False)})
        return {
            "reply": json.dumps({"speech": self.speech_text, "actions": []}, ensure_ascii=False),
            "provider": "test-provider",
            "providerLabel": "Test Provider",
            "model": "fake-model",
            "usage": {},
            "images": [],
        }


class ChatStreamingServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_tts_generation_can_run_concurrently_while_timeline_emits_in_order(self) -> None:
        session_store = _FakeSessionStore("sess_test")
        events_bus = _FakeEventsBus()
        chat_service = _FakeChatService("这是第一句测试文本。这里是第二句测试文本。")
        tts_service = _FakeTtsService()

        with tempfile.TemporaryDirectory() as temp_dir:
            context = type(
                "FakeContext",
                (),
                {
                    "session_store": session_store,
                    "chat_service": chat_service,
                    "events_bus": events_bus,
                    "tts_service": tts_service,
                    "uploads_dir": Path(temp_dir),
                },
            )()
            service = ChatStreamingService(context)

            timeline_units: list[dict] = []

            async def consume_stream() -> None:
                async for frame in service._stream(
                    {
                        "sessionId": "sess_test",
                        "modelId": "unused-model",
                        "providerId": "test-provider",
                        "text": "你好",
                        "ttsEnabled": True,
                    }
                ):
                    event_name, payload = _parse_sse_frame(frame)
                    if event_name == "timeline":
                        timeline_units.append(payload["unit"])

            consume_task = asyncio.create_task(consume_stream())

            await asyncio.wait_for(tts_service.first_started.wait(), timeout=1)
            await asyncio.wait_for(tts_service.second_started.wait(), timeout=1)
            await asyncio.sleep(0.05)

            self.assertEqual(timeline_units, [])

            tts_service.release_first.set()
            await asyncio.wait_for(consume_task, timeout=1)

        self.assertEqual(tts_service.started_texts[:2], ["这是第一句测试文本。", "这里是第二句测试文本。"])
        self.assertEqual([unit["i"] for unit in timeline_units], [0, 1])
        self.assertEqual([unit["text"] for unit in timeline_units], ["这是第一句测试文本。", "这里是第二句测试文本。"])

    async def test_timeline_frames_flush_while_later_tts_units_are_still_running(self) -> None:
        session_store = _FakeSessionStore("sess_test")
        events_bus = _FakeEventsBus()
        chat_service = _FakeChatService("这是第一句测试文本。这里是第二句测试文本。")
        tts_service = _FlushProbeTtsService()

        with tempfile.TemporaryDirectory() as temp_dir:
            context = type(
                "FakeContext",
                (),
                {
                    "session_store": session_store,
                    "chat_service": chat_service,
                    "events_bus": events_bus,
                    "tts_service": tts_service,
                    "uploads_dir": Path(temp_dir),
                },
            )()
            service = ChatStreamingService(context)

            timeline_units: list[dict] = []

            async def consume_stream() -> None:
                async for frame in service._stream(
                    {
                        "sessionId": "sess_test",
                        "modelId": "unused-model",
                        "providerId": "test-provider",
                        "text": "你好",
                        "ttsEnabled": True,
                    }
                ):
                    event_name, payload = _parse_sse_frame(frame)
                    if event_name == "timeline":
                        timeline_units.append(payload["unit"])

            consume_task = asyncio.create_task(consume_stream())

            await asyncio.wait_for(tts_service.first_finished.wait(), timeout=1)
            await asyncio.wait_for(tts_service.second_started.wait(), timeout=1)
            await asyncio.sleep(0.1)

            self.assertEqual([unit["i"] for unit in timeline_units], [0])
            self.assertEqual([unit["text"] for unit in timeline_units], ["这是第一句测试文本。"])

            tts_service.release_second.set()
            await asyncio.wait_for(consume_task, timeout=1)

        self.assertEqual([unit["i"] for unit in timeline_units], [0, 1])

    async def test_stream_finishes_with_final_event_after_tts_frames_complete(self) -> None:
        session_store = _FakeSessionStore("sess_test")
        events_bus = _FakeEventsBus()
        chat_service = _FakeChatService("这是第一句测试文本。这里是第二句测试文本。")
        tts_service = _FlushProbeTtsService()

        with tempfile.TemporaryDirectory() as temp_dir:
            context = type(
                "FakeContext",
                (),
                {
                    "session_store": session_store,
                    "chat_service": chat_service,
                    "events_bus": events_bus,
                    "tts_service": tts_service,
                    "uploads_dir": Path(temp_dir),
                },
            )()
            service = ChatStreamingService(context)

            seen_events: list[str] = []

            async def consume_stream() -> None:
                async for frame in service._stream(
                    {
                        "sessionId": "sess_test",
                        "modelId": "unused-model",
                        "providerId": "test-provider",
                        "text": "你好",
                        "ttsEnabled": True,
                    }
                ):
                    event_name, _payload = _parse_sse_frame(frame)
                    seen_events.append(event_name)

            consume_task = asyncio.create_task(consume_stream())

            await asyncio.wait_for(tts_service.first_finished.wait(), timeout=1)
            await asyncio.wait_for(tts_service.second_started.wait(), timeout=1)
            tts_service.release_second.set()

            await asyncio.wait_for(consume_task, timeout=1)

        self.assertIn("final", seen_events)

    async def test_timeline_flushes_even_after_provider_returns_immediately(self) -> None:
        session_store = _FakeSessionStore("sess_test")
        events_bus = _FakeEventsBus()
        chat_service = _FastReturnChatService("这是第一句测试文本。这里是第二句测试文本。")
        tts_service = _FlushProbeTtsService()

        with tempfile.TemporaryDirectory() as temp_dir:
            context = type(
                "FakeContext",
                (),
                {
                    "session_store": session_store,
                    "chat_service": chat_service,
                    "events_bus": events_bus,
                    "tts_service": tts_service,
                    "uploads_dir": Path(temp_dir),
                },
            )()
            service = ChatStreamingService(context)

            timeline_units: list[dict] = []

            async def consume_stream() -> None:
                async for frame in service._stream(
                    {
                        "sessionId": "sess_test",
                        "modelId": "unused-model",
                        "providerId": "test-provider",
                        "text": "你好",
                        "ttsEnabled": True,
                    }
                ):
                    event_name, payload = _parse_sse_frame(frame)
                    if event_name == "timeline":
                        timeline_units.append(payload["unit"])

            consume_task = asyncio.create_task(consume_stream())

            await asyncio.wait_for(tts_service.first_finished.wait(), timeout=1)
            await asyncio.wait_for(tts_service.second_started.wait(), timeout=1)
            await asyncio.sleep(0.1)

            self.assertEqual([unit["i"] for unit in timeline_units], [0])

            tts_service.release_second.set()
            await asyncio.wait_for(consume_task, timeout=1)

        self.assertEqual([unit["i"] for unit in timeline_units], [0, 1])


if __name__ == "__main__":
    unittest.main()
