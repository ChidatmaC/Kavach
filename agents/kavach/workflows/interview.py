"""interview (spec 7, 7a "Interview questions", 8). Asks the next unanswered question, saves answers
with `save_answer` (the module computes severity, D2), stops after 5 questions or at Critical.

Modes: text (queues the next question via the outbox), app (returns it), voice (extracts answers
for all five ids from free speech, saves each one, returns what to say next).
"""
from __future__ import annotations

import json
import re
from typing import Any

from ..llm import prompt
from ..recovery import recovery_steps
from ..redact import redact
from ..signals import claimed_identity, tactics_of
from .base import BadRequest, NotFound, Run, outbox_args

QUESTION_IDS = ["q_identity", "q_ask", "q_shared", "q_secrecy", "q_help"]
SHARED_ITEMS = ["code", "pin", "password", "card", "gift_card", "money", "remote_app", "personal_details", "link"]

# Asked first when the report is about a call: a missed or declined call ends the questions (Low).
ANSWERED_QUESTION = "Did you answer the call? Reply yes or no."
APP_ENTRY_POINTS = {"app", "report_swipe", "companion"}

QUESTIONS = {
    "q_answered": ANSWERED_QUESTION,
    "q_identity": "Who did they say they were? For example: your bank, your grandson, the IRS, or a company.",
    "q_ask": "Did they ask for money, codes, gift cards or personal details? Reply yes or no, or \"agreed\" if you agreed to pay or call them back.",
    "q_shared": "Did you share or send anything? Pick any that apply: code, PIN, password, card details, gift card numbers, money, an app install, personal details, tapped a link, or nothing.",
    "q_secrecy": "Did they ask you to keep it secret or rush you? Reply yes or no.",
    "q_help": "Do you want help right now? Reply yes or no.",
}
VOICE_QUESTIONS = {
    "q_answered": "Did you pick up the call?",
    "q_identity": "Who did they say they were?",
    "q_ask": "Did they ask you for money, codes, gift cards or personal details?",
    "q_shared": "Did you share or send anything, like a code, card details, gift cards, money, an app, personal details, or a link you tapped? Please don't tell me the actual numbers.",
    "q_secrecy": "Did they ask you to keep it secret, or rush you?",
    "q_help": "Do you want help right now?",
}
CHECKIN_QUESTION = ("Checking in. Did anything else happen since we talked? Did you share anything else, like a code, "
                    "card details or money? Reply \"nothing\" if not, or tell me what you shared.")

_YES = re.compile(r"(?i)^\s*(y|yes|yeah|yep|yup|sure|correct|they did|i did|definitely|absolutely|uh huh|please|ok(ay)?)\b")
_NO = re.compile(r"(?i)^\s*(n|no|nope|nah|not really|never|they didn'?t|i didn'?t|none|nothing)\b")
_AGREED = re.compile(r"(?i)\b(agreed|i agreed|promised|said i would|said i'?d|call(ed)? (them )?back|callback|going to pay|will pay)\b")

_SHARED_KEYWORDS: list[tuple[str, str]] = [
    (r"gift ?cards?|itunes|google play|steam card", "gift_card"),
    (r"\bpins?\b", "pin"),
    (r"pass ?words?", "password"),
    (r"\b(codes?|otp|passcode|verification number)\b", "code"),
    (r"(credit|debit|bank) ?card|card (number|details|info)|\bcard\b|cvv|expiration", "card"),
    (r"\b(money|paid|wired?|zelle|venmo|cash ?app|bitcoin|crypto|transfer(red)?)\b|sent \$|\$\d", "money"),
    (r"\bapps?\b|anydesk|teamviewer|install(ed)?|remote|screen ?share|download(ed)?", "remote_app"),
    (r"social security|\bssn\b|date of birth|birthday|\baddress|personal (details|info)|my name|medicare (number|id)|account number|details", "personal_details"),
    (r"\blinks?\b|clicked|tapped|website", "link"),
]
_NEGATION = re.compile(r"(?i)\b(didn'?t|did not|never|no|not|wouldn'?t|refused|hung up)\b")
_ASKED = re.compile(r"(?i)\b(asked|wanted|told me to|demanded|needed|asking|ask)\b")
_BACKREF = re.compile(r"(?i)\b(them|it|those|these|one|two|three|some|the numbers?|the codes?|him|her)\b")
_GAVE = re.compile(r"(?i)\b(i|we)\s+(gave|sent|shared|told|read|paid|bought|installed|downloaded|clicked|tapped|wired|transferred|entered|typed|provided|let them)\b")


