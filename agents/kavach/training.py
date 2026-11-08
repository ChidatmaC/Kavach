"""Training log for self-improving Nemotron (docs/CONTRACTS.md section 7).

decisions.jsonl: one line per scam_check / advise / interview decision: redacted input, tactics, an
evidence summary (kinds, scores, counts, campaigns; never other people's report text), the model
verdict, the floors that applied and why, the final verdict, and the check request_key or incident id.

labels.jsonl: one line per label: iMessage feedback ("wrong", "that was safe"...), POST /app/feedback,
and automatic outcomes (a verification the relative denied, an incident reaching High/Critical).

Confirmed examples (decision + label) are retrieved as few-shot examples for the scam_check and advise
prompts (top 3 by lexical similarity). They go to the model only, never to people. Nothing here may
hold codes, card or account numbers (everything passes through `redact`) or full raw messages.

Writing never raises: a failed append is logged and the workflow carries on.
"""
from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Iterable

from .config import AGENTS_DIR
from .log import log
from .redact import redact

VERDICTS = ("safe", "suspicious", "likely_scam")
INPUT_LIMIT = 1000
FEW_SHOT_K = 3
FEW_SHOT_MIN_SCORE = 0.12
FEW_SHOT_TEXT_LIMIT = 400
FEEDBACK_MAX_AGE_S = 7 * 24 * 3600

_lock = threading.Lock()
_cache: dict[str, tuple[float, int, list[dict]]] = {}


def training_dir() -> Path:
    return Path(os.environ.get("KAVACH_TRAINING_DIR") or AGENTS_DIR / "data" / "training")


def decisions_path() -> Path:
    return training_dir() / "decisions.jsonl"


def labels_path() -> Path:
    return training_dir() / "labels.jsonl"


def _append(path: Path, rec: dict[str, Any]) -> bool:
    try:
        with _lock:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return True
    except OSError as e:
        log("training_write_failed", path=path.name, error=type(e).__name__)
        return False


def _read(path: Path) -> list[dict]:
    """All records of a jsonl file, cached on (mtime, size)."""
    try:
        st = path.stat()
    except OSError:
        return []
    key = str(path)
    hit = _cache.get(key)
    if hit and hit[0] == st.st_mtime and hit[1] == st.st_size:
        return hit[2]
    rows: list[dict] = []
    with _lock:
        with path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    _cache[key] = (st.st_mtime, st.st_size, rows)
    return rows


def load_decisions() -> list[dict]:
    return _read(decisions_path())


def load_labels() -> list[dict]:
    return _read(labels_path())


# --- decisions -------------------------------------------------------------------------------

def evidence_summary(evidence: Iterable[Any]) -> list[dict]:
    """Community evidence without anyone's report text (no excerpts)."""
    out = []
    for e in list(evidence)[:8]:
        d = e if isinstance(e, dict) else e.__dict__
        out.append({
            "kind": d.get("kind", ""), "score": round(float(d.get("score") or 0), 3),
            "reporter_count": int(d.get("reporter_count") or 0), "campaign_id": int(d.get("campaign_id") or 0),
            "campaign_title": str(d.get("campaign_title") or "")[:80], "tactics": list(d.get("tactics") or [])[:8],
            "verdict": d.get("verdict", ""),
        })
    return out


def log_decision(*, workflow: str, person_id: int, text: str, tactics: list[str], evidence: Iterable[Any],
                 model_verdict: str, final_verdict: str, floors: dict[str, Any], reason: str = "",
                 sender_e164: str = "", link_domains: list[str] | None = None, claimed_identity: str = "",
                 check_request_key: str = "", incident_id: int = 0, method: str = "",
                 extra: dict[str, Any] | None = None) -> str:
    """Append one decision. Returns its id ("" if it could not be written)."""
    rec = {
        "id": f"d_{uuid.uuid4().hex[:16]}", "ts": round(time.time(), 3), "workflow": workflow,
        "person_id": int(person_id or 0),
        "input_redacted": redact(text or "")[:INPUT_LIMIT],
        "signals": {"sender_e164": sender_e164 or "", "link_domains": list(link_domains or [])[:5],
                    "claimed_identity": redact(claimed_identity or "")[:80]},
        "tactics": list(dict.fromkeys(tactics or []))[:8],
        "evidence": evidence_summary(evidence),
        "model_verdict": model_verdict or "", "floors": floors, "final_verdict": final_verdict,
        "reason": redact(reason or "")[:300], "method": method,
        "check_request_key": check_request_key or "", "incident_id": int(incident_id or 0),
    }
    if extra:
        rec.update(extra)
    return rec["id"] if _append(decisions_path(), rec) else ""


def decision_by_id(decision_id: str) -> dict | None:
    return next((d for d in reversed(load_decisions()) if d.get("id") == decision_id), None)


def decision_for_check(request_key: str) -> dict | None:
    if not request_key:
        return None
    return next((d for d in reversed(load_decisions()) if d.get("check_request_key") == request_key), None)


