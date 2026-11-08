"""Shared run context and helpers for workflows."""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from ..config import Settings, settings
from ..guard import Guard, guard
from ..llm import LLM, ModelSet
from ..stdb import Stdb
from ..tools import Toolbox

MAX_BODY = 600
MAX_BRIEFING = 1200
OUT_CHANNELS = {"imessage", "sms", "rcs", "whatsapp", "push"}


class BadRequest(ValueError):
    """Input that can't be processed (HTTP 400)."""


class NotFound(LookupError):
    """Referenced row doesn't exist (HTTP 404)."""


@dataclass
class Run:
    workflow: str
    db: Stdb
    tools: Toolbox
    llm: LLM
    guard: Guard
    s: Settings
    started: float = field(default_factory=time.perf_counter)
    fields: dict[str, Any] = field(default_factory=dict)  # extra structured-log fields (no contents)

    @property
    def app(self) -> str:
        return self.s.app_name

    def elapsed(self) -> float:
        return time.perf_counter() - self.started


def make_run(workflow: str, db: Stdb, models: ModelSet | None = None, nat_tools: dict | None = None) -> Run:
    s = settings()
    return Run(
        workflow=workflow, db=db, tools=Toolbox(workflow, db, s.max_tool_calls, nat_tools),
        llm=LLM(models or ModelSet.from_env()), guard=guard(), s=s,
    )


def clamp(text: str, limit: int = MAX_BODY) -> str:
    text = " ".join((text or "").split())
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    for sep in (". ", "! ", "? "):
        i = cut.rfind(sep)
        if i > limit * 0.6:
            return cut[: i + 1]
    return cut.rsplit(" ", 1)[0] + "…"


def outbox_args(to_e164: str, channel: str, kind: str, body: str, priority: str = "normal",
                incident_id: int = 0, contact_id: int = 0, group_key: str = "") -> dict[str, Any]:
    if channel not in OUT_CHANNELS:
        channel = "imessage"
    return {
        "to_e164": to_e164, "channel": channel, "kind": kind,
        "body": clamp(body, MAX_BRIEFING if kind == "briefing" else MAX_BODY),
        "priority": priority if priority in ("urgent", "normal") else "normal",
        "related_incident_id": int(incident_id or 0), "recipient_contact_id": int(contact_id or 0),
        "group_key": group_key or "",
    }


def family_group_key(person_id: int, incident_id: int) -> str:
    return f"family:{person_id}:{incident_id}"


def can_alert_contact(person: dict, contact: dict, severity: str) -> bool:
    """Same rule as canAlertContact() in spacetime/src/lib.ts (pre-filter; the reducer decides)."""
    if int(contact.get("person_id", -1)) != int(person.get("id", -2)) or contact.get("consent_status") != "accepted":
        return False
    if not person.get("sharing_paused"):
        return True
    return severity == "critical" and bool(person.get("critical_overrides_pause")) and bool(contact.get("is_emergency_contact"))


def human_list(items: list[str]) -> str:
    items = [i for i in items if i]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


TACTIC_WORDS = {
    "urgency": "rushing you", "fee_threat": "threatening fees or penalties", "payment_link": "a payment link",
    "code_request": "asking for a security code", "gift_card_request": "asking for gift cards",
    "secrecy": "asking to keep it secret", "impersonation": "pretending to be someone trusted",
    "new_number": "claiming a new phone number", "recovery_offer": "offering to recover lost money",
    "upfront_fee": "asking for an upfront fee", "job_offer": "an unrealistic job offer", "prize": "a fake prize",
    "remote_access": "asking to install a remote-access app", "money_request": "asking for money",
    "org_impersonation": "claiming to be a bank, company or agency",
    "family_emergency": "a family emergency story",
    "legal_threat": "threatening arrest or legal trouble",
}

# Plain reasons used when a red flag (signals.risk_floor) sets the verdict.
RISK_REASONS = {
    "gift_cards": "Nobody legitimate asks to be paid in gift cards. That is a scam sign every time.",
    "code": "Anyone asking for a security code is trying to get into your accounts.",
    "remote_access": "Asking you to install an app so they can see your screen is how scammers take over devices.",
    "money_pressure": "It asks for money while pressuring you or claiming to be someone trusted. Real banks, agencies and family can wait while you check.",
    "recovery_fee": "Real agencies never charge a fee to return lost money.",
    "prize_link": "Unexpected offers of money or prizes with a link are a classic scam. Even a real company's name in the link doesn't make the offer real.",
    "money_or_impersonation": "It asks for money or claims to be someone you trust. Check with them on a number you already know before doing anything.",
}


def tactic_words(tactics: list[str], n: int = 3) -> list[str]:
    out = []
    for t in tactics:
        w = TACTIC_WORDS.get(t, t.replace("_", " "))
        if w not in out:
            out.append(w)
    return out[:n]
