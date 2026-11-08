"""router (spec 7): classify an inbound text into one intent with ready-to-call args.

Intents: scam_check, advise, command, verify_relative, interview, pause, resume, stop, help, out_of_scope,
clarify. A forward wrapper ("Forwarded message:", "Fwd:", "Check this"...; see forward.py) is a deterministic
scam_check of the inner text, before anything else; so are "1" answers to our clarifying question, the text
after a bare "Fwd:", and extra bubbles a few seconds after a forward. Then text commands, obvious iMessage
commands ("report +1 555...", "who is in my family", "status"), pending interview answers, feedback ("wrong"
/ "that was safe", only when there is a recent check to rate), the input rail (scope), and the deterministic
own-voice / someone-else's-words signals, with MODEL_FAST breaking ties. An unwrapped text is the person
talking to us by default; when it is genuinely unclear the router returns `clarify` and asks. With `dispatch: true` the router also runs the chosen workflow and returns its
result (and queues the reply for help / out_of_scope); by default it only classifies.
"""
from __future__ import annotations

import json

from ..guard import is_explicit_off_topic
import re
import time
from typing import Any

from .. import training
from ..llm import prompt
from ..signals import extract_urls, to_e164
from ..stdb import new_key, q
from .base import BadRequest, Run, outbox_args
from .command import ACTIONS as COMMAND_ACTIONS
from .command import looks_like_command, parse_fast as parse_command_fast
from .forward import (CLARIFY_QUESTION, STATE, _FIRST_PERSON, classify_unwrapped, forward_signals,
                      no_signal_fallback, own_voice, parse_clarify_answer, parse_wrapper, tie_fallback)
from .interview import QUESTION_IDS, next_question_id, parse_ask, parse_shared, parse_yes_no

INTENTS = ["scam_check", "advise", "command", "verify_relative", "interview", "pause", "resume", "stop", "help",
           "out_of_scope"]  # model intents ("ambiguous" too); the router may also return "clarify"
FEEDBACK_WINDOW_S = 24 * 3600

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
# Already shared or sent something: the interview sets the threat level and starts recovery.
_ALREADY_SHARED = re.compile(
    r"(?i)\b(i|we) (already |just )?(gave|sent|paid|bought|installed|clicked|tapped|wired|transferred|read (them|him|her)|"
    r"told (them|him|her) (my|the)|shared)\b|\bi'?m on (a|the) (call|phone) (with|right now)"
)
# Asking for advice about a situation with someone (not a forwarded message).
_ASKING = re.compile(
    r"(?i)(\?\s*$|\b(should i|can i|is it (safe|ok|okay|normal|legit)|is (this|that|he|she|it) (a scam|legit|real|safe)|"
    r"what (should|do) i|how (do|can) i (know|tell)|do you think|would you|(asked|wants|want|told|asking) me to|"
    r"(he|she|they|someone|a man|a woman|a guy|my \w+) (wants|asked|is asking|keeps asking)|i met (someone|a|this))\b)"
)
_VERIFY_FREE = re.compile(r"(?i)\b(?:is (?:this|it) really|check (?:with|on)|verify)\s+(?:my\s+)?([A-Z][a-z]+|grandson|granddaughter|son|daughter)\b")

