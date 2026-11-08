"""POST /ios/call-report (docs/CONTRACTS.md section 7, "Reporting a call from Recents").

The iOS Unwanted Communication extension can't use the network, so iOS POSTs its
ILClassificationResponse.userInfo to us: {token, caller_e164, answers: {q_*: value}, reported_at}, either
at the top level or nested (under `userInfo` or similar, possibly as a JSON string). With the app's own
token we open a `report_swipe` incident, save each answer (the module computes severity, D2) and
`report_number` the caller. Idempotent: the request_key is derived from token + caller + reported_at,
so a replay from the App Group on the next launch finds the same incident.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from typing import Any

from .log import log
from .redact import redact
from .signals import to_e164
from .stdb import ReducerError, SqlError, Stdb, q

NEST_KEYS = ("userInfo", "user_info", "userinfo", "payload", "report", "data", "body", "info", "classification",
             "response", "ILClassificationResponse")
TOKEN_KEYS = ("token", "app_token", "spacetime_token", "auth_token")
CALLER_KEYS = ("caller_e164", "caller", "phone_e164", "phone", "number", "phone_number", "from", "handle")
TIME_KEYS = ("reported_at", "reportedAt", "timestamp", "ts", "date")
ANSWER_ORDER = ["q_identity", "q_ask", "q_secrecy", "q_help", "q_engaged", "q_summary", "q_shared"]
SHARED_ITEMS = {"code", "pin", "password", "card", "gift_card", "money", "remote_app", "personal_details", "link", "nothing"}
_YES = {"yes", "y", "true", "1", "yeah", "yep"}
_NO = {"no", "n", "false", "0", "nope"}


class CallReportError(ValueError):
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status = status


def _maybe_json(v: Any) -> Any:
    if isinstance(v, (str, bytes)):
        s = v.decode() if isinstance(v, bytes) else v
        s = s.strip()
        if s.startswith("{"):
            try:
                return json.loads(s)
            except ValueError:
                return v
    return v


def find_report(body: Any, depth: int = 0) -> dict[str, Any] | None:
    """The object holding the report: the first dict (breadth-first, depth <= 4) with a token or caller."""
    body = _maybe_json(body)
    if not isinstance(body, dict) or depth > 4:
        return None
    if any(k in body for k in TOKEN_KEYS) or (any(k in body for k in CALLER_KEYS) and "answers" in body):
        return body
    ordered = [k for k in NEST_KEYS if k in body] + [k for k in body if k not in NEST_KEYS]
    for k in ordered:
        v = _maybe_json(body[k])
        if isinstance(v, dict):
            hit = find_report(v, depth + 1)
            if hit is not None:
                return hit
    return None


def _first(d: dict, keys: tuple[str, ...]) -> Any:
    for k in keys:
        if d.get(k) not in (None, ""):
            return d[k]
    return None


def _norm_time(v: Any) -> str:
    """reported_at as a stable string: epoch seconds (ms and ISO accepted)."""
    if v is None or v == "":
        return ""
    if isinstance(v, (int, float)):
        x = float(v)
        if x > 1e14:      # micros
            x /= 1e6
        elif x > 1e11:    # millis
            x /= 1e3
        return str(int(x))
    s = str(v).strip()
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return _norm_time(float(s))
    try:
        return str(int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()))
    except ValueError:
        return s[:40]


def _answer_value(qid: str, v: Any) -> str | None:
    if v is None:
        return None
    if isinstance(v, bool):
        v = "yes" if v else "no"
    if isinstance(v, (list, tuple)):
        v = ",".join(str(x) for x in v)
    s = str(v).strip()
    if not s:
        return None
    low = s.lower()
    if qid in ("q_secrecy", "q_help", "q_engaged"):
        return "yes" if low in _YES else "no" if low in _NO else None
    if qid == "q_ask":
        return low if low in ("yes", "no", "agreed") else "yes" if low in _YES else "no" if low in _NO else None
    if qid == "q_shared":
        items = [i.strip().lower().replace(" ", "_") for i in low.split(",") if i.strip()]
        items = [i for i in items if i in SHARED_ITEMS]
        if not items:
            return None
        if "nothing" in items and len(items) > 1:
            items = [i for i in items if i != "nothing"]
        return ",".join(dict.fromkeys(items))
    if qid in ("q_identity", "q_summary"):
        return redact(s)[:80 if qid == "q_identity" else 480]
    return None


def parse_call_report(body: Any, bearer: str = "") -> dict[str, Any]:
    """Normalize the flexible payload. Raises CallReportError(400/401)."""
    rep = find_report(body)
    if rep is None and bearer and isinstance(_maybe_json(body), dict):
        rep = _maybe_json(body)
    if rep is None:
        raise CallReportError(400, "no call report found in body")
    token = str(_first(rep, TOKEN_KEYS) or bearer or "").strip()
    if len(token) < 20:
        raise CallReportError(401, "token required")
    caller_raw = str(_first(rep, CALLER_KEYS) or "").strip()
    caller = to_e164(caller_raw) if caller_raw else ""
    if caller and not re.fullmatch(r"\+[1-9]\d{6,14}", caller):
        caller = ""
    answers_raw = _maybe_json(rep.get("answers")) or {}
    if not isinstance(answers_raw, dict):
        answers_raw = {}
    # Answers may also sit at the top level (q_identity: ...).
    answers_raw = {**{k: v for k, v in rep.items() if isinstance(k, str) and k.startswith("q_")}, **answers_raw}
    answers: list[tuple[str, str]] = []
    for qid in ANSWER_ORDER:
        val = _answer_value(qid, answers_raw.get(qid))
        if val is not None:
            answers.append((qid, val))
    reported_at = _norm_time(_first(rep, TIME_KEYS))
    # The iOS extension sends its own request_key; the app replays saved reports with the same key,
    # so using it keeps the POST and the replay idempotent. Otherwise derive a stable one.
    given = rep.get("request_key")
    if isinstance(given, str) and re.fullmatch(r"[A-Za-z0-9._:-]{8,64}", given):
        request_key = given
    else:
        key_src = f"{token}|{caller}|{reported_at}"
        request_key = "callrep-" + hashlib.sha256(key_src.encode()).hexdigest()[:40]
    return {"token": token, "caller_e164": caller, "answers": answers, "reported_at": reported_at,
            "request_key": request_key}


async def handle_call_report(db: Stdb, rep: dict[str, Any]) -> dict[str, Any]:
    """Runs the reducers with the app's own token. Returns the response body."""
    tok = rep["token"]
    try:
        person = await db.one("SELECT * FROM my_person", token=tok)
    except SqlError:
        person = None
    if not person:
        raise CallReportError(401, "unknown app identity; sign in first (request_sign_in, then verify_sign_in)")
    pid = int(person["id"])
    key = rep["request_key"]
    existing = await db.one(f"SELECT * FROM my_incidents WHERE request_key = {q(key)}", token=tok)
    duplicate = existing is not None
    if not existing:
        await db.call("open_incident", {"request_key": key, "person_id": pid, "entry_point": "report_swipe",
                                        "caller_e164": rep["caller_e164"]}, token=tok)
        existing = await db.one(f"SELECT * FROM my_incidents WHERE request_key = {q(key)}", token=tok)
    if not existing:
        raise RuntimeError("incident not readable after open_incident")
    iid = int(existing["id"])
    try:
        have = json.loads(existing.get("answers_json") or "{}")
    except ValueError:
        have = {}
    saved = 0
    for qid, val in rep["answers"]:
        if qid in have:
            continue  # replay: already saved
        if existing.get("status") == "resolved":
            break
        try:
            await db.call("save_answer", {"incident_id": iid, "question_id": qid, "answer": val}, token=tok)
            saved += 1
        except ReducerError as e:
            log("call_report_answer_refused", status=e.status, error=e.text[:120])
    reported = False
    if rep["caller_e164"]:
        try:
            await db.call("report_number", {"person_id": pid, "kind": "number", "value": rep["caller_e164"]}, token=tok)
            reported = True
        except ReducerError as e:
            log("call_report_number_refused", status=e.status, error=e.text[:120])
    inc = await db.one(f"SELECT * FROM my_incidents WHERE id = {iid}", token=tok) or existing
    sev = inc.get("severity") or ""
    if sev in ("high", "critical"):
        from . import training

        training.label_incident(iid, sev, pid)
    log("call_report", person_id=pid, incident_id=iid, outcome="duplicate" if duplicate else "ok", count=saved)
    return {"ok": True, "incident_id": iid, "severity": sev, "request_key": key, "duplicate": duplicate,
            "answers_saved": saved, "reported": reported}
