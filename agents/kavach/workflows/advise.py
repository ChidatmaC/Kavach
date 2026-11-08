"""advise: conversational answers to questions about the person's dealings with others
("my nephew wants gift cards, should I?", "a man from my bank says my account is locked, what do I do?").

Grounded the same way as scam_check: the community search (7a) and the red-flag floor set a minimum
verdict the model can't lower. MODEL_WRITER writes the answer with the last few messages of this
conversation in context, so follow-up questions work. The check is stored with save_message_check
(so it appears in the app and feeds the corpus when risky) and the reply goes out through the outbox.

Tool calls (max 6): get_person, search_community, read inbound history, read outbox history,
save_message_check, enqueue_outbox.
"""
from __future__ import annotations

import json
import re
import time
from typing import Any

from .. import training
from ..community import SearchResult, VERDICT_RANK, local_floor, max_verdict
from ..llm import prompt
from ..log import log
from ..redact import redact
from ..signals import risk_floor
from ..stdb import new_key, q
from .base import RISK_REASONS, BadRequest, NotFound, Run, clamp, outbox_args, tactic_words

HISTORY_WINDOW_S = 2 * 3600

# Red-flag reasons phrased for a person describing a situation (not a message they received).
ADVISE_RISK_REASONS = {
    "gift_cards": "Please don't. Nobody legitimate asks to be paid in gift cards, so this is a scam sign every time.",
    "code": "Never share a security code. Anyone asking for one is trying to get into your accounts.",
    "remote_access": "Don't install anything they ask for. Letting someone see your screen is how scammers take over devices.",
    "money_pressure": "This has the signs of a scam: money plus pressure, secrecy or someone claiming to be trusted. Real banks, agencies and family can wait while you check.",
    "recovery_fee": "Real agencies never charge a fee to return lost money.",
    "money_or_impersonation": "Be careful before sending money. Even when it seems to come from someone you know, accounts get hacked and voices get faked, so check with them on a number you already know first.",
}
HISTORY_TURNS = 8
LABELS = {"likely_scam": "Likely scam", "suspicious": "Be careful", "safe": "Probably fine"}
SAFE_DEFAULT_STEPS = [
    "Check with the person on a number you already know.",
    "Never send money, gift cards or codes because of a message or call.",
]
SHARED_PROMPT = 'If you already sent money or shared a code, reply "I sent it" and I\'ll walk you through what to do now.'


def _micros(v: Any) -> int:
    if isinstance(v, list):
        v = v[0] if v else 0
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


def build_history(inbound: list[dict], outbound: list[dict], now_micros: int, current_text: str) -> list[dict]:
    """Recent turns of this conversation, oldest first, redacted, excluding the message being answered."""
    since = now_micros - HISTORY_WINDOW_S * 1_000_000
    turns = [{"role": "person", "t": _micros(m.get("received_at")), "text": m.get("body") or ""} for m in inbound]
    turns += [{"role": "kavach", "t": _micros(m.get("created_at")), "text": m.get("body") or ""}
              for m in outbound if m.get("channel") != "push"]
    turns = [t for t in turns if t["t"] >= since and t["text"]]
    turns.sort(key=lambda t: t["t"])
    if turns and turns[-1]["role"] == "person" and turns[-1]["text"].strip() == current_text.strip():
        turns = turns[:-1]
    return [{"role": t["role"], "text": redact(t["text"])[:400]} for t in turns[-HISTORY_TURNS:]]


def template_answer(verdict: str, risk_why: str, search: SearchResult, tactics: list[str]) -> tuple[str, list[str]]:
    """No-model answer from the same evidence."""
    if risk_why:
        answer = ADVISE_RISK_REASONS[risk_why]
    elif search.has_community_match or search.evidence:
        answer = "This matches a pattern many people have reported as a scam."
    elif verdict == "safe":
        answer = "I don't see the usual scam signs here. If anything changes, like a request for money or secrecy, check with me again."
    else:
        tw = tactic_words(tactics, 2)
        answer = f"Be careful: it uses common scam tricks ({', '.join(tw)})." if tw else "Be careful with this one."
    steps = SAFE_DEFAULT_STEPS if verdict != "safe" else ["Trust your instincts, and ask me again if something feels off."]
    return answer, steps


_RESTATED_VERDICT = re.compile(
    r"^\s*(this|that|it)\s+(is|looks|seems|sounds)\s+(very\s+)?(like(ly)?\s+)?(a\s+)?(scam|safe|fine|suspicious)[^.!]*[.!]\s*",
    re.IGNORECASE)


