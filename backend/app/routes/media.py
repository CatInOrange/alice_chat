from __future__ import annotations

import imghdr
import mimetypes
import os
import time
import uuid
from pathlib import Path
from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse

from ..app_context import AppContext
from ..auth import verify_app_password
from ..config import ROOT
from ..web.helpers import build_protected_media_url

_IMAGE_EXT_BY_MIME = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/gif': '.gif',
}

_IMAGE_KIND_BY_IMGHDR = {
    'jpeg': ('image/jpeg', '.jpg'),
    'png': ('image/png', '.png'),
    'webp': ('image/webp', '.webp'),
    'gif': ('image/gif', '.gif'),
}


def _normalize_image_attachment(*, file_id: str, url: str, filename: str, mime_type: str, size: int) -> dict:
    return {
        'id': file_id,
        'kind': 'image',
        'mimeType': mime_type,
        'name': filename,
        'filename': filename,
        'url': url,
        'size': size,
        'status': 'ready',
        'meta': {},
    }



def _is_within(path: Path, base: Path) -> bool:
    try:
        path.resolve().relative_to(base.resolve())
        return True
    except Exception:
        return False


def _resolve_allowed_media_path(raw_path: str, *, context: AppContext) -> tuple[Path, str]:
    value = str(raw_path or '').strip()
    if not value:
        raise HTTPException(status_code=400, detail='missing media path')
    lower = value.lower()
    if lower.startswith('http://') or lower.startswith('https://'):
        raise HTTPException(status_code=400, detail='remote url is not allowed for media file endpoint')

    path = Path(os.path.expanduser(value)).resolve()
    allowed_roots = [
        context.uploads_dir.resolve(),
        (ROOT.parent / 'media').resolve(),
    ]
    if not any(_is_within(path, root) for root in allowed_roots):
        raise HTTPException(status_code=403, detail='media path is outside allowed directories')
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail='media file not found')

    mime_type, _ = mimetypes.guess_type(str(path))
    return path, mime_type or 'application/octet-stream'


def create_media_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.get('/api/media/file')
    async def media_file(path: str = Query(..., min_length=1)):
        resolved_path, media_type = _resolve_allowed_media_path(path, context=context)
        return FileResponse(resolved_path, media_type=media_type, filename=resolved_path.name)

    @router.post('/api/media/upload')
    async def upload_media(file: UploadFile = File(...)) -> dict:
        raw = await file.read()
        if not raw:
            raise HTTPException(status_code=400, detail='empty file')
        if len(raw) > 20 * 1024 * 1024:
            raise HTTPException(status_code=413, detail='file too large')

        detected = imghdr.what(None, h=raw)
        if detected not in _IMAGE_KIND_BY_IMGHDR:
            raise HTTPException(status_code=400, detail='only image upload is supported for now')

        mime_type, ext = _IMAGE_KIND_BY_IMGHDR[detected]
        original_name = (file.filename or '').strip()
        if original_name and '.' in original_name:
            candidate_ext = Path(original_name).suffix.lower()
            if candidate_ext in _IMAGE_EXT_BY_MIME.values():
                ext = candidate_ext

        file_id = f'att_{uuid.uuid4().hex[:12]}'
        year_month = time.strftime('%Y/%m')
        media_dir = context.uploads_dir / 'media' / year_month
        media_dir.mkdir(parents=True, exist_ok=True)
        stored_name = f'{file_id}{ext}'
        stored_path = media_dir / stored_name
        stored_path.write_bytes(raw)

        url = f'/uploads/media/{year_month}/{stored_name}'
        attachment = _normalize_image_attachment(
            file_id=file_id,
            url=url,
            filename=original_name or stored_name,
            mime_type=mime_type,
            size=len(raw),
        )
        return {'ok': True, 'attachment': attachment}

    return router
