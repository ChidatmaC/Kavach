"""Nemotron via the hosted NIM OpenAI-compatible API (D3, D4).

Every model step returns JSON validated against a schema in shared/schemas/. Invalid output is
retried once; after that the caller's deterministic fallback is used (spec 7). Without NIM_API_KEY
every call returns None immediately, so each workflow runs on its fallback path.
"""
from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from typing import Any

from .config import PROMPTS_DIR, settings
from .log import log
from .schemas import SchemaError, validate


@dataclass
class ModelSet:
    """Model ids per tier. Filled from the NAT `llms:` config when NAT is loaded, else from env."""
    fast: str
    writer: str
    base_url: str
    api_key: str

    @classmethod
    def from_env(cls) -> "ModelSet":
        s = settings()
        return cls(fast=s.model_fast, writer=s.model_writer, base_url=s.nim_base_url, api_key=s.nim_api_key)

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)


_prompt_cache: dict[str, str] = {}


def prompt(name: str, **vars: Any) -> str:
    """Load shared/prompts/<name>.md and fill {placeholders}. APP_DISPLAY_NAME is always available."""
    if name not in _prompt_cache:
        _prompt_cache[name] = (PROMPTS_DIR / f"{name}.md").read_text()
    text = _prompt_cache[name]
    vars.setdefault("app_name", settings().app_name)
    for k, v in vars.items():
        text = text.replace("{" + k + "}", v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
    return text


def _thinking_body() -> dict:
    """Nemotron 3.5 models reason by default, which costs latency and can leave `content` empty
    when reasoning uses the token budget. NIM_THINKING=off (default) disables it per request."""
    if os.environ.get("NIM_THINKING", "off").lower() == "off":
        return {"chat_template_kwargs": {"enable_thinking": False}}
    return {}


def _extract_json(text: str) -> Any:
    text = re.sub(r"(?s)<think>.*?</think>", "", text or "").strip()
    fence = re.search(r"(?s)```(?:json)?\s*(.*?)```", text)
    if fence:
        text = fence.group(1)
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    if start < 0:
        raise ValueError("no JSON in model output")
    depth, in_str, esc = 0, False, False
    open_ch = text[start]
    close_ch = "}" if open_ch == "{" else "]"
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return json.loads(text[start : i + 1])
    raise ValueError("unterminated JSON")


class LLM:
    def __init__(self, models: ModelSet):
        self.models = models
        self._client = None

    def _get_client(self):
        if self._client is None:
            from openai import AsyncOpenAI

            self._client = AsyncOpenAI(api_key=self.models.api_key, base_url=self.models.base_url,
                                       timeout=8.0, max_retries=0)
        return self._client

    async def json(self, tier: str, system: str, user: str, schema: str, *, workflow: str,
                   max_tokens: int = 400, temperature: float = 0.2, timeout: float = 8.0) -> dict | None:
        """One schema-checked model step: try, retry once with the validation error, else None."""
        if not self.models.enabled:
            return None
        model = self.models.fast if tier == "fast" else self.models.writer
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]
        for attempt in (1, 2):
            t0 = time.perf_counter()
            try:
                res = await self._get_client().chat.completions.create(
                    model=model, messages=messages, temperature=temperature, max_tokens=max_tokens, timeout=timeout,
                    extra_body=_thinking_body(),
                )
                raw = res.choices[0].message.content or ""
                obj = validate(schema, _extract_json(raw))
                log("model_step", workflow=workflow, model=model, outcome="ok",
                    latency_ms=int((time.perf_counter() - t0) * 1000))
                return obj
            except (SchemaError, ValueError) as e:
                log("model_step", workflow=workflow, model=model, outcome=f"invalid_try{attempt}",
                    error=type(e).__name__, latency_ms=int((time.perf_counter() - t0) * 1000))
                messages.append({"role": "user", "content": f"That was not valid. Error: {str(e)[:200]}. Reply with only the JSON object."})
            except Exception as e:  # noqa: BLE001 - provider/network errors -> fallback
                log("model_step", workflow=workflow, model=model, outcome="error", error=type(e).__name__,
                    latency_ms=int((time.perf_counter() - t0) * 1000))
                return None
        return None

    async def vision_text(self, image_base64: str, *, workflow: str) -> str:
        """Screenshot text recognition via a NIM vision model (MODEL_VISION). Returns "" if unavailable."""
        s = settings()
        if not (self.models.enabled and s.model_vision and image_base64):
            return ""
        try:
            res = await self._get_client().chat.completions.create(
                model=s.model_vision, max_tokens=500, temperature=0.0, timeout=8.0, extra_body=_thinking_body(),
                messages=[{"role": "user", "content": [
                    {"type": "text", "text": "Transcribe all text in this screenshot exactly. Output only the text."},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_base64}"}},
                ]}],
            )
            return (res.choices[0].message.content or "").strip()
        except Exception as e:  # noqa: BLE001
            log("vision_fallback", workflow=workflow, error=type(e).__name__)
            return ""
