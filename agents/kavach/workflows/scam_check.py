"""scam_check (spec 7, 7a): search the community corpus, check links, classify with the evidence,
apply the community floor, store the verdict with `save_message_check`, reply via the outbox.

Tool calls (max 6): get_person, search_community, check_link, save_message_check, read back, enqueue_outbox.
"""
from __future__ import annotations

import json
import re
import time
from functools import lru_cache
from typing import Any

from ..community import SearchResult, VERDICT_RANK, local_floor, max_verdict
from ..config import SHARED_DIR
from ..llm import prompt
from ..log import log
from ..redact import redact
from ..stdb import new_key, q
from .base import BadRequest, NotFound, Run, clamp, outbox_args, tactic_words

SOURCES = {"imessage", "share", "app_paste", "screenshot", "call"}
LABELS = {"likely_scam": "Likely scam", "suspicious": "Suspicious", "safe": "Looks safe"}
FALLBACK_REASON = "I couldn't check this right now. Don't reply or tap any links, and ask someone you trust."

TACTIC_WEIGHT = {
    "code_request": 3, "gift_card_request": 3, "remote_access": 3, "secrecy": 2, "upfront_fee": 2, "new_number": 2,
    "prize": 2, "money_request": 2, "recovery_offer": 1.5, "payment_link": 1.5, "job_offer": 1.5, "fee_threat": 1,
    "urgency": 1, "impersonation": 1,
}
TIPS = {
    "link": "Don't tap the link. Go to the official app or website yourself.",
    "code_request": "Never share a code, even with someone who says they're support.",
    "gift_card_request": "No real company or agency asks to be paid in gift cards.",
    "secrecy": "Real family and companies never ask you to keep it secret. Tell someone you trust.",
    "new_number": "Check with them on the number you already have saved, or text \"verify\" and their name.",
    "remote_access": "Don't install any app someone asks you to install.",
    "upfront_fee": "Don't pay any fee to receive money.",
    "recovery_offer": "Don't pay anyone who offers to recover lost money.",
    "money_request": "Don't send money until you've checked on a number you know.",
    "job_offer": "Real jobs don't pay you to like products or ask for deposits.",
    "prize": "You can't win a prize you didn't enter.",
    "number": "Don't call or text this number back.",
    "default": "When in doubt, don't reply, and ask someone you trust.",
}


@lru_cache(maxsize=1)
def demo_messages() -> list[dict[str, Any]]:
    seed = json.loads((SHARED_DIR / "seed" / "demo.json").read_text())
    return seed.get("demo_messages", [])


def _norm(t: str) -> str:
    return " ".join((t or "").lower().split())


def demo_cached(text: str) -> dict[str, Any] | None:
    n = _norm(text)
    return next((m for m in demo_messages() if _norm(m["text"]) == n), None)


def quotes_evidence(text: str, excerpts: list[str], n: int = 6) -> bool:
    """True if `text` shares an n-word run with any evidence excerpt (reports must never be quoted)."""
    words = re.findall(r"[a-z0-9$']+", (text or "").lower())
    grams = {" ".join(words[i : i + n]) for i in range(len(words) - n + 1)}
    for ex in excerpts:
        ew = re.findall(r"[a-z0-9$']+", (ex or "").lower())
        if grams & {" ".join(ew[i : i + n]) for i in range(len(ew) - n + 1)}:
            return True
    return False


def heuristic_verdict(search: SearchResult, links: list[dict]) -> tuple[str, list[str], float]:
    """No-model classifier, standing in for MODEL_FAST: judges the content (tactics, link risk, reported
    phrases, similar-report tactics). Exact number/link reports are not counted here: like a real model
    verdict, it is raised afterwards by the community floor (local_floor + save_message_check)."""
    tactics = list(search.signals.tactics)
    score = sum(TACTIC_WEIGHT.get(t, 0.5) for t in tactics)
    for link in links:
        score += {"high": 3, "medium": 1.5}.get(link["risk"], 0)
    for e in search.evidence:
        if e.kind == "exact_phrase":
            score += 2
        elif e.kind.startswith("similar"):
            for t in e.tactics:
                if t not in tactics:
                    tactics.append(t)
    verdict = "likely_scam" if score >= 4 else "suspicious" if score >= 2 else "safe"
    return verdict, tactics, score


