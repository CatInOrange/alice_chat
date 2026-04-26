from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from ..app_context import AppContext
from ..auth import verify_app_password

_LOG = logging.getLogger(__name__)


def create_debug_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])
    debug_dir = (context.uploads_dir / 'debug-logs').resolve()
    debug_dir.mkdir(parents=True, exist_ok=True)

    @router.post('/api/debug/client-log')
    async def client_log(body: dict):
        now = datetime.now()
        upload_id = f"debug_{now.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}"
        payload = {
            'uploadId': upload_id,
            'receivedAt': now.isoformat(),
            'body': body,
        }
        path = debug_dir / f'{upload_id}.json'
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, default=str),
            encoding='utf-8',
        )
        try:
            _LOG.warning('[alicechat.client] stored=%s %s', path.name, json.dumps(body, ensure_ascii=False, default=str))
        except Exception:
            _LOG.warning('[alicechat.client] stored=%s %r', path.name, body)
        return JSONResponse({'ok': True, 'uploadId': upload_id, 'path': str(path)})

    @router.get('/api/debug/client-log/latest')
    async def latest_client_log(limit: int = 5):
        files = sorted(
            debug_dir.glob('debug_*.json'),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )[: max(1, min(limit, 20))]
        items = []
        for file in files:
            try:
                data = json.loads(file.read_text(encoding='utf-8'))
            except Exception:
                data = {
                    'uploadId': file.stem,
                    'receivedAt': None,
                    'body': None,
                }
            items.append(
                {
                    'uploadId': data.get('uploadId') or file.stem,
                    'receivedAt': data.get('receivedAt'),
                    'path': str(file),
                    'body': data.get('body'),
                }
            )
        return JSONResponse({'ok': True, 'items': items})

    return router
