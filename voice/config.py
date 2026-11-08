"""Settings for the hotline, read from the environment (repo-root .env is loaded, never overriding).

Everything is read at call time so tests can change env vars per test.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

VOICE_DIR = Path(__file__).resolve().parent
REPO_ROOT = VOICE_DIR.parent
load_dotenv(REPO_ROOT / ".env", override=False)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return default


@dataclass(frozen=True)
class Config:
    app_name: str
    spacetime_uri: str
    db_name: str
    voice_token: str
    agent_url: str
    agent_token: str
    agent_timeout_s: float
    filler_after_s: float
    family_alert_wait_s: float

    @staticmethod
    def load() -> "Config":
        return Config(
            app_name=env("APP_DISPLAY_NAME") or "Kavach",
            spacetime_uri=env("SPACETIME_URI", "http://127.0.0.1:3000").rstrip("/"),
            db_name=env("SPACETIME_DB_NAME", "kavach"),
            voice_token=voice_token(),
            agent_url=env("AGENT_SERVICE_URL", "http://127.0.0.1:8088").rstrip("/"),
            agent_token=env("AGENT_SERVICE_TOKEN"),
            agent_timeout_s=env_float("VOICE_AGENT_TIMEOUT_S", 20.0),
            filler_after_s=env_float("VOICE_FILLER_AFTER_S", 0.7),
            family_alert_wait_s=env_float("VOICE_FAMILY_ALERT_WAIT_S", 4.0),
        )


def voice_token() -> str:
    """SPACETIME_TOKEN_VOICE, else the `voice` entry of the repo-root .spacetime-tokens.json."""
    tok = env("SPACETIME_TOKEN_VOICE")
    if tok:
        return tok
    path = REPO_ROOT / ".spacetime-tokens.json"
    if path.exists():
        try:
            return json.loads(path.read_text()).get("voice", "")
        except (OSError, ValueError):
            return ""
    return ""
