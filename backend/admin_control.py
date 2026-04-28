from __future__ import annotations

import argparse
import asyncio
import json
import os
import shlex
import socket
import subprocess
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

import uvicorn
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from backend.app.auth import verify_app_password
from backend.app.config import load_config

ROOT = Path('/root/.openclaw/AliceChat').resolve()
DATA_DIR = ROOT / 'data' / 'admin_control'
LOCK_DIR = DATA_DIR / 'locks'
BACKEND_PORT = 18081
CONTROL_PORT = 18082
BACKEND_HEALTH_URL = f'http://127.0.0.1:{BACKEND_PORT}/api/health'
BACKEND_LOG = '/tmp/alicechat-backend.log'
GATEWAY_RESTART_CMD = ['openclaw', 'gateway', 'restart']
BACKEND_START_CMD = (
    f'cd {shlex.quote(str(ROOT))} && '
    f'PYTHONPATH={shlex.quote(str(ROOT))} '
    f'nohup python3 -m backend.run --port {BACKEND_PORT} '
    f'> {shlex.quote(BACKEND_LOG)} 2>&1 &'
)


def _ensure_dirs() -> None:
    LOCK_DIR.mkdir(parents=True, exist_ok=True)


@dataclass
class TaskRecord:
    id: str
    action: str
    state: str
    message: str
    created_at: float
    started_at: float | None = None
    finished_at: float | None = None
    detail: dict[str, Any] = field(default_factory=dict)


class TaskRegistry:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._tasks: dict[str, TaskRecord] = {}

    def create(self, action: str) -> TaskRecord:
        task = TaskRecord(
            id=f'{action}-{uuid.uuid4().hex[:12]}',
            action=action,
            state='accepted',
            message='任务已接收',
            created_at=time.time(),
        )
        with self._lock:
            self._tasks[task.id] = task
        return task

    def update(self, task_id: str, **changes: Any) -> TaskRecord:
        with self._lock:
            task = self._tasks[task_id]
            for key, value in changes.items():
                setattr(task, key, value)
            return task

    def get(self, task_id: str) -> TaskRecord | None:
        with self._lock:
            return self._tasks.get(task_id)


TASKS = TaskRegistry()
ACTION_LOCKS = {
    'restart-backend': threading.Lock(),
    'restart-gateway': threading.Lock(),
}


def _is_port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(('127.0.0.1', port)) == 0


def _wait_for_backend(timeout_seconds: float = 30.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            request = Request(BACKEND_HEALTH_URL, headers={'Accept': 'application/json'})
            with urlopen(request, timeout=2.0) as response:  # noqa: S310
                if response.status == 200:
                    payload = json.loads(response.read().decode('utf-8') or '{}')
                    if payload.get('ok') is True:
                        return
        except (OSError, URLError, TimeoutError, json.JSONDecodeError):
            pass
        time.sleep(1.0)
    raise RuntimeError('backend did not become healthy in time')


def _run_shell(command: str) -> None:
    subprocess.run(['bash', '-lc', command], check=True)  # noqa: S603,S607


def _restart_backend_impl() -> dict[str, Any]:
    pids_output = subprocess.run(  # noqa: S603,S607
        ['bash', '-lc', f'lsof -t -i:{BACKEND_PORT} || true'],
        capture_output=True,
        text=True,
        check=True,
    )
    raw_pids = [line.strip() for line in pids_output.stdout.splitlines() if line.strip()]
    killed: list[str] = []
    for pid in raw_pids:
        subprocess.run(['kill', pid], check=False)  # noqa: S603
        killed.append(pid)
    if killed:
        deadline = time.time() + 10.0
        while time.time() < deadline and _is_port_open(BACKEND_PORT):
            time.sleep(0.5)
    _run_shell(BACKEND_START_CMD)
    _wait_for_backend()
    return {
        'killedPids': killed,
        'logFile': BACKEND_LOG,
        'healthUrl': BACKEND_HEALTH_URL,
    }


def _restart_gateway_impl() -> dict[str, Any]:
    completed = subprocess.run(  # noqa: S603
        GATEWAY_RESTART_CMD,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout or 'gateway restart failed').strip())
    return {
        'stdout': (completed.stdout or '').strip(),
        'stderr': (completed.stderr or '').strip(),
    }


def _run_task(task_id: str, action: str) -> None:
    lock = ACTION_LOCKS[action]
    if not lock.acquire(blocking=False):
        TASKS.update(task_id, state='failed', message='已有同类任务在执行', finished_at=time.time())
        return
    try:
        TASKS.update(task_id, state='running', message='任务执行中', started_at=time.time())
        if action == 'restart-backend':
            detail = _restart_backend_impl()
            TASKS.update(task_id, state='succeeded', message='Backend 已重启', finished_at=time.time(), detail=detail)
            return
        if action == 'restart-gateway':
            detail = _restart_gateway_impl()
            TASKS.update(task_id, state='succeeded', message='Gateway 已重启', finished_at=time.time(), detail=detail)
            return
        raise RuntimeError(f'unknown action: {action}')
    except Exception as exc:  # noqa: BLE001
        TASKS.update(task_id, state='failed', message=str(exc), finished_at=time.time())
    finally:
        lock.release()


async def _start_task(action: str) -> dict[str, Any]:
    task = TASKS.create(action)
    thread = threading.Thread(target=_run_task, args=(task.id, action), daemon=True)
    thread.start()
    return {'ok': True, 'task': asdict(task)}


app = FastAPI(title='AliceChat Admin Control', version='0.1')
app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_credentials=False,
    allow_methods=['*'],
    allow_headers=['*'],
)


@app.on_event('startup')
async def _startup() -> None:
    _ensure_dirs()
    load_config()


@app.get('/api/admin-control/health')
async def health(_: None = Depends(verify_app_password)) -> dict[str, Any]:
    return {'ok': True, 'service': 'admin-control'}


@app.post('/api/admin-control/restart/backend')
async def restart_backend(_: None = Depends(verify_app_password)) -> dict[str, Any]:
    return await _start_task('restart-backend')


@app.post('/api/admin-control/restart/gateway')
async def restart_gateway(_: None = Depends(verify_app_password)) -> dict[str, Any]:
    return await _start_task('restart-gateway')


@app.get('/api/admin-control/tasks/{task_id}')
async def get_task(task_id: str, _: None = Depends(verify_app_password)) -> dict[str, Any]:
    task = TASKS.get(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail='task not found')
    return {'ok': True, 'task': asdict(task)}


def main() -> None:
    parser = argparse.ArgumentParser(description='AliceChat admin control service')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=int(os.environ.get('ALICECHAT_ADMIN_CONTROL_PORT') or CONTROL_PORT))
    args = parser.parse_args()
    uvicorn.run(app, host=str(args.host), port=int(args.port), log_level='info')


if __name__ == '__main__':
    main()