def template_reason(verdict: str, search: SearchResult, links: list[dict], tactics: list[str]) -> str:
    kinds = {e.kind for e in search.evidence}
    camp = search.campaign_title.lower() if search.campaign_title else ""
    tw = tactic_words(tactics, 2)
    if verdict == "safe":
        return "I didn't find warning signs or community reports for this. If anything feels off, check with someone you trust."
    parts = []
    if "exact_link" in kinds:
        parts.append("The link goes to a site many people have reported as a scam.")
    elif "exact_number" in kinds:
        parts.append("This number has been reported by other people as a scammer.")
    elif any(link["risk"] == "high" for link in links):
        parts.append("The link is a fake-looking web address, not the real company's site.")
    if search.similarity_floor or "similar_campaign" in kinds or "similar_report" in kinds:
        parts.append(f"It matches a pattern many people have reported{f' ({camp})' if camp else ''}.")
    if tw and len(parts) < 2:
        parts.append(f"It uses common scam tricks: {', '.join(tw)}.")
    lead = "This looks like a scam." if verdict == "likely_scam" else "This could be a scam."
    return clamp(" ".join([lead] + parts), 300)


def template_tips(search: SearchResult, links: list[dict], tactics: list[str]) -> list[str]:
    tips: list[str] = []
    if links and any(link["risk"] != "low" for link in links):
        tips.append(TIPS["link"])
    for t in ("code_request", "gift_card_request", "remote_access", "new_number", "secrecy", "upfront_fee",
              "recovery_offer", "money_request", "job_offer", "prize"):
        if t in tactics and TIPS[t] not in tips:
            tips.append(TIPS[t])
    if any(e.kind == "exact_number" for e in search.evidence):
        tips.append(TIPS["number"])
    if not tips:
        tips.append(TIPS["default"])
    return tips[:3]


def reply_body(app: str, verdict: str, reason: str, tips: list[str]) -> str:
    return clamp(f"{app}: {LABELS[verdict]}. {reason} {' '.join(tips[:2])}")


def fallback_output() -> dict[str, Any]:
    return {"verdict": "suspicious", "reason": FALLBACK_REASON, "campaign_id": 0,
            "tips": ["Don't reply or tap any links.", "Ask someone you trust."], "evidence_count": 0}


async def send_fallback_reply(run: Run, payload: dict[str, Any]) -> None:
    to = payload.get("reply_to_e164") or ""
    if not to:
        return
    await run.db.call("enqueue_outbox", outbox_args(
        to, payload.get("reply_channel") or "imessage", "reply", f"{run.app}: {FALLBACK_REASON}"))


