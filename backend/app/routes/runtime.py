from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends

from ..app_context import AppContext
from ..auth import verify_app_password


def _load_openclaw_model_catalog() -> dict:
    config_path = Path.home() / '.openclaw' / 'openclaw.json'
    if not config_path.exists():
        return {'providers': [], 'providerCount': 0, 'modelCount': 0}

    try:
        payload = json.loads(config_path.read_text(encoding='utf-8'))
    except Exception:
        return {'providers': [], 'providerCount': 0, 'modelCount': 0}

    providers = []
    total_models = 0
    provider_map = ((payload.get('models') or {}).get('providers') or {})
    for provider_id, provider_config in provider_map.items():
        raw_models = provider_config.get('models') or []
        models = []
        for item in raw_models:
            model_id = str((item or {}).get('id') or '').strip()
            if not model_id:
                continue
            models.append({
                'id': model_id,
                'name': str((item or {}).get('name') or model_id),
            })
        if not models:
            continue
        total_models += len(models)
        providers.append({
            'id': str(provider_id).strip(),
            'name': str(provider_config.get('name') or provider_id),
            'models': models,
        })

    providers.sort(key=lambda item: item['id'])
    return {
        'providers': providers,
        'providerCount': len(providers),
        'modelCount': total_models,
    }


def create_runtime_router(context: AppContext) -> APIRouter:
    router = APIRouter()

    @router.get('/api/health')
    async def health() -> dict:
        return {'ok': True}

    @router.get('/api/runtime/model-catalog', dependencies=[Depends(verify_app_password)])
    async def runtime_model_catalog() -> dict:
        return {'ok': True, **_load_openclaw_model_catalog()}

    return router
