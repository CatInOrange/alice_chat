from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException

from ..app_context import AppContext
from ..auth import verify_app_password

_TASK_PRIORITIES = {"low", "medium", "high", "urgent"}
_TASK_STATUSES = {"todo", "doing", "done", "archived"}
_ACTION_TYPES = {
    "create_task",
    "update_task",
    "complete_task",
    "reopen_task",
    "delete_task",
    "create_project",
    "update_project",
    "archive_project",
    "replace_subtasks",
}


def _now_iso() -> str:
    return datetime.utcnow().isoformat()


def _normalize_snapshot(snapshot: dict[str, Any] | None) -> dict[str, Any]:
    data = snapshot if isinstance(snapshot, dict) else {}
    projects = data.get("projects")
    tasks = data.get("tasks")
    subtasks = data.get("subtasks")
    return {
        "projects": projects if isinstance(projects, list) else [],
        "tasks": tasks if isinstance(tasks, list) else [],
        "subtasks": subtasks if isinstance(subtasks, list) else [],
    }


def _find_project_index(
    projects: list[dict[str, Any]],
    project_id: str = "",
    project_name: str = "",
) -> int:
    normalized_id = project_id.strip()
    if normalized_id:
        for index, project in enumerate(projects):
            if str(project.get("id") or "").strip() == normalized_id:
                return index
    normalized_name = project_name.strip().casefold()
    if normalized_name:
        for index, project in enumerate(projects):
            if str(project.get("name") or "").strip().casefold() == normalized_name:
                return index
    return -1


def _find_task_index(tasks: list[dict[str, Any]], task_id: str) -> int:
    normalized_id = task_id.strip()
    for index, task in enumerate(tasks):
        if str(task.get("id") or "").strip() == normalized_id:
            return index
    return -1


def _subtasks_for_task(
    subtasks: list[dict[str, Any]],
    task_id: str,
) -> list[dict[str, Any]]:
    normalized = task_id.strip()
    return [
        item
        for item in subtasks
        if str(item.get("taskId") or "").strip() == normalized
    ]


def _active_project_or_default(snapshot: dict[str, Any]) -> dict[str, Any]:
    projects = snapshot["projects"]
    for project in projects:
        if not bool(project.get("archived")):
            return project
    now_iso = _now_iso()
    project = {
        "id": "inbox",
        "name": "收件箱",
        "iconCodePoint": 0xE156,
        "colorValue": 0xFF7BAAF7,
        "description": "AI 临时放进来的待办。",
        "sortOrder": len(projects),
        "archived": False,
        "createdAt": now_iso,
        "updatedAt": now_iso,
    }
    projects.append(project)
    return project


def _resolve_project(snapshot: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    index = _find_project_index(
        snapshot["projects"],
        str(payload.get("projectId") or ""),
        str(payload.get("projectName") or ""),
    )
    if index >= 0:
        return snapshot["projects"][index]
    return _active_project_or_default(snapshot)


def _normalize_priority(value: Any, fallback: str = "medium") -> str:
    normalized = str(value or "").strip().lower()
    return normalized if normalized in _TASK_PRIORITIES else fallback


def _normalize_status(value: Any, fallback: str = "todo") -> str:
    normalized = str(value or "").strip().lower()
    return normalized if normalized in _TASK_STATUSES else fallback


def _optional_iso_datetime(value: Any) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).isoformat()
    except ValueError as error:
        raise HTTPException(status_code=400, detail=f"invalid datetime: {raw}") from error