async def run_scam_check(run: Run, p: dict[str, Any], *, queue_reply: bool = True) -> dict[str, Any]:
    person_id = int(p.get("person_id") or 0)
    if not person_id:
        raise BadRequest("person_id required")
    source = p.get("source") or "imessage"
    if source not in SOURCES:
        raise BadRequest(f"invalid source: {source}")
    sender = p.get("sender_e164") or ""
    text = (p.get("text") or "").strip()
    if not text and p.get("image_base64"):
        text = await run.llm.vision_text(p["image_base64"], workflow=run.workflow)
    if not text:
        raise BadRequest("text required (screenshot text could not be read)")

    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    run.fields["person_id"] = person_id

    search: SearchResult = await run.tools.call("search_community", {"text": text, "sender_e164": sender})
    sig = search.signals
    links = await run.tools.call("check_link", {"urls": sig.urls}) if sig.urls else []

    cached = demo_cached(text) if run.s.demo_mode else None
    corpus_camps = {}
    if cached:
        from ..community import load_corpus

        corpus_camps = {c.get("slug"): int(c["id"]) for c in (await load_corpus(run.db))["campaigns"]}
        model_verdict = cached["verdict"]
        reason, tips = cached["reason"], list(cached.get("tips", []))
        tactics = list(sig.tactics)
        campaign_id = corpus_camps.get(cached.get("campaign_slug") or "", 0) or search.campaign_id
        run.fields["method"] = "demo_cache"
    else:
        model_verdict, tactics, reason, tips = await classify(run, text, search, links)
        campaign_id = search.campaign_id if (search.has_community_match or search.evidence) else 0
        run.fields["method"] = "model" if run.llm.models.enabled else f"heuristic+{search.method}"

    floor = local_floor(search, person, sig.text_redacted, int(time.time() * 1_000_000))
    verdict = max_verdict(model_verdict, floor)
    if VERDICT_RANK[verdict] > VERDICT_RANK[model_verdict] and not cached:
        # The community raised the verdict: say so (without quoting anyone's report).
        reason = template_reason(verdict, search, links, tactics)
        tips = template_tips(search, links, tactics)

    key = new_key()
    await run.tools.call("reducer", {"name": "save_message_check", "args": {
        "request_key": key, "person_id": person_id, "source": source, "content": redact(text)[:1000],
        "model_verdict": model_verdict, "reason": clamp(reason, 300), "campaign_id": int(campaign_id or 0),
        "sender_e164": sig.sender_e164, "link_domains": sig.domains,
        "similarity_floor": search.similarity_floor, "tactics": tactics[:8],
        "evidence_count": len(search.evidence),
    }})
    rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_message_check WHERE request_key = {q(key)}"})
    stored = rows[0] if rows else None
    if stored:
        if stored["verdict"] != verdict:
            verdict = stored["verdict"]
            reason = template_reason(verdict, search, links, tactics)
            tips = template_tips(search, links, tactics)
        campaign_id = int(stored.get("campaign_id") or 0)
    run.fields.update(model_verdict=model_verdict, stored_verdict=verdict, evidence_count=len(search.evidence),
                      similarity_floor=search.similarity_floor or "none")

    out = {"verdict": verdict, "reason": clamp(reason, 300), "campaign_id": campaign_id,
           "tips": [clamp(t, 160) for t in tips[:3]], "evidence_count": len(search.evidence)}

    to = p.get("reply_to_e164") or ""
    if queue_reply and to:
        body = reply_body(run.app, verdict, out["reason"], out["tips"])
        if not (await run.guard.check_output(body)).ok:
            body = reply_body(run.app, verdict, template_reason(verdict, search, links, tactics),
                              template_tips(search, links, tactics))
        await run.tools.call("reducer", {"name": "enqueue_outbox", "args": outbox_args(
            to, p.get("reply_channel") or "imessage", "reply", body,
            "urgent" if verdict == "likely_scam" else "normal")})
    return out


async def classify(run: Run, text: str, search: SearchResult, links: list[dict]) -> tuple[str, list[str], str, list[str]]:
    """MODEL_FAST classifies with the evidence in context; MODEL_WRITER words the reply.
    Falls back to the heuristic classifier and templates."""
    h_verdict, h_tactics, _ = heuristic_verdict(search, links)
    excerpts = [e.excerpt for e in search.evidence if e.excerpt]
    facts = {
        "message_redacted": search.signals.text_redacted[:1200],
        "sender_e164": search.signals.sender_e164,
        "claimed_identity": search.signals.claimed_identity,
        "detected_tactics": search.signals.tactics,
        "links": links,
        "community_evidence": search.evidence_for_model(),
        "community_floor": search.floor,
    }
    model = await run.llm.json("fast", prompt("scam_check"), json.dumps(facts, ensure_ascii=False),
                               "scam_check.model", workflow=run.workflow)
    if not model:
        return h_verdict, h_tactics, template_reason(h_verdict, search, links, h_tactics), template_tips(search, links, h_tactics)

    verdict = model["verdict"]
    tactics = [t for t in model.get("tactics", []) if re.fullmatch(r"[a-z_]{2,32}", t)] or h_tactics
    reason, tips = model["reason"], model.get("tips", [])
    writer = await run.llm.json("writer", prompt("scam_check_reply"), json.dumps(
        {"verdict": verdict, "draft_reason": reason, "tactics": tactics, "links": links,
         "community_match": search.has_community_match or bool(search.evidence),
         "campaign": search.campaign_title}, ensure_ascii=False),
        "scam_check.reply", workflow=run.workflow, timeout=5.0)
    if writer:
        reason, tips = writer["reason"], writer["tips"]
    if quotes_evidence(reason + " " + " ".join(tips), excerpts) or not (await run.guard.check_output(reason + " " + " ".join(tips))).ok:
        log("reason_replaced", workflow=run.workflow, outcome="quoted_or_unsafe")
        reason, tips = template_reason(verdict, search, links, tactics), template_tips(search, links, tactics)
    return verdict, tactics, reason, tips or template_tips(search, links, tactics)
