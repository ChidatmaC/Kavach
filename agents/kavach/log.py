"""Structured JSON logs: workflow, ids, latency, outcome. Never message contents (spec 12, 13)."""
from __future__ import annotations

import json
import logging
import sys
import time

_ALLOWED = {
    "workflow", "incident_id", "person_id", "drill_id", "verification_id", "latency_ms", "outcome",
    "tool_calls", "model", "path", "status", "error", "count", "verdict", "model_verdict", "stored_verdict",
    "evidence_count", "similarity_floor", "method", "rows", "refused", "intent", "source", "task_id", "enabled",
}

_logger = logging.getLogger("kavach")
if not _logger.handlers:
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(h)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False


def log(event: str, level: int = logging.INFO, **fields) -> None:
    """Emit one JSON line. Unknown keys are dropped so contents can't leak by accident."""
    rec = {"ts": round(time.time(), 3), "event": event}
    for k, v in fields.items():
        if k in _ALLOWED and v is not None:
            rec[k] = v if isinstance(v, (int, float, bool)) else str(v)[:200]
    _logger.log(level, json.dumps(rec))