def reply_body(app: str, verdict: str, answer: str, steps: list[str], add_shared_prompt: bool) -> str:
    # The label already states the verdict; drop an opening sentence that only repeats it.
    trimmed = _RESTATED_VERDICT.sub("", answer, count=1)
    answer = trimmed if len(trimmed) > 20 else answer
    label = LABELS[verdict]
    # When the answer already opens with the label ("Be careful before sending money…"), don't repeat it.
    body = f"{app}: {answer}" if answer.lower().startswith(label.lower()) else f"{app}: {label}. {answer}"
    # Skip next steps the answer already says (models often repeat "call him on a number you know").
    def _key(t: str) -> set[str]:
        return {w for w in re.findall(r"[a-z]+", t.lower()) if len(w) > 3}
    answer_words = _key(answer)
    steps = [st for st in steps if len(_key(st) - answer_words) >= max(2, len(_key(st)) // 2)]
    if steps:
        body += " " + " ".join(s if s.endswith(".") else s + "." for s in steps[:2])
    if add_shared_prompt:
        body += " " + SHARED_PROMPT
    return clamp(body)


async def run_advise(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    person_id = int(p.get("person_id") or 0)
    text = (p.get("text") or "").strip()
    if not person_id:
        raise BadRequest("person_id required")
    if not text:
        raise BadRequest("text required")
    run.fields["person_id"] = person_id

    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    search: SearchResult = await run.tools.call("search_community", {"text": text, "sender_e164": ""})
    phone = person.get("phone_e164") or ""
    inbound = await run.tools.call("read", {"query": f"SELECT * FROM svc_inbound_message WHERE from_e164 = {q(phone)}"})
    outbound = await run.tools.call("read", {"query": f"SELECT * FROM svc_outbox WHERE to_e164 = {q(phone)}"})
    now = int(time.time() * 1_000_000)
    history = build_history(inbound or [], outbound or [], now, text)

    tactics = list(search.signals.tactics)
    risk, risk_why = risk_floor(tactics, text)
    community = local_floor(search, person, search.signals.text_redacted, now)
    floor = max_verdict(community, risk)
    examples = training.few_shot(text)

    facts = {
        "question_redacted": search.signals.text_redacted[:1500],
        "conversation_so_far": history,
        "detected_tactics": tactics,
        "red_flag_floor": risk,
        "community_evidence": search.evidence_for_model(),
        "community_floor": search.floor,
        "minimum_verdict": floor,
    }
    if examples:
        facts["labeled_examples"] = [{"message_redacted": x["message_redacted"], "correct_verdict": x["correct_verdict"]}
                                     for x in examples]
    model = await run.llm.json("writer", prompt("advise"), json.dumps(facts, ensure_ascii=False), "advise.model",
                               workflow=run.workflow, max_tokens=500, timeout=8.0)

    if model:
        from .scam_check import quotes_evidence

        model_verdict = model["verdict"]
        answer, steps = model["answer"], [s for s in model.get("next_steps", []) if s][:3]
        already_shared = bool(model.get("already_shared"))
        tactics = list(dict.fromkeys(tactics + [t for t in model.get("tactics", []) if t.replace("_", "").isalpha()]))
        excerpts = [e.excerpt for e in search.evidence if e.excerpt] + [x["message_redacted"] for x in examples]
        if (quotes_evidence(answer + " " + " ".join(steps), excerpts)
                or not (await run.guard.check_output(answer + " " + " ".join(steps))).ok):
            log("answer_replaced", workflow=run.workflow, outcome="quoted_or_unsafe")
            answer, steps = template_answer(max_verdict(model_verdict, floor), risk_why, search, tactics)
        run.fields["method"] = "model" + (f"+fewshot{len(examples)}" if examples else "")
    else:
        model_verdict = floor
        answer, steps = template_answer(floor, risk_why, search, tactics)
        already_shared = False
        run.fields["method"] = "template"

    verdict = max_verdict(model_verdict, floor)
    if VERDICT_RANK[verdict] > VERDICT_RANK[model_verdict] and risk_why:
        # A red flag set the verdict: make sure the answer says why.
        answer = clamp(f"{ADVISE_RISK_REASONS[risk_why]} {answer}", 360)
    run.fields.update(model_verdict=model_verdict, verdict=verdict, risk_floor=risk or "safe",
                      evidence_count=len(search.evidence), history_turns=len(history))

    key = new_key()
    await run.tools.call("reducer", {"name": "save_message_check", "args": {
        "request_key": key, "person_id": person_id, "source": "imessage", "content": redact(text)[:1000],
        "model_verdict": model_verdict, "reason": clamp(answer, 300), "campaign_id": int(search.campaign_id or 0),
        "sender_e164": "", "link_domains": search.signals.domains,
        "similarity_floor": "" if max_verdict(search.similarity_floor or "safe", risk) == "safe"
        else max_verdict(search.similarity_floor or "safe", risk),
        "tactics": tactics[:8], "evidence_count": len(search.evidence),
    }})

    out = {"verdict": verdict, "answer": clamp(answer, 360), "next_steps": [clamp(s, 160) for s in steps[:3]],
           "evidence_count": len(search.evidence), "already_shared": already_shared}
    # The question is the person's own words about someone else: redacted, and history is not logged.
    training.log_decision(
        workflow="advise", person_id=person_id, text=text, tactics=tactics, evidence=search.evidence,
        model_verdict=model_verdict, final_verdict=verdict, reason=out["answer"], method=run.fields.get("method", ""),
        floors={"community": community, "similarity": search.similarity_floor or "", "exact": search.exact_floor or "",
                "risk": risk, "risk_why": risk_why},
        link_domains=search.signals.domains, check_request_key=key, extra={"already_shared": already_shared})
    to = p.get("reply_to_e164") or ""
    if to:
        body = reply_body(run.app, verdict, out["answer"], out["next_steps"],
                          add_shared_prompt=verdict != "safe" and not already_shared)
        if already_shared:
            body = clamp(body + " Tell me exactly what you sent or shared, and I'll walk you through what to do right now.")
        await run.tools.call("reducer", {"name": "enqueue_outbox", "args": outbox_args(
            to, p.get("reply_channel") or "imessage", "reply", body,
            "urgent" if verdict == "likely_scam" else "normal")})
    return out
