"""family_alert (spec 7, 7a "Explained family alert format", 8, 12).

One explained alert (<= 600 chars): what kind of scam, what the caller claimed, tactics, what may
have been shared, the first two precautions, and a kind way to check in. Never message contents.
One outbox row per eligible contact, all sharing group_key family:<person_id>:<incident_id>.
Tool calls: get_incident, get_person, get_contacts, recovery_steps, enqueue (batch) = 5.
"""
from __future__ import annotations

import json
from typing import Any

from ..llm import prompt
from ..log import log
from .base import (BadRequest, NotFound, Run, can_alert_contact, clamp, family_group_key, human_list,
                   outbox_args, tactic_words)

ITEM_WORDS = {
    "code": "a security code", "pin": "a PIN", "password": "a password", "card": "card details",
    "gift_card": "gift card numbers", "money": "money", "remote_app": "access through an app they installed",
    "personal_details": "personal details", "link": "a tapped link",
}
FAMILY_STEP = {
    # Family-facing wording of the vetted steps (D10: same steps, worded for the helper).
    "call_bank_freeze_card": "help them call the number on their card to freeze it",
    "call_bank_stop_transfer": "help them call their bank's official number to stop the payment",
    "contact_carrier_account_lock": "help them call their phone carrier to lock the account",
    "change_password_reused": "help them change the password they shared",
    "enable_2fa": "help them turn on two-step sign-in",
    "gift_card_issuer": "help them call the gift card company to freeze the balance",
    "keep_receipts": "remind them to keep the cards and receipts",
    "uninstall_remote_app": "help them turn off Wi-Fi and delete the remote app",
    "device_checkup": "get their device checked",
    "credit_freeze": "help them freeze their credit (free at Equifax, Experian and TransUnion)",
    "watch_statements": "watch their bank statements this week",
    "password_change_link": "help them change any password typed on that page",
    "report_ftc": "help them report it at ReportFraud.ftc.gov",
    "report_ic3": "help them report it at ic3.gov",
    "tell_family": "stay in touch with them today",
}
CHECK_IN = {
    "critical": "Call them now and stay calm: \"I heard what happened. You're not in trouble. Let's sort it out together.\"",
    "high": "A kind way to check in: \"Hey, I heard about that call. Want to go through it together?\"",
    "default": "A kind way to check in: \"I heard you dodged a scam. Proud of you. Want to talk about it?\"",
}


def scam_kind(inc: dict, campaign_title: str) -> str:
    if campaign_title:
        return campaign_title.lower()
    ident = (inc.get("claimed_identity") or "").lower()
    if any(w in ident for w in ("grand", "son", "daughter", "nephew", "niece", "family")):
        return "family emergency scam"
    if any(w in ident for w in ("bank", "fraud", "carrier", "mobile", "verizon")):
        return "fake fraud department scam"
    if any(w in ident for w in ("irs", "social security", "police", "medicare", "government")):
        return "government impersonation scam"
    return "scam " + ("call" if inc.get("entry_point") in ("companion", "report_swipe", "hotline") else "message")


def explained_alert(app: str, person: dict, inc: dict, steps: list[dict], campaign_title: str = "") -> str:
    """Deterministic explained alert (no model). Different from the module's template fallback."""
    name = person.get("display_name") or "Your family member"
    sev = inc.get("severity") or ""
    shared = [s for s in (inc.get("shared_items") or []) if s != "nothing"]
    head = "URGENT. " if sev == "critical" else ""
    what = (f"a known scam ({campaign_title.lower()})" if campaign_title else f"a {scam_kind(inc, '')}")
    parts = [f"{app} family alert. {head}{name} was targeted by {what}."]
    if inc.get("claimed_identity"):
        parts.append(f"The caller claimed to be {inc['claimed_identity']}.")
    tw = tactic_words(list(inc.get("tactics") or []), 3)
    if tw:
        parts.append(f"Tactics: {', '.join(tw)}.")
    parts.append(f"They may have shared {human_list([ITEM_WORDS.get(s, s) for s in shared])}." if shared
                 else "They didn't share anything.")
    first = [FAMILY_STEP.get(s["key"], "") for s in steps[:2] if FAMILY_STEP.get(s["key"])]
    if first:
        parts.append(f"First: {human_list(first)}.")
    parts.append(CHECK_IN.get(sev, CHECK_IN["default"]))
    if sev == "critical":
        parts.append("Reply \"I'm calling\" if you're on it.")
    body = " ".join(parts)
    if len(body) > 600:  # drop the least important parts first
        parts = [x for x in parts if not x.startswith("Tactics:")]
        body = " ".join(parts)
    return clamp(body, 600)


