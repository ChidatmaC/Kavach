"""verify_relative (spec 7) and trusted_sender (Stretch).

verify_relative: find the named contact. If the claim came from an unknown number (or none given),
text the relative's saved number. If it came from the relative's own number, prompt a direct call
and ask another family member. Either way start the verification deadline.
Tool calls: get_contacts, get_person, start_verification, read back, enqueue (batch) = 5.
"""
from __future__ import annotations

import re
from typing import Any

from ..redact import redact
from ..signals import to_e164
from ..stdb import new_key, q
from .base import BadRequest, NotFound, Run, clamp, outbox_args

RELATIONSHIP_WORDS = {"son", "daughter", "grandson", "granddaughter", "nephew", "niece", "brother", "sister",
                      "wife", "husband", "mom", "dad", "mother", "father", "grandma", "grandpa", "friend"}


def find_contact(contacts: list[dict], name: str) -> dict | None:
    n = re.sub(r"[^a-z ]", "", (name or "").lower()).strip()
    n = re.sub(r"^(my|our)\s+", "", n)
    if not n:
        return None
    for c in contacts:
        if c.get("name", "").lower() == n:
            return c
    for c in contacts:
        cn = c.get("name", "").lower()
        if cn.split(" ")[0] == n.split(" ")[0] or cn.startswith(n) or n.startswith(cn):
            return c
    if n in RELATIONSHIP_WORDS or n.rstrip("s") in RELATIONSHIP_WORDS:
        for c in contacts:
            if c.get("relationship", "").lower() == n:
                return c
    return None


async def run_verify_relative(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    person_id = int(p.get("person_id") or 0)
    name = (p.get("relative_name") or "").strip()
    if not person_id or not name:
        raise BadRequest("person_id and relative_name required")
    run.fields["person_id"] = person_id
    contacts = await run.tools.call("get_contacts", {"person_id": person_id})
    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    pname = person.get("display_name") or "Your family member"
    rel = find_contact(contacts, name)
    if not rel:
        body = (f"{run.app}: I couldn't find \"{clamp(name, 40)}\" in your family contacts. Until you reach them on a "
                "number you already know, treat the message as a scam and don't send anything.")
        await run.tools.call("reducer", {"name": "enqueue_outbox",
                                         "args": outbox_args(person["phone_e164"], "imessage", "verification", body, "normal")})
        return {"verification_id": 0, "messages": [{"to_e164": person["phone_e164"], "channel": "imessage", "body": body}]}

    claim = to_e164(p.get("claim_from_e164") or "") if p.get("claim_from_e164") else ""
    from_own_number = bool(claim) and claim == rel.get("phone_e164")
    key = new_key()
    await run.tools.call("reducer", {"name": "start_verification", "args": {
        "request_key": key, "person_id": person_id, "contact_id": int(rel["id"]), "kind": "relay"}})
    rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_verification WHERE request_key = {q(key)}"})
    vid = int(rows[0]["id"]) if rows else 0
    run.fields["verification_id"] = vid
    rname = rel["name"]
    msgs: list[dict[str, Any]] = []

    if not from_own_number:
        msgs.append({"to_e164": rel["phone_e164"], "channel": rel.get("channel") or "sms",
                     "body": f"{run.app}: {pname} got a message from someone saying they're you. Was it really you? "
                             f"Reply YES if it was you, or NO if it wasn't."})
        msgs.append({"to_e164": person["phone_e164"], "channel": "imessage",
                     "body": f"{run.app}: I've texted {rname} on their saved number to check. Don't send anything or "
                             f"share any codes until they answer. I'll tell you as soon as they reply."})
    else:
        others = [c for c in contacts if c["id"] != rel["id"] and c.get("consent_status") == "accepted"]
        helper = next((c for c in others if c.get("is_emergency_contact")), others[0] if others else None)
        msgs.append({"to_e164": person["phone_e164"], "channel": "imessage",
                     "body": f"{run.app}: That message came from {rname}'s own number, but numbers and accounts can be "
                             f"hacked. Call {rname} directly on the number you know and ask for your family code word. "
                             f"Don't send anything until you've talked to them."
                             + (f" I've also asked {helper['name']} to check." if helper else "")})
        if helper:
            msgs.append({"to_e164": helper["phone_e164"], "channel": helper.get("channel") or "sms",
                         "body": f"{run.app}: {pname} got a message from {rname}'s number asking for help. Can you reach "
                                 f"{rname} directly and check it's really them? Please call {pname} after."})
        msgs.append({"to_e164": rel["phone_e164"], "channel": rel.get("channel") or "sms",
                     "body": f"{run.app}: {pname} got a message from your number. Was it really you? "
                             f"Reply YES if it was you, or NO if it wasn't."})

    from ..tools import checked_reducers

    results = await checked_reducers(run.tools, [
        {"name": "enqueue_outbox", "args": outbox_args(m["to_e164"], m["channel"], "verification", m["body"],
                                                       "urgent", 0, int(rel["id"]) if m["to_e164"] == rel["phone_e164"] else 0)}
        for m in msgs])
    sent = [m for m, r in zip(msgs, results) if r["ok"]]
    return {"verification_id": vid, "messages": sent}


async def run_trusted_sender(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    """Stretch: flagged message from a contact who uses the app -> verification + push to their app."""
    person_id = int(p.get("person_id") or 0)
    contact_id = int(p.get("contact_id") or 0)
    if not person_id or not contact_id:
        raise BadRequest("person_id and contact_id required")
    run.fields["person_id"] = person_id
    contacts = await run.tools.call("get_contacts", {"person_id": person_id})
    c = next((x for x in contacts if int(x["id"]) == contact_id), None)
    if not c:
        raise NotFound("unknown contact")
    if not c.get("is_app_user"):
        raise BadRequest("contact does not use the app; use verify_relative")
    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    key = new_key()
    await run.tools.call("reducer", {"name": "start_verification", "args": {
        "request_key": key, "person_id": person_id, "contact_id": contact_id, "kind": "trusted_sender"}})
    rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_verification WHERE request_key = {q(key)}"})
    vid = int(rows[0]["id"]) if rows else 0
    run.fields["verification_id"] = vid
    excerpt = clamp(redact(p.get("message_text") or ""), 140)
    pname = person.get("display_name") or "your family member"
    from ..tools import checked_reducers

    await checked_reducers(run.tools, [
        {"name": "enqueue_outbox", "args": outbox_args(
            c["phone_e164"], "push", "verification",
            f"Did you send this to {pname}? \"{excerpt}\" Tap Yes or No.", "urgent", 0, contact_id)},
        {"name": "enqueue_outbox", "args": outbox_args(
            person["phone_e164"], "imessage", "verification",
            f"{run.app}: I'm checking with {c['name']} in their app that they really sent that. Don't send anything yet.",
            "normal")},
    ])
    return {"verification_id": vid}
