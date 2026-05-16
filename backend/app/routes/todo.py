from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from ..app_context import AppContext
from ..auth import verify_app_password


def create_todo_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/todo')
    async def get_todo_snapshot() -> dict:
        payload = context.todo_store.load_snapshot()
        if payload is None:
            return {
                'ok': True,
                'exists': False,
                'snapshot': None,
                'revision': 0,
                'updatedAt': None,
            }
        return {
            'ok': True,
            'exists': True,
            'snapshot': payload['snapshot'],
            'revision': payload['revision'],
            'updatedAt': payload['updatedAt'],
        }

    @router.put('/api/todo')
    async def save_todo_snapshot(body: dict) -> dict:
        snapshot = body.get('snapshot')
        if not isinstance(snapshot, dict):
            raise HTTPException(status_code=400, detail='snapshot is required')
        saved = context.todo_store.save_snapshot(snapshot)
        client_instance_id = str(body.get('clientInstanceId') or '').strip()
        await context.events_bus.publish(
            'todo.snapshot_changed',
            {
                'revision': saved['revision'],
                'updatedAt': saved['updatedAt'],
                'clientInstanceId': client_instance_id,
            },
        )
        return {
            'ok': True,
            'snapshot': saved['snapshot'],
            'revision': saved['revision'],
            'updatedAt': saved['updatedAt'],
        }

    return router