def latest_decision(person_id: int, workflows: tuple[str, ...] = ("scam_check", "advise", "interview"),
                    max_age_s: float = FEEDBACK_MAX_AGE_S, verdicts: tuple[str, ...] = VERDICTS) -> dict | None:
    cutoff = time.time() - max_age_s
    for d in reversed(load_decisions()):
        if (int(d.get("person_id") or 0) == int(person_id) and d.get("workflow") in workflows
                and float(d.get("ts") or 0) >= cutoff and d.get("final_verdict") in verdicts):
            return d
    return None


# --- labels -----------------------------------------------------------------------------------

def flipped(verdict: str) -> str:
    """The label implied by "that was wrong" with no verdict given."""
    return "suspicious" if verdict == "safe" else "safe"


def add_label(*, decision: dict | None, person_id: int, source: str, correct: bool | None = None, label: str = "",
              note: str = "", key: str = "", check_id: int = 0) -> dict | None:
    """Append a label. `label` is the true verdict when known; with only correct=True/False it is derived
    from the decision's final verdict. `key` makes automatic labels idempotent."""
    if key and any(lb.get("key") == key for lb in load_labels()):
        return None
    final = (decision or {}).get("final_verdict", "")
    if label not in VERDICTS:
        label = ""
    if not label and correct is True and final in VERDICTS:
        label = final
    if not label and correct is False and final in VERDICTS:
        label = flipped(final)
    if correct is None and label and final:
        correct = label == final
    rec = {
        "id": f"l_{uuid.uuid4().hex[:16]}", "ts": round(time.time(), 3), "key": key,
        "decision_id": (decision or {}).get("id", ""), "workflow": (decision or {}).get("workflow", ""),
        "person_id": int(person_id or 0), "check_id": int(check_id or 0),
        "source": source, "correct": correct, "label": label, "previous_verdict": final, "note": redact(note or "")[:200],
    }
    if not _append(labels_path(), rec):
        return None
    log("training_label", source=source, label=label or "none", decision_id=rec["decision_id"])
    return rec


def latest_labels() -> dict[str, dict]:
    """decision_id -> its most recent label that names a verdict."""
    out: dict[str, dict] = {}
    for lb in load_labels():
        if lb.get("decision_id") and lb.get("label") in VERDICTS:
            out[lb["decision_id"]] = lb
    return out


def labeled_examples(workflows: tuple[str, ...] = ("scam_check", "advise")) -> list[tuple[dict, str]]:
    labels = latest_labels()
    out = []
    for d in load_decisions():
        lb = labels.get(d.get("id", ""))
        if lb and d.get("workflow") in workflows and d.get("input_redacted"):
            out.append((d, lb["label"]))
    return out


def few_shot(text: str, workflows: tuple[str, ...] = ("scam_check", "advise"), k: int = FEW_SHOT_K,
             min_score: float = FEW_SHOT_MIN_SCORE) -> list[dict]:
    """Top-k confirmed examples most similar to `text`, redacted, for the model prompt only."""
    from .similarity import lexical_scores

    examples = labeled_examples(workflows)
    if not examples or not text:
        return []
    # One example per distinct input (latest label wins).
    uniq: dict[str, tuple[dict, str]] = {}
    for d, lb in examples:
        uniq[" ".join(d["input_redacted"].lower().split())] = (d, lb)
    pool = list(uniq.values())
    scores = lexical_scores(redact(text), [d["input_redacted"] for d, _ in pool])
    ranked = sorted(zip(scores, pool), key=lambda x: -x[0])
    return [{"message_redacted": d["input_redacted"][:FEW_SHOT_TEXT_LIMIT], "tactics": d.get("tactics", [])[:6],
             "correct_verdict": lb, "similarity": round(sc, 3)}
            for sc, (d, lb) in ranked[:k] if sc >= min_score]


# --- automatic outcomes ----------------------------------------------------------------------

def label_incident(incident_id: int, severity: str, person_id: int = 0) -> int:
    """An incident reached High/Critical: its interview decisions were scams. Returns labels written."""
    if severity not in ("high", "critical") or not incident_id:
        return 0
    n = 0
    for d in load_decisions():
        if int(d.get("incident_id") or 0) == int(incident_id):
            if add_label(decision=d, person_id=person_id or int(d.get("person_id") or 0), source="incident_severity",
                         label="likely_scam", key=f"incident:{incident_id}:{d['id']}", note=f"severity {severity}"):
                n += 1
    return n


def label_verification_denied(verification_id: int, person_id: int, created_at_s: float,
                              window_s: float = 2 * 3600) -> int:
    """The relative said "it wasn't me": the check that led to the verification was a scam."""
    key = f"verification:{verification_id}"
    if any(lb.get("key") == key for lb in load_labels()):
        return 0
    related = None
    for d in reversed(load_decisions()):
        ts = float(d.get("ts") or 0)
        if (int(d.get("person_id") or 0) == int(person_id) and d.get("workflow") in ("scam_check", "advise")
                and created_at_s - window_s <= ts <= created_at_s + 300):
            related = d
            break
    if not related:
        return 0
    return 1 if add_label(decision=related, person_id=person_id, source="verification_denied", label="likely_scam",
                          key=key) else 0