def parse_yes_no(text: str) -> str | None:
    if _NO.search(text):
        return "no"
    if _YES.search(text):
        return "yes"
    return None


_NOT_ANSWERED = re.compile(r"(?i)\b(no|nope|missed|didn'?t|did not|declined|ignored|let it ring|voicemail|hung up before)\b")


def parse_answered(text: str) -> str | None:
    """"Did you answer the call?" -> yes | no ("missed it", "let it go to voicemail" count as no)."""
    if _NOT_ANSWERED.search(text or ""):
        return "no"
    return parse_yes_no(text)


def parse_ask(text: str) -> str | None:
    if _AGREED.search(text):
        return "agreed"
    return parse_yes_no(text)


def parse_shared(text: str) -> str | None:
    """Comma list for save_answer q_shared, 'nothing', or None if unclear."""
    t = text.strip().lower()
    if re.fullmatch(r"(no|nope|nothing|none|nothing at all|i didn'?t( share anything)?|no i didn'?t)[.! ]*", t):
        return "nothing"
    items = [item for pat, item in _SHARED_KEYWORDS if re.search(pat, t)]
    # gift card numbers mention "card" and "numbers": keep gift_card only
    if "gift_card" in items and "card" in items and not re.search(r"(credit|debit|bank) ?card", t):
        items.remove("card")
    items = list(dict.fromkeys(items))
    if items:
        return ",".join(items)
    if re.search(r"(?i)\bnothing\b|\bnone\b", t):
        return "nothing"
    return None


def extract_from_speech(text: str) -> dict[str, str]:
    """Heuristic extraction of interview answers from a free description (voice mode, no model)."""
    out: dict[str, str] = {}
    ident = claimed_identity(text)
    if ident:
        out["q_identity"] = ident
    low = text.lower()
    if _AGREED.search(low):
        out["q_ask"] = "agreed"
    elif re.search(r"\b(asked|wanted|told me to|demanded|needed|asking) (me )?(for|to (send|pay|buy|give|read|install|click))\b", low) or \
            re.search(r"\b(asked|wanted|asking)\b.{0,40}\b(money|codes?|gift ?cards?|details|card|pin|password|social security|pay)\b", low):
        out["q_ask"] = "yes"
    shared: list[str] = []
    said_nothing = bool(re.search(r"\b(i )?(didn'?t|did not|never) (share|give|send|tell|pay)\b.{0,15}\b(anything|them anything|a thing)\b|\bi hung up\b", low))
    clauses = re.split(r"[.;!?]|\bbut\b|\band then\b", low)
    # Items the caller asked for ("asked me to buy gift cards"), so "I bought two" can refer back to them.
    asked_items = [item for c in clauses if _ASKED.search(c) for pat, item in _SHARED_KEYWORDS if re.search(pat, c)]
    for clause in clauses:
        if _GAVE.search(clause) and not re.search(r"\b(i|we) (didn'?t|did not|never|wouldn'?t)\b", clause):
            found = [item for pat, item in _SHARED_KEYWORDS if re.search(pat, clause)]
            if not found and _BACKREF.search(clause):
                found = asked_items
            for item in found:
                if item not in shared:
                    shared.append(item)
    if "gift_card" in shared and "card" in shared and not re.search(r"(credit|debit|bank) ?card", low):
        shared.remove("card")
    if shared:
        out["q_shared"] = ",".join(shared)
    elif said_nothing:
        out["q_shared"] = "nothing"
    t = tactics_of(text)
    if "secrecy" in t or "urgency" in t or re.search(r"\b(rush(ed|ing)?|pressur|hurry|keep (it|this) (a )?secret|(not|don'?t|never) (to )?tell (anyone|anybody|mom|dad|your|my|the))", low):
        out["q_secrecy"] = "yes"
    if re.search(r"\b(help me|i need help|what (do|should) i do|please help)\b", low):
        out["q_help"] = "yes"
    return out


