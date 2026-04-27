from __future__ import annotations

from fastapi import APIRouter

from ..app_context import AppContext
from ..services.chat_streaming import ChatStreamingService


def create_chat_router(context: AppContext) -> APIRouter:
    router = APIRouter()
    service = ChatStreamingService(context)

    @router.post('/api/chat/stream')
    async def chat_stream(body: dict):
        return service.create_response(body)

    return router
