from __future__ import annotations

import imghdr
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from ..app_context import AppContext
from ..auth import verify_app_password

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



def create_media_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

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