HELP_TEXT = ("{app} helps you spot scams. Forward any text you're unsure about and I'll check it: start it with "
             "\"Forwarded message:\" so I know it's something you received. Or just ask me a question. "
             "Text \"verify\" and a name (like \"verify Tommy\") to check a message that claims to be family. "
             "You can also text \"report\" and a number, \"add\" a name and number to your family, "
             "\"who is in my family\", \"status\", \"code word\", \"briefing\", or \"wrong\" if I got one wrong. "
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


INTERVIEW_REPLY_WINDOW_S = 30 * 60


async def awaiting_interview_answer(run: Run, phone: str, incident_id: int) -> bool:
    """True when our latest message to this person was an interview question or check-in for this incident,
    sent in the last 30 minutes: only then is a short reply an answer rather than a new message."""
    rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_outbox WHERE to_e164 = {q(phone)}"})
    latest = None
    for r in rows or []:
        if r.get("channel") == "push":
            continue
        t = r.get("created_at")
        t = int((t[0] if isinstance(t, list) else t) or 0)
        if latest is None or t > latest[0]:
            latest = (t, r)
    if not latest:
        return False
    t, row = latest
    fresh = time.time() * 1_000_000 - t < INTERVIEW_REPLY_WINDOW_S * 1_000_000
    is_question = int(row.get("related_incident_id") or 0) == incident_id and (
        row.get("kind") == "checkin" or " of 5)" in str(row.get("body") or ""))
    return fresh and is_question


def heuristic_intent(text: str) -> tuple[str, dict[str, Any]]:
    if looks_like_command(text or ""):
        return "command", {}
    m = _VERIFY_FREE.search(text or "")
    if m and len(text) < 120:
        return "verify_relative", {"relative_name": m.group(1).title()}
    if _ALREADY_SHARED.search(text or ""):
        return "interview", {}
    if _ASKING.search(text or "") and len(text) < 600:
        return "advise", {}
    if _NARRATIVE.search(text or ""):
        return "interview", {}
    return "scam_check", {}


def _key(person_id: int, from_e164: str) -> str:
    return f"p{person_id}" if person_id else (f"n{from_e164}" if from_e164 else "")


def _pre_route(key: str, text: str) -> tuple[str | None, dict[str, Any], str]:
    """Forward wrappers and per-person follow-ups, decided before anything else (CONTRACTS section 7).
    Returns (intent, extra, text): the text is what the chosen workflow should see (the wrapper stripped,
    or the remembered message for a "1"/"2" answer). intent None: route the text normally."""
    wrapped = parse_wrapper(text)
    if wrapped:
        if wrapped.bare:
            pending = STATE.peek_pending(key) if key else ""
            if pending:  # "send money" ... "Fwd:" - they just told us the last one was a forward
                STATE.clear_pending(key)
                STATE.saw_forward(key)
                return "scam_check", {"forward": "clarified"}, pending
            if key:
                STATE.expect_forward(key)
            return "clarify", {"reason": "await_forward"}, text
        if key:
            STATE.clear_pending(key)
            STATE.saw_forward(key)
        return "scam_check", {"forward": "wrapped", "sender_e164": wrapped.sender_e164}, wrapped.inner
    if not key:
        return None, {}, text
    pending = STATE.peek_pending(key)
    answer = parse_clarify_answer(text) if pending else None
    if answer:
        STATE.clear_pending(key)
        if answer == "received":
            return "scam_check", {"forward": "clarified", "teach_candidate": True}, pending
        own = own_voice(pending)
        if own and own[0] in ("command", "interview", "verify_relative"):
            return own[0], dict(own[1], own_words=True), pending
        return "advise", {"own_words": True}, pending
    if pending:
        STATE.clear_pending(key)  # they moved on: route the new text on its own
    if STATE.take_expected_forward(key):
        STATE.saw_forward(key)
        return "scam_check", {"forward": "after_marker"}, text
    if STATE.in_bubble_window(key) and not parse_command(text) and classify_unwrapped(text).intent in (None, "scam_check") \
            and not is_explicit_off_topic(text):
        STATE.saw_forward(key)  # another bubble of the message they just forwarded
        return "scam_check", {"forward": "bubble"}, text
    STATE.end_bubbles(key)
    if re.fullmatch(r"[\s\d\W]{1,4}", text) and not re.search(r"[A-Za-z]", text):
        # A lone digit or symbol with nothing pending ("2", "?", "1."): not a message to check.
        return "help", {"reason": "bare"}, text
    return None, {}, text


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
    key = _key(person_id, from_e164)

    intent, extra = None, {}
    if mode == "text":
        intent, extra, text = _pre_route(key, text)
        if intent:
            run.fields["forward"] = extra.get("forward") or extra.get("reason") or "clarified"
    if intent == "command" and not person_id:
        intent, extra = "advise", {}
    cmd = parse_command(text) if not intent else None
    fast = parse_command_fast(text) if mode == "text" and not cmd and not intent else None
    if intent:
        pass
    elif cmd:
        intent, extra = cmd
    elif fast and fast["action"] != "feedback" and person_id:
        intent, extra = "command", fast  # "report +1 555...", "add Maria +1 555... daughter", "status"
    else:
        # Pending interview answer?
        active = None
        if person_id:
            incs = await run.tools.call("read", {"query": f"SELECT * FROM svc_incident WHERE person_id = {person_id}"})
            recent = int(time.time() * 1_000_000) - 6 * 3600 * 1_000_000
            open_incs = [i for i in incs if i.get("status") != "resolved" and int(i.get("created_at") or 0) >= recent]
            active = max(open_incs, key=lambda i: int(i["id"]), default=None)
        if active and from_e164 and not await awaiting_interview_answer(run, from_e164, int(active["id"])):
            active = None  # an old open incident: don't hijack new messages unless we just asked a question
        if active:
            answers = json.loads(active.get("answers_json") or "{}")
            qid = next_question_id(answers) or "q_shared"
            if answer_like(text, qid) and not (mode == "text" and looks_like_command(text)):
                intent, extra = "interview", {"incident_id": int(active["id"])}
        if not intent and fast and person_id and training.latest_decision(person_id, max_age_s=FEEDBACK_WINDOW_S):
            intent, extra = "command", fast  # "wrong", "that was safe", "right": a label for the last check
        if not intent:
            intent, extra = await _classify(run, text, mode, person_id)
            if intent == "scam_check" and mode == "text":
                extra = dict(extra, teach_candidate=True)  # an unwrapped text we treated as a forward
            elif intent == "clarify" and key:
                STATE.set_pending(key, text)
    if intent == "verify_relative" and not cmd and person_id:
        # A forwarded "it's me, Grandpa" text names the reader, not a relative to verify. Only route to
        # verification when the name matches one of the person's family contacts; otherwise check it
        # (someone else's words) or answer it (their own question).
        contacts = await run.tools.call("read", {"query": f"SELECT * FROM svc_contact WHERE person_id = {person_id}"})
        name = (extra.get("relative_name") or "").strip().lower()
        if not any(name and name in (str(c.get("name", "")).lower(), str(c.get("relationship", "")).lower())
                   for c in contacts):
            intent, extra = ("scam_check", {}) if forward_signals(text) else ("advise", {})
    if extra.pop("teach_candidate", False) and intent == "scam_check" and key:
        extra["teach"] = STATE.tip_due(key)  # teach the wrapper at most once a day per person
    run.fields["intent"] = intent

    args = await build_args(run, intent, extra, text, person_id, from_e164, channel, mode)
    out: dict[str, Any] = {"intent": intent, "args": args}
    if p.get("dispatch") and dispatcher is not None:
        out["result"] = await dispatch(run, intent, args, from_e164, channel, dispatcher)
    return out


_TRUSTED_MODEL = ("command", "help", "out_of_scope", "verify_relative", "interview")


async def _classify(run: Run, text: str, mode: str, person_id: int) -> tuple[str, dict[str, Any]]:
    """An unwrapped text with no command or pending answer. The person is talking to us by default:
    scam_check needs a deterministic sign of someone else's message; the model only breaks ties."""
    rail = await run.guard.check_input(text)
    if not rail.ok and is_explicit_off_topic(text):
        return "out_of_scope", {}
    c = classify_unwrapped(text)
    run.fields["signals"] = ",".join(c.forward) or "none"
    if c.intent:
        intent, extra = c.intent, dict(c.extra)
    else:
        model = await run.llm.json("fast", prompt("router"), json.dumps(
            {"text": text[:1000], "mode": mode}, ensure_ascii=False), "router.model", workflow=run.workflow,
            max_tokens=120, timeout=4.0)
        m_intent = model.get("intent") if model else None
        if m_intent in ("pause", "resume", "stop") or (m_intent not in INTENTS and m_intent != "ambiguous"):
            m_intent = None
        extra = {}
        if m_intent == "command" and model.get("action") in COMMAND_ACTIONS:
            extra = {"action": model["action"]}
        elif m_intent == "verify_relative":
            if model.get("relative_name"):
                extra = {"relative_name": model["relative_name"]}
            else:
                m_intent = None
        run.fields["model_intent"] = m_intent or "none"
        if c.forward and c.own:
            # Both someone else's words and their own voice ("is this real? USPS: ..."): the model decides.
            intent = m_intent if m_intent in ("scam_check", "advise", "command", "interview", "verify_relative") \
                else tie_fallback(c)
            if intent != m_intent:
                extra = {}
        elif m_intent in _TRUSTED_MODEL:
            intent = m_intent
        elif m_intent == "advise" and (_FIRST_PERSON.search(text) or "?" in text):
            intent = m_intent
        elif m_intent is None:
            intent = no_signal_fallback(text)
        else:
            intent = "clarify"  # scam_check or ambiguous with no sign of someone else's words: ask
    if intent == "out_of_scope" and not is_explicit_off_topic(text):
        intent, extra = no_signal_fallback(text), {}  # only clear general-chat requests are out of scope
    if intent == "command" and mode == "text" and not person_id:
        intent, extra = "advise", {}
    if mode != "text":
        # Voice (call companion): always their own words; no commands, no clarifying question.
        if intent in ("command", "clarify"):
            intent, extra = "advise", {}
    return intent, extra


async def build_args(run: Run, intent: str, extra: dict, text: str, person_id: int, from_e164: str,
                     channel: str, mode: str) -> dict[str, Any]:
    if intent == "scam_check":
        args = {"person_id": person_id, "text": text, "sender_e164": extra.get("sender_e164") or "",
                "source": "imessage" if mode == "text" else "call",
                "reply_to_e164": from_e164 if mode == "text" else "", "reply_channel": channel if channel != "push" else "imessage"}
        if extra.get("teach"):
            args["teach_wrapper"] = True  # scam_check adds WRAPPER_TIP to its reply
        return args
    if intent == "clarify":
        # await_forward: a bare "Fwd:" - stay quiet, the forwarded text is on its way.
        return {"reply": "" if extra.get("reason") == "await_forward" else f"{run.app}: {CLARIFY_QUESTION}",
                "reason": extra.get("reason") or "ambiguous"}
    if intent == "verify_relative":
        return {"person_id": person_id, "relative_name": extra.get("relative_name", "")}
    if intent == "command":
        # Ready body for /run/command; args.action is a hint (or a complete parse from the fast path).
        return {"person_id": person_id, "text": text, "reply_to_e164": from_e164,
                "reply_channel": channel if channel != "push" else "imessage", "args": dict(extra or {})}
    if intent == "advise":
        return {"person_id": person_id, "text": text, "reply_to_e164": from_e164 if mode == "text" else "",
                "reply_channel": channel if channel != "push" else "imessage", "mode": mode}
    if intent == "interview":
        incident_id = int(extra.get("incident_id") or 0)
        if not incident_id and person_id:
            key = new_key()
            await run.tools.call("reducer", {"name": "open_incident", "args": {
                "request_key": key, "person_id": person_id, "entry_point": "imessage" if mode == "text" else "app",
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
    if intent == "clarify":
        if from_e164 and args.get("reply"):
            await run.db.call("enqueue_outbox", outbox_args(from_e164, channel, "reply", args["reply"]))
        return None
    if intent in ("scam_check", "advise", "command", "verify_relative", "interview"):
        return await dispatcher(intent, args)
    return None  # pause/resume/stop are handled by the caller (photon-worker) with its own identity
