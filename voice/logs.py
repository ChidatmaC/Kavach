"""Structured JSON logs. Never log utterances, replies or numbers: only event names, ids,
latencies and outcomes (spec 12, 13)."""
from __future__ import annotations

import json
import logging
import sys
import time

_logger = logging.getLogger("kavach.voice")
if not _logger.handlers:
    _h = logging.StreamHandler(sys.stderr)
    _h.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(_h)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False

# Keys whose values may carry caller content; refused even if a caller passes them.
_FORBIDDEN = {"text", "utterance", "say", "body", "transcript", "summary", "caller_e164", "phone"}


def log(event: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "svc": "voice", "event": event}
    for k, v in fields.items():
        if k in _FORBIDDEN:
            continue
        rec[k] = v
    _logger.info(json.dumps(rec, default=str))
