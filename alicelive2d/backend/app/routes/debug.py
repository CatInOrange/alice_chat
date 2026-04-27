from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter

from ..config import ROOT

DEBUG_LOG_DIR = ROOT / 'debug_logs'
DEBUG_LOG_DIR.mkdir(parents=True, exist_ok=True)


def create_debug_router() -> APIRouter:
    router = APIRouter(prefix="/api/debug")

    @router.post("/webgl")
    async def report_webgl_debug(data: dict[str, Any]):
        """Receive WebGL debug info from frontend"""
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        filename = DEBUG_LOG_DIR / f"webgl_debug_{timestamp}.json"
        
        with open(filename, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": timestamp,
                "data": data
            }, f, ensure_ascii=False, indent=2)
        
        return {"status": "ok", "filename": str(filename)}

    @router.post("/model")
    async def report_model_debug(data: dict[str, Any]):
        """Receive model position debug info from frontend"""
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        filename = DEBUG_LOG_DIR / f"model_debug_{timestamp}.json"
        
        with open(filename, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": timestamp,
                "data": data
            }, f, ensure_ascii=False, indent=2)
        
        return {"status": "ok", "filename": str(filename)}

    @router.get("/test")
    async def test_debug():
        """Test endpoint to verify if code is running - creates a distinctive log file"""
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        filename = DEBUG_LOG_DIR / f"TEST_Y_OFFSET_CODE_RAN_{timestamp}.json"
        
        with open(filename, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": timestamp,
                "message": "TEST Y-OFFSET CODE RAN SUCCESSFULLY",
                "source": "test_endpoint"
            }, f, ensure_ascii=False, indent=2)
        
        return {"status": "ok", "filename": str(filename)}

    @router.get("/logs")
    async def list_debug_logs():
        """List all debug log files"""
        logs = sorted(DEBUG_LOG_DIR.glob("webgl_debug_*.json"), reverse=True)
        return {
            "logs": [
                {
                    "filename": log.name,
                    "size": log.stat().st_size,
                    "modified": log.stat().st_mtime
                }
                for log in logs[:20]
            ]
        }

    @router.get("/logs/{filename}")
    async def get_debug_log(filename: str):
        """Get specific debug log content"""
        filepath = DEBUG_LOG_DIR / filename
        if not filepath.exists() or ".." in filename:
            return {"error": "Not found"}
        with open(filepath, "r", encoding="utf-8") as f:
            return json.load(f)

    @router.post("/frontend-error")
    async def report_frontend_error(data: dict[str, Any]):
        """Receive frontend fetch/connection error reports from the browser"""
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        filename = DEBUG_LOG_DIR / f"frontend_error_{timestamp}.json"

        with open(filename, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": timestamp,
                **data,
            }, f, ensure_ascii=False, indent=2)

        return {"status": "ok", "filename": str(filename)}

    return router
