from __future__ import annotations

import json

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, Response

from ..config import FRONTEND_DIR, PATCHED_MODEL_JSON, get_model_dir, get_model_or_raise
from ..manifest import build_patched_model_json


def create_assets_router() -> APIRouter:
    router = APIRouter()

    @router.get('/models/{model_id}/{path:path}')
    async def models_static(model_id: str, path: str):
        model_config = get_model_or_raise(model_id)
        model_dir = get_model_dir(model_config).resolve()

        if path == PATCHED_MODEL_JSON:
            data = json.dumps(build_patched_model_json(model_config), ensure_ascii=True)
            return Response(content=data, media_type='application/json', headers={'Cache-Control': 'no-store'})

        target = (model_dir / path).resolve()
        if not str(target).startswith(str(model_dir)):
            raise HTTPException(status_code=403, detail='Forbidden')
        if not target.exists() or not target.is_file():
            raise HTTPException(status_code=404, detail='Not Found')
        return FileResponse(target, headers={'Cache-Control': 'public, max-age=31536000, immutable'})

    @router.get('/')
    async def frontend_index():
        index = (FRONTEND_DIR / 'index.html').resolve()
        return FileResponse(index, media_type='text/html', headers={'Cache-Control': 'no-store'})

    @router.get('/index.html')
    async def frontend_index_alias():
        index = (FRONTEND_DIR / 'index.html').resolve()
        return FileResponse(index, media_type='text/html', headers={'Cache-Control': 'no-store'})

    return router
