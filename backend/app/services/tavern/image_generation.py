from __future__ import annotations

import base64
import json
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen


@dataclass(slots=True)
class TavernImageGenerationResult:
    prompt: str
    image_url: str
    provider_meta: dict[str, Any]


class TavernImagePromptRefiner:
    def __init__(self, *, text_provider_config: dict[str, Any], model_client_cls: type):
        self.text_provider_config = dict(text_provider_config or {})
        self.model_client_cls = model_client_cls

    def refine(self, *, character_name: str, assistant_text: str) -> str:
        source = assistant_text.strip()
        if not source:
            raise ValueError('latest assistant message is empty')
        client = self.model_client_cls(self.text_provider_config)
        response = client.generate(
            messages=[
                {
                    'role': 'system',
                    'content': (
                        '你是图像提示词整理器。'
                        '请把给定的剧情回复提炼成一段适合中文图像模型的单段场景描述。'
                        '要求：保留当前场景、人物动作、表情、服饰、环境、氛围与镜头感；'
                        '避免对话体、避免解释、避免分点；'
                        '默认写实唯美风格；'
                        '输出纯提示词正文，不要前后缀。'
                    ),
                },
                {
                    'role': 'user',
                    'content': f'角色：{character_name}\n\n最近一条 assistant 回复：\n{source}',
                },
            ]
        )
        prompt = response.text.strip()
        if not prompt:
            raise ValueError('image prompt refinement returned empty text')
        return prompt


class TavernImageGenerator:
    def __init__(self, *, provider_config: dict[str, Any], uploads_dir: Path):
        self.provider_config = dict(provider_config or {})
        self.uploads_dir = uploads_dir

    def generate(
        self,
        *,
        prompt: str,
        reference_image_path: Path,
        chat_id: str,
    ) -> TavernImageGenerationResult:
        provider_type = str(self.provider_config.get('type') or 'openai-images').strip() or 'openai-images'
        if provider_type != 'openai-images':
            raise ValueError(f'unsupported tavern image provider type: {provider_type}')
        return self._generate_openai_images(
            prompt=prompt,
            reference_image_path=reference_image_path,
            chat_id=chat_id,
        )

    def _generate_openai_images(
        self,
        *,
        prompt: str,
        reference_image_path: Path,
        chat_id: str,
    ) -> TavernImageGenerationResult:
        endpoint = str(self.provider_config.get('endpoint') or '').strip()
        if not endpoint:
            base_url = str(self.provider_config.get('baseUrl') or '').rstrip('/')
            if not base_url:
                raise ValueError('tavern image provider missing endpoint/baseUrl')
            endpoint = f'{base_url}/images/generations'
        model = str(self.provider_config.get('model') or '').strip()
        if not model:
            raise ValueError('tavern image provider missing model')
        api_key = str(self.provider_config.get('apiKey') or '').strip()
        if not api_key:
            raise ValueError('tavern image provider missing apiKey')

        body: dict[str, Any] = {
            'model': model,
            'prompt': prompt,
            'size': str(self.provider_config.get('size') or '1024x1024'),
        }
        quality = str(self.provider_config.get('quality') or '').strip()
        if quality:
            body['quality'] = quality
        background = str(self.provider_config.get('background') or '').strip()
        if background:
            body['background'] = background
        image_payload = self._encode_reference_image(reference_image_path)
        if image_payload is not None:
            body['image'] = image_payload
        count = int(self.provider_config.get('count') or 1)
        if count > 1:
            body['n'] = count

        request = Request(
            endpoint,
            data=json.dumps(body).encode('utf-8'),
            headers={
                'Content-Type': 'application/json',
                'Authorization': f'Bearer {api_key}',
            },
            method='POST',
        )
        timeout = max(10, int(float(self.provider_config.get('timeoutSeconds') or 180)))
        with urlopen(request, timeout=timeout) as resp:
            raw = resp.read().decode('utf-8', errors='ignore')
        payload = json.loads(raw or '{}')
        image_bytes = self._extract_image_bytes(payload)
        if image_bytes is None:
            raise ValueError('image provider returned no image payload')

        rel = Path('tavern') / 'generated' / f'{chat_id}_{uuid.uuid4().hex[:10]}.png'
        target = (self.uploads_dir / rel).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(image_bytes)
        return TavernImageGenerationResult(
            prompt=prompt,
            image_url=f'/uploads/{rel.as_posix()}',
            provider_meta={
                'providerType': 'openai-images',
                'provider': str(self.provider_config.get('provider') or '').strip() or 'unknown',
                'model': model,
            },
        )

    def _encode_reference_image(self, path: Path) -> str | None:
        if not path.exists() or not path.is_file():
            return None
        mime = 'image/png'
        suffix = path.suffix.lower()
        if suffix in {'.jpg', '.jpeg'}:
            mime = 'image/jpeg'
        elif suffix == '.webp':
            mime = 'image/webp'
        encoded = base64.b64encode(path.read_bytes()).decode('ascii')
        return f'data:{mime};base64,{encoded}'

    def _extract_image_bytes(self, payload: dict[str, Any]) -> bytes | None:
        data = payload.get('data')
        if not isinstance(data, list) or not data:
            return None
        first = data[0] or {}
        if isinstance(first, dict):
            b64 = first.get('b64_json') or first.get('b64')
            if isinstance(b64, str) and b64.strip():
                return base64.b64decode(b64)
            url = first.get('url')
            if isinstance(url, str) and url.strip():
                req = Request(url.strip(), headers={'User-Agent': 'AliceChat Tavern Image/1.0'})
                with urlopen(req, timeout=60) as resp:
                    return resp.read()
        return None