def _answers(inc: dict) -> dict[str, str]:
    try:
        return json.loads(inc.get("answers_json") or "{}")
    except ValueError:
        return {}


def next_question_id(answers: dict[str, str], inc: dict | None = None) -> str | None:
    """Next unanswered question. Call reports start with "Did you answer the call?"; "no" ends it."""
    if answers.get("q_answered") == "no":
        return None
    if inc and inc.get("caller_e164") and "q_answered" not in answers and not any(q in answers for q in QUESTION_IDS):
        return "q_answered"
    return next((qid for qid in QUESTION_IDS if qid not in answers), None)


def question_number(qid: str) -> int:
    return 1 if qid == "q_answered" else QUESTION_IDS.index(qid) + 1


def wrap_up(run: Run, inc: dict, has_family: bool) -> str:
    sev = inc.get("severity") or ""
    steps = recovery_steps(list(inc.get("shared_items") or []), sev == "critical")
    first = " ".join(s["text"] for s in steps[:2])
    if sev == "critical":
        msg = (f"This was a scam, and it's serious, but we can fix this together. {first} "
               "I can stay on the line while you call your bank or carrier.")
    elif sev == "high":
        msg = f"This looks like a scam. Be careful: what you shared could be misused. {first}"
    elif sev == "medium":
        msg = "This was likely a scam, and you did the right thing by not sharing anything."
    elif sev == "low":
        msg = "Good news: nothing was shared, so you're safe."
    else:
        msg = "Thanks for telling me."
    if has_family and sev in ("critical", "high"):
        msg += " I've told your family."
    elif sev == "medium":
        msg += " Would you like me to tell your family?"
    return msg + " Press 1 or say repeat to hear that again."


def call_verdict(search, severity: str) -> tuple[str, str]:
    """Verdict for a described call (7a "Calls"): heuristics + community floor, raised by severity."""
    from ..community import max_verdict
    from .scam_check import heuristic_verdict, template_reason

    verdict, tactics, _ = heuristic_verdict(search, [])
    verdict = max_verdict(verdict, search.floor)
    if severity in ("high", "critical"):
        verdict = "likely_scam"
    elif severity == "medium":
        verdict = max_verdict(verdict, "suspicious")
    return verdict, template_reason(verdict, search, [], tactics)


