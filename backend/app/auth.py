from __future__ import annotations

from fastapi import Header, HTTPException

from .config import load_config


async def verify_app_password(
    x_alicechat_password: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    auth_config = load_config().get('auth') or {}
    expected = str(auth_config.get('appAccessPassword') or '').strip()
    if not expected:
        return

    provided = str(x_alicechat_password or '').strip()
    if not provided and authorization:
        value = str(authorization).strip()
        if value.lower().startswith('bearer '):
            provided = value[7:].strip()

    if provided != expected:
        raise HTTPException(status_code=401, detail='invalid app password')
