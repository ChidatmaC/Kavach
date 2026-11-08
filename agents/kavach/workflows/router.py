"""router (spec 7): classify an inbound text or hotline turn into one intent with ready-to-call args.

Intents: scam_check, verify_relative, interview, pause, resume, stop, help, out_of_scope.
Text commands are parsed first (deterministic), then the input rail (scope), then MODEL_FAST, with a
heuristic fallback. With `dispatch: true` the router also runs the chosen workflow and returns its
result (and queues the reply for help / out_of_scope); by default it only classifies.
"""
from __future__ import annotations

import json

from ..guard import is_explicit_off_topic
import re
import time
from typing import Any

from ..llm import prompt
from ..signals import extract_urls, to_e164
from ..stdb import new_key, q
from .base import BadRequest, Run, outbox_args
from .interview import QUESTION_IDS, next_question_id, parse_ask, parse_shared, parse_yes_no

INTENTS = ["scam_check", "verify_relative", "interview", "pause", "resume", "stop", "help", "out_of_scope"]

_CMD = [
    (re.compile(r"(?i)^\s*verify\s+(?:my\s+)?([a-z][a-z .'-]{0,40}?)\s*[.!?]*\s*$"), "verify_relative"),
    (re.compile(r"(?i)^\s*(pause)( sharing| alerts)?\s*[.!]*\s*$"), "pause"),
    (re.compile(r"(?i)^\s*(resume|unpause)( sharing| alerts)?\s*[.!]*\s*$"), "resume"),
    (re.compile(r"(?i)^\s*(stop|stopall|unsubscribe|cancel|end|quit|opt out)\s*[.!]*\s*$"), "stop"),
    (re.compile(r"(?i)^\s*(help|info|\?|menu|what can you do\??)\s*[.!]*\s*$"), "help"),
]
_NARRATIVE = re.compile(
    r"(?i)\b(i (just )?(got|had|received) a (phone )?call|someone (just )?called|(he|she|they) called|"
    r"on the phone with|i('m| am) on a call|they asked me|i gave (them|him|her)|i sent (them|him|her)|"
    r"i (paid|bought|installed|clicked|tapped)|they (said|told me) (they|he|she) (was|were|is|are))\b"
)
_VERIFY_FREE = re.compile(r"(?i)\b(?:is (?:this|it) really|check (?:with|on)|verify)\s+(?:my\s+)?([A-Z][a-z]+|grandson|granddaughter|son|daughter)\b")

HELP_TEXT = ("{app} helps you spot scams. Forward any text you're unsure about and I'll check it. "
             "Text \"verify\" and a name (like \"verify Tommy\") to check a message that claims to be family. "
             "\"pause\" or \"resume\" family alerts, \"stop\" to opt out. Never share codes with anyone.")


def parse_command(text: str) -> tuple[str, dict[str, Any]] | None:
    for rx, intent in _CMD:
        m = rx.match(text or "")
        if m:
            return (intent, {"relative_name": m.group(1).strip().title()}) if intent == "verify_relative" else (intent, {})
    return None


def answer_like(text: str, qid: str) -> bool:
    t = (text or "").strip()
    if len(t) > 120 or extract_urls(t):
        return False  # a forwarded message, not an answer
    if qid == "q_identity":
        return len(t) <= 60 and not re.search(r"https?://|\.\w{2,4}/", t)
    parser = {"q_ask": parse_ask, "q_shared": parse_shared, "q_secrecy": parse_yes_no, "q_help": parse_yes_no}[qid]
    return parser(t) is not None


def heuristic_intent(text: str) -> tuple[str, dict[str, Any]]:
    m = _VERIFY_FREE.search(text or "")
    if m and len(text) < 120:
        return "verify_relative", {"relative_name": m.group(1).title()}
    if _NARRATIVE.search(text or ""):
        return "interview", {}
    return "scam_check", {}


