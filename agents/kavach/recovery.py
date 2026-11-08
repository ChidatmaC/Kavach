"""Vetted recovery steps (D10). The LLM may only reword these; it never invents steps."""
from __future__ import annotations

from functools import lru_cache
from typing import Any

import yaml

from .config import SHARED_DIR

PRIORITY_RANK = {"now": 0, "today": 1, "this_week": 2}


@lru_cache(maxsize=1)
def library() -> dict[str, Any]:
    return yaml.safe_load((SHARED_DIR / "recovery_library.yaml").read_text())


def recovery_steps(shared_items: list[str], critical: bool = False) -> list[dict[str, str]]:
    """Ordered, de-duplicated steps for a set of shared items (same order as spacetime/src/recovery.ts)."""
    lib = library()
    keys: list[str] = []
    for item in shared_items:
        for k in lib["items"].get(item, []):
            if k not in keys:
                keys.append(k)
    if critical:
        for k in lib["critical_always"]:
            if k not in keys:
                keys.append(k)
    steps = [{"key": k, "priority": lib["steps"][k]["priority"], "text": lib["steps"][k]["text"], "i": i}
             for i, k in enumerate(keys)]
    steps.sort(key=lambda s: (PRIORITY_RANK[s["priority"]], s["i"]))
    return [{k: v for k, v in s.items() if k != "i"} for s in steps]


def step_text(key: str) -> str:
    return library()["steps"].get(key, {}).get("text", "")