async def run_family_alert(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    incident_id = int(p.get("incident_id") or 0)
    if not incident_id:
        raise BadRequest("incident_id required")
    priority = p.get("priority") if p.get("priority") in ("urgent", "normal") else "normal"
    run.fields["incident_id"] = incident_id
    inc = await run.tools.call("get_incident", {"incident_id": incident_id})
    if not inc:
        raise NotFound("unknown incident")
    person_id = int(inc.get("person_id") or 0)
    if not person_id:
        return {"alerts": []}  # unregistered hotline caller: nobody to alert
    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    contacts = await run.tools.call("get_contacts", {"person_id": person_id})
    sev = inc.get("severity") or ""
    eligible = [c for c in contacts if can_alert_contact(person, c, sev)]
    if not eligible:
        log("family_alert_none_eligible", workflow=run.workflow, incident_id=incident_id)
        return {"alerts": []}

    steps = await run.tools.call("recovery_steps", {"shared_items": list(inc.get("shared_items") or []),
                                                    "critical": sev == "critical"})
    from ..community import load_corpus

    camps = {int(c["id"]): c for c in (await load_corpus(run.db))["campaigns"]}
    camp = camps.get(int(inc.get("campaign_id") or 0), {})
    body = await write_alert(run, person, inc, steps, camp)

    calls = [{"name": "enqueue_outbox", "args": outbox_args(
        c["phone_e164"], c.get("channel") or "sms", "family_alert", body, priority, incident_id, int(c["id"]),
        family_group_key(person_id, incident_id))} for c in eligible]
    from ..tools import checked_reducers

    results = await checked_reducers(run.tools, calls)
    alerts = [{"contact_id": int(c["id"]), "body": body} for c, r in zip(eligible, results) if r["ok"]]
    unexpected = [r for r in results if not r["ok"] and "refused" not in r.get("error", "")]
    if not alerts and unexpected:
        # Nothing queued for a reason other than consent/pause: fail so the module sends its template.
        raise RuntimeError("no family alerts could be queued")
    if alerts:
        from ..tools import ALERTED_INCIDENTS

        ALERTED_INCIDENTS.add(incident_id)
    run.fields["count"] = len(alerts)
    return {"alerts": alerts}


async def write_alert(run: Run, person: dict, inc: dict, steps: list[dict], camp: dict) -> str:
    """MODEL_WRITER words the alert from incident fields only; falls back to the explained template."""
    fallback = explained_alert(run.app, person, inc, steps, camp.get("title", ""))
    facts = {
        "person_name": person.get("display_name"), "severity": inc.get("severity"),
        "scam_kind": scam_kind(inc, camp.get("title", "")), "campaign_summary": camp.get("tactic_summary", ""),
        "claimed_identity": inc.get("claimed_identity"), "tactics": tactic_words(list(inc.get("tactics") or []), 4),
        "shared": [ITEM_WORDS.get(s, s) for s in (inc.get("shared_items") or [])],
        "first_two_steps": [FAMILY_STEP.get(s["key"], s["text"]) for s in steps[:2]],
    }
    model = await run.llm.json("writer", prompt("family_alert"), json.dumps(facts, ensure_ascii=False),
                               "family_alert.model", workflow=run.workflow, timeout=7.0)
    if not model:
        return fallback
    body = clamp(model["body"], 600)
    if not body.startswith(run.app):
        body = clamp(f"{run.app}: {body}", 600)
    if not (await run.guard.check_output(body)).ok:
        log("family_alert_rail_blocked", workflow=run.workflow, incident_id=inc.get("id"))
        return fallback
    return body
