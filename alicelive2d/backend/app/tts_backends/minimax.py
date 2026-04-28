"""MiniMax TTS backend for AliceClaw Live2D."""
from __future__ import annotations

import binascii
import json
import urllib.error
import urllib.request

from .base import TtsBackend


def build_minimax_headers(api_key: str) -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }


class MiniMaxTtsBackend(TtsBackend):
    """MiniMax Text-to-Audio v2 backend.
    
    API: POST https://api.minimaxi.com/v1/t2a_v2
    """

    error_label = "minimax-tts"
    default_model = "speech-2.8-hd"
    default_voice = "wumei_yujie"
    default_speed = 0.9
    default_vol = 1.0
    default_pitch = 0

    def _apply_overrides(self, tts: dict, overrides: dict | None = None) -> dict:
        merged = dict(tts)
        if not overrides:
            return merged

        for key in ("apiKey", "baseUrl", "model", "voice", "speed", "vol", "pitch",
                    "outputFormat", "sampleRate", "bitrate", "audioFormat"):
            value = overrides.get(key)
            if value is not None and value != "":
                merged[key] = value

        return merged

    def _build_payload(self, text: str, tts: dict) -> dict:
        voice_setting = {
            "voice_id": str(tts.get("voice") or self.default_voice),
            "speed": float(tts.get("speed") or self.default_speed),
            "vol": float(tts.get("vol") or self.default_vol),
            "pitch": int(tts.get("pitch") or self.default_pitch),
        }

        audio_setting = {
            "sample_rate": int(tts.get("sampleRate") or 32000),
            "bitrate": int(tts.get("bitrate") or 128000),
            "format": str(tts.get("audioFormat") or "mp3"),
            "channel": 1,
        }

        return {
            "model": str(tts.get("model") or self.default_model),
            "text": text,
            "stream": False,
            "output_format": str(tts.get("outputFormat") or "hex"),
            "voice_setting": voice_setting,
            "audio_setting": audio_setting,
        }

    def synthesize(self, text: str, overrides: dict | None = None) -> tuple[bytes, str]:
        tts = self._apply_overrides(self.config, overrides)

        if not tts.get("enabled", True):
            raise RuntimeError("tts is disabled")
        if not str(text or "").strip():
            raise ValueError("text is required")

        base_url = str(tts.get("baseUrl") or "https://api.minimaxi.com").rstrip("/")
        api_key = str(tts.get("apiKey") or "").strip()
        if not api_key:
            raise ValueError(f"{self.error_label} requires apiKey")

        body = json.dumps(self._build_payload(text, tts), ensure_ascii=False).encode("utf-8")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request(
            f"{base_url}/v1/t2a_v2",
            data=body,
            method="POST",
            headers=build_minimax_headers(api_key),
        )

        try:
            with opener.open(req, timeout=120) as resp:
                content_type = (resp.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
                data = resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{self.error_label} HTTP {exc.code}: {detail[:500]}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"{self.error_label} unavailable: {exc}") from exc

        # MiniMax returns JSON with hex-encoded audio
        if content_type == "application/json" or content_type.startswith("application/json"):
            try:
                obj = json.loads(data.decode("utf-8", errors="replace"))
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"{self.error_label} failed to parse JSON: {exc}") from exc

            audio_data = obj.get("data", {}).get("audio")
            if not audio_data:
                raise RuntimeError(f"{self.error_label} no audio in response: {list(obj.keys())}")

            # Decode hex to bytes
            try:
                audio_bytes = binascii.unhexlify(audio_data)
            except (binascii.Error, ValueError) as exc:
                raise RuntimeError(f"{self.error_label} failed to decode hex audio: {exc}") from exc

            audio_format = obj.get("extra_info", {}).get("audio_format", "mp3")
            mime_type = f"audio/{audio_format}" if audio_format else "audio/mpeg"
            return audio_bytes, mime_type

        # If returned as raw audio binary
        if content_type.startswith("audio/"):
            return data, content_type

        raise RuntimeError(f"{self.error_label} unexpected Content-Type: {content_type}")
