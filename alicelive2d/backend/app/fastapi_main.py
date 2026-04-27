from __future__ import annotations

"""Uvicorn entrypoint for the FastAPI backend.

We keep this separate from `backend/app/main.py` so the legacy server can continue
working while the migration is in progress.

Usage (inside nix-shell):

    python -m backend.app.fastapi_main --host 0.0.0.0 --port 18080

"""

import argparse

import uvicorn

from .config import get_server_config
from .fastapi_app import create_app


def main() -> None:
    parser = argparse.ArgumentParser(description="Lunaria (FastAPI)")
    server = get_server_config()
    parser.add_argument("--host", default=server.get("host") or "0.0.0.0")
    parser.add_argument("--port", type=int, default=int(server.get("port") or 18080))
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload (dev only)")
    args = parser.parse_args()

    app = create_app()

    uvicorn.run(
        app,
        host=str(args.host),
        port=int(args.port),
        reload=bool(args.reload),
        log_level="info",
        timeout_keep_alive=86400,  # 24小时，与nginx超时一致
    )


if __name__ == "__main__":
    main()
