from __future__ import annotations

from fastapi import APIRouter

from ..app_context import AppContext


def create_runtime_router(context: AppContext) -> APIRouter:
    router = APIRouter()

    @router.get('/api/health')
    async def health() -> dict:
        return {'ok': True}

    return router
