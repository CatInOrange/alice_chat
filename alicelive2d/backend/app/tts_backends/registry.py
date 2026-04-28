from __future__ import annotations

from ..config import get_tts_provider_config
from .base import TtsBackend
from .edge import EdgeTtsBackend
from .gpt_sovits import GptSoVitsBackend
from .minimax import MiniMaxTtsBackend
from .openai_compatible import OpenAICompatibleTtsBackend

TTS_BACKEND_REGISTRY: dict[str, type[TtsBackend]] = {
    'edge-tts': EdgeTtsBackend,
    'openai-compatible': OpenAICompatibleTtsBackend,
    'gpt-sovits': GptSoVitsBackend,
    'minimax-tts': MiniMaxTtsBackend,
}


def create_tts_backend(config: dict | None = None, provider_id: str | None = None) -> TtsBackend:
    # If config is provided, use it directly (for backwards compatibility)
    # Otherwise, resolve from the new structured config
    if config is not None:
        resolved = dict(config)
        provider = str(provider_id or resolved.get('provider') or 'edge-tts').strip()
    else:
        resolved = get_tts_provider_config(provider_id)
        provider = str(resolved.get('provider') or 'edge-tts').strip()

    backend_cls = TTS_BACKEND_REGISTRY.get(provider)
    if not backend_cls:
        raise ValueError(f'unsupported tts provider: {provider}')
    return backend_cls(resolved)
