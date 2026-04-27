from __future__ import annotations

import json

from ..config import get_chat_config
from ..manifest import collect_model_stage_capabilities


def extract_text_from_message_content(content: object) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item.get("content"), str):
                    parts.append(item["content"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(part.strip() for part in parts if part and part.strip()).strip()
    return ""


def build_stage_prompt(request) -> str:
    model_config = request.model_config or {}
    if not model_config:
        return ""
    capabilities = collect_model_stage_capabilities(model_config)
    expression_names = [item["name"] for item in capabilities["expressions"] if item.get("name")]
    motion_tokens = []
    for item in capabilities["motions"]:
        group = item.get("group")
        index = item.get("index")
        if group is None:
            continue
        group = str(group)
        name = str(item.get("name") or "").strip()
        # If the group name is empty, expose a simplified token "<index>"
        # so the assistant emits [motion:<index>] instead of [motion::<index>].
        if group.strip() == "":
            # Empty group: directive format is [motion:Index]. Still show the file-stem name for readability.
            if name:
                motion_tokens.append(f"{index} ({name})")
            else:
                motion_tokens.append(str(index))
        else:
            # Prefer a human-meaningful name (derived from motion file stem) when available.
            # Keep Index as the canonical routing key.
            if name:
                motion_tokens.append(f"{group}:{index} ({name})")
            else:
                motion_tokens.append(f"{group}:{index}")
    lines = [
        "Stage directive rules:",
        "- You may embed inline stage directives in square brackets.",
        "- Supported directive formats:",
        "  - [expr:ExpressionName]",
        "  - [motion:GroupName:Index]",
        "  - If GroupName is empty, use [motion:Index] (no double colon).",
        "- Use English-only directive names. Never use Chinese tags like [表情:...] or [动作:...].",
        "- Place directives at natural sentence boundaries.",
        "- Keep directives sparse and meaningful. Do not overuse them.",
        "- The visible spoken content must still read naturally after directives are removed.",
        "- Do not invent extra directive formats.",
    ]
    if expression_names:
        lines.append(f"Available expressions: {', '.join(expression_names)}")
    if motion_tokens:
        lines.append(f"Available motions: {', '.join(motion_tokens)}")
    return "\n".join(lines)


def build_system_prompt(request) -> str:
    base_prompt = get_chat_config().get("systemPrompt") or "You are Lunaria, the speaking soul of a Live2D desktop character. Reply conversationally, warmly, and concisely in Chinese unless the user asks otherwise."
    prompt_parts = [base_prompt]
    injection_items = get_chat_config().get("promptInjections") or []
    if isinstance(injection_items, dict):
        injection_items = [injection_items]
    if isinstance(injection_items, list):
        prepend_parts: list[str] = []
        append_parts: list[str] = []
        for item in injection_items:
            if isinstance(item, str):
                text = item.strip()
                if text:
                    append_parts.append(text)
                continue
            if not isinstance(item, dict):
                continue
            if item.get("enabled") is False:
                continue
            text = str(item.get("content") or item.get("text") or "").strip()
            if not text:
                continue
            position = str(item.get("position") or "append").strip().lower()
            if position == "prepend":
                prepend_parts.append(text)
            else:
                append_parts.append(text)
        if prepend_parts:
            prompt_parts = [*prepend_parts, *prompt_parts]
        if append_parts:
            prompt_parts.extend(append_parts)
    stage_prompt = build_stage_prompt(request)
    if stage_prompt:
        prompt_parts.append(stage_prompt)
    if request.agent:
        prompt_parts.append(f"Preferred OpenClaw agent: {request.agent}")
    if request.session_name:
        prompt_parts.append(f"Preferred Lunaria session: {request.session_name}")
    return "\n\n".join(part for part in prompt_parts if part and part.strip())


LIVE2D_INIT_VERSION = 2


def build_live2d_init_message(request) -> str:
    """Build a one-shot initialization message for bridge-style chat providers.

    Some bridge providers do not accept an explicit system prompt injection per
    request. We send this message once per sessionKey to teach the agent the
    Live2D inline directive format and to persist the spec into LIVE2D.md for
    future reference.
    """

    system_prompt = build_system_prompt(request)
    lines = [
        f"[[LIVE2D_INIT v{LIVE2D_INIT_VERSION}]]",
        "下面这一段是初始化规则（system prompt 等价物），不是用户问题。请不要直接回复这一段内容。",
        "",
        system_prompt,
        "",
        "你接下来会看到用户的真实消息；请只回复用户消息本身，并在正文中按规则穿插舞台指令。",
        "",
        "(Optional persistence, best-effort):",
        "- If LIVE2D.md does not exist, you may create it and write the Live2D directive rules + available expressions/motions.",
        "- If LIVE2D.md already exists, do NOT rewrite it unless you need to upgrade spec_version.",
        "- In this session, do not repeatedly re-read or re-write LIVE2D.md; read/write at most once per session.",
        "- If AGENTS.md exists, you may append a single note pointing to LIVE2D.md (only if not already present).",
        f"[[/LIVE2D_INIT v{LIVE2D_INIT_VERSION}]]",
    ]
    return "\n".join([line for line in lines if line is not None])


def truncate_for_log(value: object, max_chars: int = 1200) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    text = str(text)
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + f" …(+{len(text) - max_chars} chars)"


def log_chat_request(provider: dict, request, system_prompt: str) -> None:
    payload = {
        "provider": provider.get("id") or provider.get("name") or "unknown",
        "agent": request.agent or "",
        "session": request.session_name or "",
        "modelId": (request.model_config or {}).get("id") or "",
        "userText": request.user_text,
        "systemPrompt": system_prompt,
    }
    print(f"[chat.request] {truncate_for_log(payload)}")


def log_chat_response(provider: dict, *, reply: str, state: str = "final", streamed: bool = False) -> None:
    payload = {
        "provider": provider.get("id") or provider.get("name") or "unknown",
        "streamed": streamed,
        "state": state,
        "reply": reply,
    }
    print(f"[chat.response] {truncate_for_log(payload)}")


def build_openai_headers(api_key: str | None) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return headers