async def run_interview(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    """Tool calls (max 6): incident_state, search_community, save (batch), incident_state, get_person, enqueue."""
    incident_id = int(p.get("incident_id") or 0)
    mode = p.get("mode") or "text"
    if not incident_id:
        raise BadRequest("incident_id required")
    if mode not in ("text", "app", "voice"):
        raise BadRequest("mode must be text, app or voice")
    run.fields["incident_id"] = incident_id
    st = await run.tools.call("incident_state", {"incident_id": incident_id})
    inc = st["incident"]
    if not inc:
        raise NotFound("unknown incident")
    person_id = int(inc.get("person_id") or 0)
    answers = _answers(inc)
    utterance = (p.get("utterance") or "").strip()
    free = bool(utterance) and (mode == "voice" or bool(p.get("free_text")))
    extracted = await extract_voice(run, utterance) if free else {}

    # 7a: search on the described call script plus the caller number.
    script = " ".join(x for x in [utterance, inc.get("summary_redacted") or ""] if x)
    ident = extracted.get("q_identity") or inc.get("claimed_identity") or ""
    search = await run.tools.call("search_community", {
        "text": script, "sender_e164": inc.get("caller_e164") or "",
        "extra_context": " ".join(x for x in [f"Caller claimed to be {ident}." if ident else "",
                                              " ".join(inc.get("tactics") or [])] if x)})
    # Tactics describe THIS call: from the caller's own words, else the single best community match.
    tactics = sorted(set(search.signals.tactics) or (set(search.evidence[0].tactics) if search.evidence else set()))
    context_call = None
    if (set(tactics) - set(inc.get("tactics") or [])) or (search.campaign_id and not inc.get("campaign_id")):
        # Tactics and campaign only (the module writes the incident's report_evidence row itself).
        context_call = {"name": "set_incident_context", "args": {
            "incident_id": incident_id, "tactics": tactics[:8], "campaign_id": int(search.campaign_id or 0)}}

    saves: list[tuple[str, str]] = []
    reask = None
    checkin = bool(p.get("checkin")) and not utterance
    if inc.get("status") != "resolved" and utterance:
        pending = next_question_id(answers, inc)
        # Only short replies are answers to the pending question; a long description is free speech.
        follow_up = free and "q_summary" in answers and pending is not None and len(utterance.split()) <= 8
        quick = None
        if follow_up:
            # A short reply to the question we just asked ("no", "gift cards"): parse it for that question.
            quick = {"q_identity": lambda u: redact(u)[:80], "q_ask": parse_ask, "q_shared": parse_shared,
                     "q_secrecy": parse_yes_no, "q_help": parse_yes_no}[pending](utterance)
        if quick is not None:
            saves.append((pending, quick))
            for qid in ("q_identity", "q_ask", "q_secrecy", "q_help", "q_shared"):
                if qid != pending and qid in extracted and qid not in answers:
                    saves.insert(0, (qid, extracted[qid]))
        elif free:
            # Context and identity first; q_shared last, because it can trigger the level sequence.
            for qid in ("q_identity", "q_ask", "q_secrecy", "q_help"):
                if qid in extracted and qid not in answers:
                    saves.append((qid, extracted[qid]))
            saves.append(("q_summary", redact(utterance)[:480]))
            if "q_shared" in extracted:
                saves.append(("q_shared", extracted["q_shared"]))
        else:
            qid = p.get("question_id") or next_question_id(answers, inc) or "q_shared"
            if qid not in QUESTION_IDS and qid != "q_answered":
                raise BadRequest("invalid question_id")
            value = {
                "q_identity": lambda u: redact(u)[:80], "q_answered": parse_answered,
                "q_ask": parse_ask, "q_shared": parse_shared,
                "q_secrecy": parse_yes_no, "q_help": parse_yes_no,
            }[qid](utterance)
            if value is None and run.llm.models.enabled:
                value = (await extract_voice(run, utterance, only=qid)).get(qid)
            if value is None:
                reask = qid
            else:
                saves.append((qid, value))

    calls = ([context_call] if context_call else []) + [
        {"name": "save_answer", "args": {"incident_id": incident_id, "question_id": qid, "answer": ans}}
        for qid, ans in saves]
    if calls:
        before = inc.get("severity") or ""
        if len(calls) == 1:
            await run.tools.call("reducer", calls[0])
        else:
            from ..tools import checked_reducers

            await checked_reducers(run.tools, calls)
        st = await run.tools.call("incident_state", {"incident_id": incident_id, "wait_alerts": True,
                                                     "severity_before": before})
        inc = st["incident"] or inc
        answers = _answers(inc)

    severity = inc.get("severity") or ""
    verdict, reason = call_verdict(search, severity)
    out: dict[str, Any] = {"done": False, "severity": severity, "verdict": verdict, "reason": reason,
                           "evidence_count": len(search.evidence), "campaign_id": int(inc.get("campaign_id") or search.campaign_id or 0),
                           "alert_sent": bool(st["alert_sent"])}
    run.fields.update(verdict=verdict, evidence_count=len(search.evidence))
    if utterance:
        from .. import training
        from ..community import max_verdict as _max

        heuristic = call_verdict(search, "")[0]
        training.log_decision(
            workflow="interview", person_id=person_id, text=utterance, tactics=tactics, evidence=search.evidence,
            model_verdict=heuristic, final_verdict=verdict, reason=reason, method="heuristic+severity",
            floors={"community": search.floor, "similarity": search.similarity_floor or "",
                    "exact": search.exact_floor or "", "severity": severity,
                    "severity_floor": "likely_scam" if severity in ("high", "critical")
                    else "suspicious" if severity == "medium" else ""},
            sender_e164=inc.get("caller_e164") or "", claimed_identity=inc.get("claimed_identity") or "",
            incident_id=incident_id, extra={"mode": mode, "raised": _max(heuristic, verdict) != heuristic})
        training.label_incident(incident_id, severity, person_id)

    if checkin:
        nxt, text = "q_shared", CHECKIN_QUESTION
    elif inc.get("status") == "resolved":
        nxt, text = None, ""
    else:
        nxt = reask or next_question_id(answers, inc)
        text = QUESTIONS[nxt] if nxt else ""
    done = nxt is None or (severity == "critical" and not checkin)
    out["done"] = done
    if not done:
        out["question_id"] = nxt
        out["next_question"] = text
        prefix = "Sorry, I didn't catch that. " if reask else ""
        if mode == "voice":
            out["say"] = prefix + (VOICE_QUESTIONS[nxt] if not checkin else CHECKIN_QUESTION)
        if mode == "text" and person_id:
            # Text mode owns the reply (D6): queue the next question or check-in ourselves.
            person = await run.tools.call("get_person", {"person_id": person_id})
            if person:
                body = (f"{run.app}: {CHECKIN_QUESTION}" if checkin
                        else f"{run.app} ({question_number(nxt)} of 5): {prefix}{text}")
                # Reports started in the app get follow-ups in the app (push), not as texts.
                channel = "push" if inc.get("entry_point") in APP_ENTRY_POINTS else "imessage"
                await run.tools.call("reducer", {"name": "enqueue_outbox", "args": outbox_args(
                    person["phone_e164"], channel, "checkin" if checkin else "reply", body, "normal", incident_id)})
    elif mode == "voice":
        out["say"] = wrap_up(run, inc, out["alert_sent"])
    return out


async def extract_voice(run: Run, utterance: str, only: str | None = None) -> dict[str, str]:
    """MODEL_FAST extracts answers from free speech; heuristic extraction is the fallback.
    Model answers are re-validated with the same parsers so only allowed values reach save_answer."""
    heur = extract_from_speech(utterance)
    model = await run.llm.json("fast", prompt("interview"), json.dumps(
        {"utterance_redacted": redact(utterance)[:1500], "only": only or "all"}, ensure_ascii=False),
        "interview.extract", workflow=run.workflow)
    if not model:
        return heur
    out = dict(heur)
    for qid, val in (model.get("answers") or {}).items():
        if not val or qid not in QUESTION_IDS:
            continue
        if qid == "q_identity":
            out[qid] = redact(str(val))[:80]
        elif qid == "q_shared":
            items = [i for i in str(val).split(",") if i.strip() in SHARED_ITEMS + ["nothing"]]
            if items:
                out[qid] = "nothing" if "nothing" in items and len(items) == 1 else ",".join(i for i in items if i != "nothing")
        elif qid == "q_ask" and val in ("yes", "no", "agreed"):
            out[qid] = val
        elif val in ("yes", "no"):
            out[qid] = val
    return out
