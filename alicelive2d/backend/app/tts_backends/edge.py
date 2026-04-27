from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path

from .base import TtsBackend


class EdgeTtsBackend(TtsBackend):
    def synthesize(self, text: str, overrides: dict | None = None) -> tuple[bytes, str]:
        tts = dict(self.config)
        if overrides:
            for key in ('voice', 'rate', 'pitch', 'volume'):
                if overrides.get(key) not in (None, ''):
                    tts[key] = overrides[key]
        if not tts.get('enabled', True):
            raise RuntimeError('tts is disabled')
        if not text.strip():
            raise ValueError('text is required')

        try:
            import edge_tts  # type: ignore
        except ModuleNotFoundError as exc:
            raise RuntimeError("Python package 'edge-tts' is missing. Run this project inside nix-shell.") from exc

        async def _run() -> bytes:
            communicate = edge_tts.Communicate(
                text=text,
                voice=str(tts.get('voice') or 'zh-CN-XiaoxiaoNeural'),
                rate=str(tts.get('rate') or '+0%'),
                pitch=str(tts.get('pitch') or '+0Hz'),
                volume=str(tts.get('volume') or '+0%'),
            )
            with tempfile.NamedTemporaryFile(suffix='.mp3', delete=False) as tmp:
                tmp_path = Path(tmp.name)
            try:
                await communicate.save(str(tmp_path))
                return tmp_path.read_bytes()
            finally:
                tmp_path.unlink(missing_ok=True)

        return asyncio.run(_run()), 'audio/mpeg'
