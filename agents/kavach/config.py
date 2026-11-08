"""Settings for the agent service. Values come from the environment, then the repo-root .env."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

AGENTS_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = AGENTS_DIR.parent
SHARED_DIR = REPO_ROOT / "shared"
SCHEMAS_DIR = SHARED_DIR / "schemas"
PROMPTS_DIR = SHARED_DIR / "prompts"
CONFIGS_DIR = AGENTS_DIR / "configs"
GUARDRAILS_DIR = AGENTS_DIR / "guardrails"

# Real environment wins over .env (so tests can point at another database).
load_dotenv(REPO_ROOT / ".env", override=False)


def _bool(v: str | None, default: bool = False) -> bool:
    if v is None or v == "":
        return default
    return v.strip().lower() in {"1", "true", "yes", "on"}


def _service_token(role: str) -> str:
    env = os.environ.get(f"SPACETIME_TOKEN_{role.upper()}", "")
    if env:
        return env
    f = REPO_ROOT / ".spacetime-tokens.json"
    if f.exists():
        try:
            return json.loads(f.read_text()).get(role, "")
        except (OSError, ValueError):
            return ""
    return ""


@dataclass(frozen=True)
class Settings:
    app_name: str = field(default_factory=lambda: os.environ.get("APP_DISPLAY_NAME", "") or "Kavach")
    spacetime_uri: str = field(default_factory=lambda: os.environ.get("SPACETIME_URI", "http://127.0.0.1:3000").rstrip("/"))
    spacetime_db: str = field(default_factory=lambda: os.environ.get("SPACETIME_DB_NAME", "kavach"))
    agents_token: str = field(default_factory=lambda: _service_token("agents"))
    nim_api_key: str = field(default_factory=lambda: os.environ.get("NIM_API_KEY", ""))
    nim_base_url: str = field(default_factory=lambda: os.environ.get("NIM_BASE_URL", "https://integrate.api.nvidia.com/v1"))
    model_fast: str = field(default_factory=lambda: os.environ.get("MODEL_FAST", "nvidia/nemotron-3.5-lightning-30b-a3b"))
    model_writer: str = field(default_factory=lambda: os.environ.get("MODEL_WRITER", "nvidia/nemotron-3.5-super-vl-120b-a12b"))
    model_embed: str = field(default_factory=lambda: os.environ.get("MODEL_EMBED", "nvidia/nemotron-3.5-embed-1b"))
    model_vision: str = field(default_factory=lambda: os.environ.get("MODEL_VISION", ""))
    service_token: str = field(default_factory=lambda: os.environ.get("AGENT_SERVICE_TOKEN", ""))
    demo_mode: bool = field(default_factory=lambda: _bool(os.environ.get("DEMO_MODE")))
    run_timeout_s: float = field(default_factory=lambda: float(os.environ.get("AGENT_RUN_TIMEOUT_S", "20")))
    max_tool_calls: int = 6
    apns_key_id: str = field(default_factory=lambda: os.environ.get("APNS_KEY_ID", ""))
    apns_team_id: str = field(default_factory=lambda: os.environ.get("APNS_TEAM_ID", ""))
    apns_key_p8: str = field(default_factory=lambda: os.environ.get("APNS_KEY_P8", ""))
    apns_topic: str = field(default_factory=lambda: os.environ.get("APNS_TOPIC", ""))
    apns_sandbox: bool = field(default_factory=lambda: _bool(os.environ.get("APNS_SANDBOX"), True))
    use_nat: bool = field(default_factory=lambda: _bool(os.environ.get("KAVACH_USE_NAT"), True))
    task_poller: bool = field(default_factory=lambda: _bool(os.environ.get("AGENT_TASK_POLLER"), True))
    use_guardrails: bool = field(default_factory=lambda: _bool(os.environ.get("KAVACH_USE_GUARDRAILS"), True))

    @property
    def llm_enabled(self) -> bool:
        return bool(self.nim_api_key)


@lru_cache(maxsize=1)
def settings() -> Settings:
    return Settings()