async def run_router(run: Run, p: dict[str, Any], dispatcher=None) -> dict[str, Any]:
    text = (p.get("text") or "").strip()
    from_e164 = to_e164(p.get("from_e164") or "") if p.get("from_e164") else ""
    channel = p.get("channel") or "imessage"
    mode = p.get("mode") or "text"
    if not text:
        raise BadRequest("text required")
    person_id = int(p.get("person_id") or 0)

    if not person_id and from_e164:
        person = await run.tools.call("read", {"query": f"SELECT * FROM svc_person WHERE phone_e164 = {q(from_e164)}"})
        if not person and mode == "text":
            await run.tools.call("reducer", {"name": "ensure_person", "args": {"phone": from_e164, "name": "Friend"}})
            person = await run.tools.call("read", {"query": f"SELECT * FROM svc_person WHERE phone_e164 = {q(from_e164)}"})
        person_id = int(person[0]["id"]) if person else 0
    run.fields["person_id"] = person_id

    intent, extra = None, {}
    cmd = parse_command(text)
    if cmd:
        intent, extra = cmd
    else:
        # Pending interview answer?
        active = None
        if person_id:
            incs = await run.tools.call("read", {"query": f"SELECT * FROM svc_incident WHERE person_id = {person_id}"})
            recent = int(time.time() * 1_000_000) - 6 * 3600 * 1_000_000
            open_incs = [i for i in incs if i.get("status") != "resolved" and int(i.get("created_at") or 0) >= recent]
            active = max(open_incs, key=lambda i: int(i["id"]), default=None)
        if active:
            answers = json.loads(active.get("answers_json") or "{}")
            qid = next_question_id(answers) or "q_shared"
            if answer_like(text, qid):
                intent, extra = "interview", {"incident_id": int(active["id"])}
        if not intent:
            rail = await run.guard.check_input(text)
            if not rail.ok and is_explicit_off_topic(text):
                intent = "out_of_scope"
            else:
                model = await run.llm.json("fast", prompt("router"), json.dumps(
                    {"text": text[:1000], "mode": mode}, ensure_ascii=False), "router.model", workflow=run.workflow,
                    max_tokens=120, timeout=4.0)
                if model and model["intent"] in INTENTS and model["intent"] not in ("pause", "resume", "stop"):
                    intent = model["intent"]
                    if intent == "verify_relative":
                        if model.get("relative_name"):
                            extra = {"relative_name": model["relative_name"]}
                        else:
                            intent = "scam_check"
                else:
                    intent, extra = heuristic_intent(text)
    if intent == "verify_relative" and not cmd and person_id:
        # A forwarded "it's me, Grandpa" text names the reader, not a relative to verify. Only route to
        # verification when the name matches one of the person's family contacts; otherwise check it.
        contacts = await run.tools.call("read", {"query": f"SELECT * FROM svc_contact WHERE person_id = {person_id}"})
        name = (extra.get("relative_name") or "").strip().lower()
        if not any(name and name in (str(c.get("name", "")).lower(), str(c.get("relationship", "")).lower())
                   for c in contacts):
            intent, extra = "scam_check", {}
    run.fields["intent"] = intent

    args = await build_args(run, intent, extra, text, person_id, from_e164, channel, mode)
    out: dict[str, Any] = {"intent": intent, "args": args}
    if p.get("dispatch") and dispatcher is not None:
        out["result"] = await dispatch(run, intent, args, from_e164, channel, dispatcher)
    return out


async def build_args(run: Run, intent: str, extra: dict, text: str, person_id: int, from_e164: str,
                     channel: str, mode: str) -> dict[str, Any]:
    if intent == "scam_check":
        return {"person_id": person_id, "text": text, "sender_e164": "", "source": "imessage" if mode == "text" else "call",
                "reply_to_e164": from_e164 if mode == "text" else "", "reply_channel": channel if channel != "push" else "imessage"}
    if intent == "verify_relative":
        return {"person_id": person_id, "relative_name": extra.get("relative_name", "")}
    if intent == "interview":
        incident_id = int(extra.get("incident_id") or 0)
        if not incident_id and person_id:
            key = new_key()
            await run.tools.call("reducer", {"name": "open_incident", "args": {
                "request_key": key, "person_id": person_id, "entry_point": "imessage" if mode == "text" else "hotline",
                "caller_e164": ""}})
            rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_incident WHERE request_key = {q(key)}"})
            incident_id = int(rows[0]["id"]) if rows else 0
        # A first description is free speech (extract all answers); a short reply answers the pending question.
        # Text mode: the interview workflow queues the next question itself (D6); voice mode only returns `say`.
        args = {"incident_id": incident_id, "mode": "voice" if mode == "voice" else "text", "utterance": text}
        if mode != "voice" and not extra.get("incident_id"):
            args["free_text"] = True
        return args
    if intent in ("pause", "resume"):
        return {"person_id": person_id, "paused": intent == "pause"}
    if intent == "stop":
        return {"phone": from_e164}
    if intent == "help":
        return {"reply": HELP_TEXT.format(app=run.app)}
    return {"reply": (await run.guard.check_input(text)).message or HELP_TEXT.format(app=run.app)}


async def dispatch(run: Run, intent: str, args: dict, from_e164: str, channel: str, dispatcher) -> Any:
    if intent in ("help", "out_of_scope"):
        if from_e164:
            await run.db.call("enqueue_outbox", outbox_args(from_e164, channel, "system", args["reply"]))
        return None
    if intent in ("scam_check", "verify_relative", "interview"):
        return await dispatcher(intent, args)
    return None  # pause/resume/stop are handled by the caller (photon-worker) with its own identity