def _replace_subtasks(
    snapshot: dict[str, Any],
    task: dict[str, Any],
    raw_subtasks: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    task_id = str(task["id"])
    now_iso = _now_iso()
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(raw_subtasks):
        title = str(item.get("title") or "").strip()
        if not title:
            continue
        normalized.append(
            {
                "id": str(item.get("id") or f"{task_id}:subtask:{uuid4().hex[:8]}"),
                "taskId": task_id,
                "title": title,
                "isCompleted": item.get("isCompleted") is True,
                "sortOrder": index,
                "createdAt": str(item.get("createdAt") or now_iso),
                "updatedAt": now_iso,
            }
        )
    snapshot["subtasks"] = [
        item
        for item in snapshot["subtasks"]
        if str(item.get("taskId") or "").strip() != task_id
    ] + normalized
    return normalized


def _sync_task_completion_from_subtasks(
    task: dict[str, Any],
    subtasks: list[dict[str, Any]],
) -> None:
    subtask_count = len(subtasks)
    completed_count = sum(1 for item in subtasks if item.get("isCompleted") is True)
    task["subtaskCount"] = subtask_count
    task["completedSubtaskCount"] = completed_count
    if subtask_count > 0 and completed_count == subtask_count:
        task["status"] = "done"
        task["completedAt"] = str(task.get("completedAt") or _now_iso())
    elif task.get("status") == "done" and completed_count < subtask_count:
        task["status"] = "todo"
        task["completedAt"] = None


def _touch_project(project: dict[str, Any]) -> None:
    project["updatedAt"] = _now_iso()


def _create_task(snapshot: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    title = str(payload.get("title") or "").strip()
    if not title:
        raise HTTPException(status_code=400, detail="create_task requires title")
    now_iso = _now_iso()
    project = _resolve_project(snapshot, payload)
    task = {
        "id": str(payload.get("taskId") or payload.get("id") or f"todo-task:{uuid4().hex}"),
        "projectId": str(project["id"]),
        "title": title,
        "description": str(payload.get("description") or "").strip(),
        "priority": _normalize_priority(payload.get("priority")),
        "status": _normalize_status(payload.get("status"), "todo"),
        "dueAt": _optional_iso_datetime(payload.get("dueAt")),
        "reminderAt": _optional_iso_datetime(payload.get("reminderAt")),
        "createdAt": now_iso,
        "updatedAt": now_iso,
        "completedAt": None,
        "subtaskCount": 0,
        "completedSubtaskCount": 0,
    }
    snapshot["tasks"].append(task)
    raw_subtasks = payload.get("subtasks")
    if isinstance(raw_subtasks, list):
        subtasks = _replace_subtasks(
            snapshot,
            task,
            [item for item in raw_subtasks if isinstance(item, dict)],
        )
        _sync_task_completion_from_subtasks(task, subtasks)
    elif task["status"] == "done":
        task["completedAt"] = now_iso
    _touch_project(project)
    return task


def _update_task(snapshot: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    task_id = str(payload.get("taskId") or payload.get("id") or "").strip()
    if not task_id:
        raise HTTPException(status_code=400, detail="update_task requires taskId")
    index = _find_task_index(snapshot["tasks"], task_id)
    if index < 0:
        raise HTTPException(status_code=404, detail=f"task not found: {task_id}")
    task = snapshot["tasks"][index]
    task["updatedAt"] = _now_iso()
    if "title" in payload:
        title = str(payload.get("title") or "").strip()
        if not title:
            raise HTTPException(status_code=400, detail="update_task title cannot be empty")
        task["title"] = title
    if "description" in payload:
        task["description"] = str(payload.get("description") or "").strip()
    if "priority" in payload:
        task["priority"] = _normalize_priority(payload.get("priority"), task.get("priority") or "medium")
    if "status" in payload:
        task["status"] = _normalize_status(payload.get("status"), task.get("status") or "todo")
        task["completedAt"] = _now_iso() if task["status"] == "done" else None
    if "dueAt" in payload:
        task["dueAt"] = _optional_iso_datetime(payload.get("dueAt"))
    if "reminderAt" in payload:
        task["reminderAt"] = _optional_iso_datetime(payload.get("reminderAt"))
    if (
        "projectId" in payload
        or "projectName" in payload
    ):
        project = _resolve_project(snapshot, payload)
        task["projectId"] = str(project["id"])
        _touch_project(project)
    if isinstance(payload.get("subtasks"), list):
        subtasks = _replace_subtasks(
            snapshot,
            task,
            [item for item in payload["subtasks"] if isinstance(item, dict)],
        )
        _sync_task_completion_from_subtasks(task, subtasks)
    return task


def _set_task_done(snapshot: dict[str, Any], task_id: str, done: bool) -> dict[str, Any]:
    index = _find_task_index(snapshot["tasks"], task_id)
    if index < 0:
        raise HTTPException(status_code=404, detail=f"task not found: {task_id}")
    task = snapshot["tasks"][index]
    now_iso = _now_iso()
    task["updatedAt"] = now_iso
    task["status"] = "done" if done else "todo"
    task["completedAt"] = now_iso if done else None
    subtasks = _subtasks_for_task(snapshot["subtasks"], task_id)
    if subtasks:
        for item in subtasks:
            item["isCompleted"] = done
            item["updatedAt"] = now_iso
        task["subtaskCount"] = len(subtasks)
        task["completedSubtaskCount"] = len(subtasks) if done else 0
    return task


def _delete_task(snapshot: dict[str, Any], task_id: str) -> dict[str, Any]:
    index = _find_task_index(snapshot["tasks"], task_id)
    if index < 0:
        raise HTTPException(status_code=404, detail=f"task not found: {task_id}")
    task = snapshot["tasks"].pop(index)
    snapshot["subtasks"] = [
        item
        for item in snapshot["subtasks"]
        if str(item.get("taskId") or "").strip() != task_id
    ]
    return task


def _create_project(snapshot: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    name = str(payload.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="create_project requires name")
    now_iso = _now_iso()
    project = {
        "id": str(payload.get("projectId") or payload.get("id") or f"todo-project:{uuid4().hex}"),
        "name": name,
        "iconCodePoint": int(payload.get("iconCodePoint") or 0xE8F9),
        "colorValue": int(payload.get("colorValue") or 0xFF7BAAF7),
        "description": str(payload.get("description") or "").strip(),
        "sortOrder": len(snapshot["projects"]),
        "archived": False,
        "createdAt": now_iso,
        "updatedAt": now_iso,
    }
    snapshot["projects"].append(project)
    return project


def _update_project(snapshot: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    index = _find_project_index(
        snapshot["projects"],
        str(payload.get("projectId") or payload.get("id") or ""),
        str(payload.get("name") or ""),
    )
    if index < 0:
        raise HTTPException(status_code=404, detail="project not found")
    project = snapshot["projects"][index]
    project["updatedAt"] = _now_iso()
    if "name" in payload:
        name = str(payload.get("name") or "").strip()
        if not name:
            raise HTTPException(status_code=400, detail="update_project name cannot be empty")
        project["name"] = name
    if "description" in payload:
        project["description"] = str(payload.get("description") or "").strip()
    if "archived" in payload:
        project["archived"] = payload.get("archived") is True
    if "iconCodePoint" in payload and payload.get("iconCodePoint") is not None:
        project["iconCodePoint"] = int(payload["iconCodePoint"])
    if "colorValue" in payload and payload.get("colorValue") is not None:
        project["colorValue"] = int(payload["colorValue"])
    return project


def _apply_action(snapshot: dict[str, Any], action_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    if action_type == "create_task":
        task = _create_task(snapshot, payload)
        return {"task": task}
    if action_type == "update_task":
        task = _update_task(snapshot, payload)
        return {"task": task}
    if action_type == "complete_task":
        task_id = str(payload.get("taskId") or payload.get("id") or "").strip()
        if not task_id:
            raise HTTPException(status_code=400, detail="complete_task requires taskId")
        task = _set_task_done(snapshot, task_id, True)
        return {"task": task}
    if action_type == "reopen_task":
        task_id = str(payload.get("taskId") or payload.get("id") or "").strip()
        if not task_id:
            raise HTTPException(status_code=400, detail="reopen_task requires taskId")
        task = _set_task_done(snapshot, task_id, False)
        return {"task": task}
    if action_type == "delete_task":
        task_id = str(payload.get("taskId") or payload.get("id") or "").strip()
        if not task_id:
            raise HTTPException(status_code=400, detail="delete_task requires taskId")
        task = _delete_task(snapshot, task_id)
        return {"task": task}
    if action_type == "create_project":
        project = _create_project(snapshot, payload)
        return {"project": project}
    if action_type == "update_project":
        project = _update_project(snapshot, payload)
        return {"project": project}
    if action_type == "archive_project":
        project = _update_project(
            snapshot,
            {
                **payload,
                "archived": payload.get("archived") is not False,
            },
        )
        return {"project": project}
    if action_type == "replace_subtasks":
        task_id = str(payload.get("taskId") or payload.get("id") or "").strip()
        if not task_id:
            raise HTTPException(status_code=400, detail="replace_subtasks requires taskId")
        index = _find_task_index(snapshot["tasks"], task_id)
        if index < 0:
            raise HTTPException(status_code=404, detail=f"task not found: {task_id}")
        task = snapshot["tasks"][index]
        raw_subtasks = payload.get("subtasks")
        if not isinstance(raw_subtasks, list):
            raise HTTPException(status_code=400, detail="replace_subtasks requires subtasks")
        subtasks = _replace_subtasks(
            snapshot,
            task,
            [item for item in raw_subtasks if isinstance(item, dict)],
        )
        task["updatedAt"] = _now_iso()
        _sync_task_completion_from_subtasks(task, subtasks)
        return {"task": task, "subtasks": subtasks}
    raise HTTPException(status_code=400, detail=f"unsupported todo action: {action_type}")


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

    @router.post('/api/todo/actions')
    async def issue_todo_action(body: dict) -> dict:
        action_type = str(body.get("type") or "").strip()
        if action_type not in _ACTION_TYPES:
            raise HTTPException(status_code=400, detail=f"unsupported todo action: {action_type}")
        payload = body.get("payload")
        if not isinstance(payload, dict):
            raise HTTPException(status_code=400, detail="payload is required")

        current = context.todo_store.load_snapshot()
        current_snapshot = _normalize_snapshot(
            None if current is None else current.get("snapshot")
        )
        result = _apply_action(current_snapshot, action_type, payload)
        saved = context.todo_store.save_snapshot(current_snapshot)
        await context.events_bus.publish(
            'todo.snapshot_changed',
            {
                'revision': saved['revision'],
                'updatedAt': saved['updatedAt'],
                'clientInstanceId': str(body.get('clientInstanceId') or '').strip(),
                'requestId': str(body.get('requestId') or '').strip(),
                'source': str(body.get('source') or '').strip(),
                'action': action_type,
            },
        )
        return {
            'ok': True,
            'type': action_type,
            'revision': saved['revision'],
            'updatedAt': saved['updatedAt'],
            'snapshot': saved['snapshot'],
            **result,
        }

    return router
