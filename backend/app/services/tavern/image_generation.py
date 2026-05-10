from __future__ import annotations

import base64
import json
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen


ReferenceImageSource = Path | str | None


def build_scene_image_generation_prompt(refined_prompt: str) -> str:
    prompt = refined_prompt.strip()
    if not prompt:
        raise ValueError('refined image prompt is empty')
    return (
        '请严格根据参考图确定女主角的脸、五官、发型、发色、年龄感与整体气质，不要擅自改变人脸辨识特征。'
        '如果文字描述与参考图外貌冲突，一律以参考图为准。'
        '画面中只允许出现女主角一人，不直接描写或生成其他人物。'
        '在此基础上，生成以下场景：'
        f'{prompt}'
    )


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
                        '要求：只描写女主角一人，把她当作唯一主体；'
                        '若原文出现男性或其他人物，只保留他们对气氛造成的痕迹或间接影响，不直接描写第二个人的外貌、身体、脸、动作或镜头；'
                        '保留当前场景、女主角的动作、表情、服饰、环境、氛围与镜头感；'
                        '描述要具体、清楚、可视化，优先写明构图、镜头距离、姿态、表情、光线、服饰细节与环境细节；'
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
        reference_image: ReferenceImageSource,
        chat_id: str,
    ) -> TavernImageGenerationResult:
        provider_type = str(self.provider_config.get('type') or 'openai-images').strip() or 'openai-images'
        if provider_type != 'openai-images':
            raise ValueError(f'unsupported tavern image provider type: {provider_type}')
        return self._generate_openai_images(
            prompt=prompt,
            reference_image=reference_image,
            chat_id=chat_id,
        )

    def _generate_openai_images(
        self,
        *,
        prompt: str,
        reference_image: ReferenceImageSource,
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
        }
        size = str(self.provider_config.get('size') or '').strip()
        if size and str(self.provider_config.get('provider') or '').strip().lower() not in {'xai', 'grok'}:
            body['size'] = size
        quality = str(self.provider_config.get('quality') or '').strip()
        if quality:
            body['quality'] = quality
        background = str(self.provider_config.get('background') or '').strip()
        if background:
            body['background'] = background
        image_payload = self._encode_reference_image(reference_image)
        if image_payload is not None:
            body['image'] = image_payload
        count = int(self.provider_config.get('count') or 1)
        if count > 1:
            body['n'] = count
        if str(self.provider_config.get('provider') or '').strip().lower() in {'xai', 'grok'}:
            body['response_format'] = 'b64_json'

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

    def _encode_reference_image(self, source: ReferenceImageSource) -> str | None:
        if source is None:
            return None
        raw_bytes: bytes | None = None
        suffix = '.png'
        if isinstance(source, Path):
            if not source.exists() or not source.is_file():
                return None
            raw_bytes = source.read_bytes()
            suffix = source.suffix.lower()
        else:
            value = str(source).strip()
            if not value:
                return None
            if value.startswith('http://') or value.startswith('https://'):
                req = Request(value, headers={'User-Agent': 'AliceChat Tavern Image/1.0'})
                with urlopen(req, timeout=60) as resp:
                    raw_bytes = resp.read()
                    content_type = resp.headers.get('Content-Type') or ''
                lowered = content_type.lower()
                if 'jpeg' in lowered or 'jpg' in lowered:
                    suffix = '.jpg'
                elif 'webp' in lowered:
                    suffix = '.webp'
                elif 'png' in lowered:
                    suffix = '.png'
            elif value.startswith('data:image/'):
                return value
            else:
                path = Path(value)
                if not path.exists() or not path.is_file():
                    return None
                raw_bytes = path.read_bytes()
                suffix = path.suffix.lower()
        if not raw_bytes:
            return None
        mime = 'image/png'
        if suffix in {'.jpg', '.jpeg'}:
            mime = 'image/jpeg'
        elif suffix == '.webp':
            mime = 'image/webp'
        encoded = base64.b64encode(raw_bytes).decode('ascii')
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
