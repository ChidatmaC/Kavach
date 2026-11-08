"""Community-informed search (spec 7a, D14, D15).

`search_community` extracts signals, finds exact matches in `svc_community_report`, ranks similar
reports from `svc_report_evidence.text_redacted` and `campaign.sample_text`, and computes the
similarity floor. Evidence is for the model only; people only ever see verdicts and reasons.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any

from . import similarity
from .signals import Signals, extract_signals
from .stdb import Stdb, cached

LABEL_THRESHOLD = 3
TOP_K = 5
VERDICT_RANK = {"safe": 0, "suspicious": 1, "likely_scam": 2}
REFUND_RE = re.compile(r"(?i)\b(refund|recover(ed|y)?|reclaim|lost (money|funds)|release (fee|your)|compensation)\b")


def max_verdict(a: str, b: str) -> str:
    return a if VERDICT_RANK.get(a, 0) >= VERDICT_RANK.get(b, 0) else b


@dataclass
class Evidence:
    kind: str  # exact_number | exact_link | exact_phrase | similar_report | similar_campaign
    score: float
    reporter_count: int = 0
    campaign_id: int = 0
    campaign_title: str = ""
    tactics: list[str] = field(default_factory=list)
    verdict: str = ""
    excerpt: str = ""  # redacted; given to the model only, never to people

    def for_model(self) -> dict[str, Any]:
        d = asdict(self)
        d["score"] = round(self.score, 3)
        return d


@dataclass
class SearchResult:
    signals: Signals
    evidence: list[Evidence]
    similarity_floor: str  # "" | suspicious
    exact_floor: str  # "" | suspicious | likely_scam (mirrors the module's exact-match rule)
    campaign_id: int
    campaign_title: str
    method: str
    best_similarity: float

    @property
    def floor(self) -> str:
        return max_verdict(self.similarity_floor or "safe", self.exact_floor or "safe")

    @property
    def has_community_match(self) -> bool:
        return bool(self.exact_floor or self.similarity_floor)

    def evidence_for_model(self) -> list[dict[str, Any]]:
        return [e.for_model() for e in self.evidence]


async def load_corpus(db: Stdb) -> dict[str, list[dict[str, Any]]]:
    async def _reports():
        return await db.sql("SELECT * FROM svc_community_report")

    async def _evidence():
        return await db.sql("SELECT * FROM svc_report_evidence")

    async def _campaigns():
        return await db.campaigns()

    return {
        "reports": await cached(f"{db.db}:reports", 2.0, _reports),
        "evidence": await cached(f"{db.db}:evidence", 5.0, _evidence),
        "campaigns": await cached(f"{db.db}:campaigns", 5.0, _campaigns),
    }


def exact_matches(sig: Signals, reports: list[dict[str, Any]], camp_title: dict[int, str]) -> list[Evidence]:
    out: list[Evidence] = []
    norm_text = re.sub(r"\s+", " ", sig.text_redacted.lower())
    numbers = {n for n in [sig.sender_e164, *sig.phones_in_text] if n}
    for r in reports:
        kind, value = r.get("kind"), str(r.get("value", ""))
        hit = False
        if kind == "number" and value in numbers:
            hit = True
        elif kind == "link" and (value in sig.domains or any(u.split("/")[0] == value for u in sig.normalized_urls)):
            hit = True
        elif kind == "phrase" and value and value in norm_text:
            hit = True
        if hit:
            cid = int(r.get("campaign_id") or 0)
            out.append(Evidence(
                kind=f"exact_{kind}", score=1.0, reporter_count=int(r.get("reporter_count") or 0),
                campaign_id=cid, campaign_title=camp_title.get(cid, ""),
                verdict="likely_scam" if int(r.get("reporter_count") or 0) >= LABEL_THRESHOLD else "suspicious",
            ))
    return out


async def search_community(db: Stdb, text: str, sender_e164: str = "", extra_context: str = "") -> SearchResult:
    """Spec 7a search. `extra_context` lets call checks add the described script (claimed identity, asks)."""
    sig = extract_signals(text, sender_e164)
    corpus = await load_corpus(db)
    camps = corpus["campaigns"]
    camp_title = {int(c["id"]): c.get("title", "") for c in camps}

    evidence = exact_matches(sig, corpus["reports"], camp_title)
    exact_floor = ""
    for e in evidence:
        # Phrases are not part of the module's floor (it only checks numbers and link domains).
        if e.kind in ("exact_number", "exact_link"):
            exact_floor = max_verdict(exact_floor or "safe", e.verdict)
    if exact_floor == "safe":
        exact_floor = ""

    docs: list[tuple[str, dict[str, Any], str]] = []
    for ev in corpus["evidence"]:
        if ev.get("text_redacted"):
            docs.append(("similar_report", ev, ev["text_redacted"]))
    for c in camps:
        if c.get("sample_text"):
            docs.append(("similar_campaign", c, c["sample_text"]))

    query = " ".join(x for x in [sig.text_redacted, extra_context] if x).strip()
    method, scores = await similarity.score(query, [d[2] for d in docs]) if query else ("lexical", [])
    th = similarity.THRESHOLDS[method]
    ranked = sorted(zip(scores, docs), key=lambda x: -x[0])
    sims: list[Evidence] = []
    for sc, (kind, row, doc_text) in ranked:
        if sc < th["evidence"] or len(sims) >= TOP_K:
            break
        if kind == "similar_campaign":
            cid = int(row["id"])
            sims.append(Evidence(kind=kind, score=sc, reporter_count=int(row.get("weekly_reports") or 0),
                                 campaign_id=cid, campaign_title=row.get("title", ""), verdict="likely_scam",
                                 excerpt=row.get("tactic_summary", "")[:200]))
        else:
            cid = int(row.get("campaign_id") or 0)
            sims.append(Evidence(kind=kind, score=sc, campaign_id=cid, campaign_title=camp_title.get(cid, ""),
                                 tactics=list(row.get("tactics") or []), verdict=row.get("verdict", ""),
                                 excerpt=doc_text[:200]))
    best = sims[0].score if sims else 0.0
    sim_floor = ""
    if any(e.score >= th["floor"] and e.verdict == "likely_scam" for e in sims):
        sim_floor = "suspicious"

    all_ev = (evidence + sims)[: TOP_K + len(evidence)]
    campaign_id = next((e.campaign_id for e in all_ev if e.campaign_id), 0)
    return SearchResult(
        signals=sig, evidence=all_ev, similarity_floor=sim_floor, exact_floor=exact_floor,
        campaign_id=campaign_id, campaign_title=camp_title.get(campaign_id, ""), method=method, best_similarity=best,
    )


def local_floor(result: SearchResult, person: dict[str, Any] | None, text: str, now_micros: int) -> str:
    """Mirror of communityFloor() in spacetime/src/lib.ts, so the reason we store matches the verdict.
    The module recomputes this on save and its stored verdict is the one we reply with."""
    floor = result.floor
    if person:
        if int(person.get("recovery_watch_until") or 0) > now_micros and REFUND_RE.search(text or ""):
            floor = "likely_scam"
        if int(person.get("campaign_watch_until") or 0) > now_micros:
            if result.signals.sender_e164 and result.signals.sender_e164 == person.get("watch_caller_e164"):
                floor = max_verdict(floor, "likely_scam")
    return floor


async def lookup_community(db: Stdb, value: str) -> dict[str, Any]:
    """Spec 7 `lookup_community(value)`: report count, label status and campaign for a number, link or phrase."""
    from .signals import registrable_domain, to_e164

    v = value.strip()
    e = to_e164(v) if re.fullmatch(r"[+\d()\s.-]{7,}", v) else ""
    if e:
        kind, norm = "number", e
    elif "." in v and " " not in v:
        kind, norm = "link", registrable_domain(v)
    else:
        kind, norm = "phrase", re.sub(r"\s+", " ", v.lower())[:200]
    corpus = await load_corpus(db)
    for r in corpus["reports"]:
        if r.get("kind") == kind and r.get("value") == norm:
            return {"kind": kind, "value": norm, "reporter_count": int(r["reporter_count"]),
                    "label_visible": bool(r["label_visible"]), "campaign_id": int(r.get("campaign_id") or 0)}
    return {"kind": kind, "value": norm, "reporter_count": 0, "label_visible": False, "campaign_id": 0}
