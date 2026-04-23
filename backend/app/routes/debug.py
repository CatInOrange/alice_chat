from __future__ import annotations

import json
import logging

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from ..auth import verify_app_password

_LOG = logging.getLogger(__name__)


def create_debug_router() -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.post('/api/debug/client-log')
    async def client_log(body: dict):
        try:
            _LOG.warning('[alicechat.client] %s', json.dumps(body, ensure_ascii=False, default=str))
        except Exception:
            _LOG.warning('[alicechat.client] %r', body)
        return JSONResponse({'ok': True})

    return router
