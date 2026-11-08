"""briefing (spec 7) and practice (Stretch).

briefing: summarize the week's incidents and checks, add one habit and current campaigns, then
`save_briefing` (which also texts it). Tool calls: get_person, read incidents, read checks, save = 4.
practice: pick a template, write a harmless practice text (no links, never asks for anything real),
queue it. Tool calls: read drill, get_person, enqueue = 3.
"""
from __future__ import annotations

import json
import time
from typing import Any

from ..community import load_corpus
from ..llm import prompt
from ..log import log
from .base import MAX_BRIEFING, BadRequest, NotFound, Run, clamp, outbox_args

WEEK_US = 7 * 24 * 3600 * 1_000_000
HABITS = [
    "Before you tap a link in a text, open the company's app or website yourself instead.",
    "If someone rushes you or asks you to keep a secret, hang up and call a family member.",
    "Ask callers who say they're family for your family code word.",
    "No real company asks to be paid with gift cards. If anyone asks, it's a scam.",
]


def compose_briefing(app: str, name: str, incidents: list[dict], checks: list[dict], campaigns: list[dict],
                     week_index: int = 0) -> tuple[str, str]:
    scams = [c for c in checks if c.get("verdict") in ("likely_scam", "suspicious")]
    wins = [i for i in incidents if i.get("severity") in ("low", "medium")]
    serious = [i for i in incidents if i.get("severity") in ("high", "critical")]
    open_serious = [i for i in serious if i.get("status") != "resolved"]
    lines = [f"{app} weekly briefing for {name}."]
    if checks:
        lines.append(f"You checked {len(checks)} message{'s' if len(checks) != 1 else ''}; "
                     f"{len(scams)} looked like scams and you didn't fall for them.")
    else:
        lines.append("You didn't check any messages this week.")
    if wins:
        lines.append(f"You handled {len(wins)} scam call{'s' if len(wins) != 1 else ''} without sharing anything. Well done.")
    if serious:
        lines.append(f"{len(serious)} incident{'s' if len(serious) != 1 else ''} needed extra steps"
                     + (f"; {len(open_serious)} still has steps left in the app." if open_serious else ", and all are wrapped up."))
    top = sorted(campaigns, key=lambda c: -int(c.get("weekly_reports") or 0))[:2]
    if top:
        lines.append("Going around this week: " + "; ".join(c["title"].lower() for c in top) + ".")
    habit = HABITS[week_index % len(HABITS)]
    lines.append(f"This week's habit: {habit}")
    summary = clamp(" ".join(lines), MAX_BRIEFING)
    spoken = [f"Here's your {app} briefing, {name}."]
    spoken.append(f"You checked {len(checks)} messages, and {len(scams)} were scams." if checks else "No messages were checked this week.")
    if wins:
        spoken.append(f"You stopped {len(wins)} scam calls. Well done.")
    if open_serious:
        spoken.append("You still have a few steps left in the app.")
    if top:
        spoken.append(f"Watch out for {top[0]['title'].lower()}.")
    spoken.append(habit)
    return summary, " ".join(spoken)


async def run_briefing(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    person_id = int(p.get("person_id") or 0)
    if not person_id:
        raise BadRequest("person_id required")
    run.fields["person_id"] = person_id
    person = await run.tools.call("get_person", {"person_id": person_id})
    if not person:
        raise NotFound("unknown person")
    now = int(time.time() * 1_000_000)
    since = now - WEEK_US
    incidents = [i for i in await run.tools.call("read", {"query": f"SELECT * FROM svc_incident WHERE person_id = {person_id}"})
                 if int(i.get("created_at") or 0) >= since]
    checks = [c for c in await run.tools.call("read", {"query": f"SELECT * FROM svc_message_check WHERE person_id = {person_id}"})
              if int(c.get("created_at") or 0) >= since]
    campaigns = (await load_corpus(run.db))["campaigns"]
    week_index = now // WEEK_US
    summary, spoken = compose_briefing(run.app, person.get("display_name") or "friend", incidents, checks, campaigns, week_index)

    model = await run.llm.json("writer", prompt("briefing"), json.dumps({
        "name": person.get("display_name"), "draft_summary": summary, "draft_spoken": spoken}, ensure_ascii=False),
        "briefing.model", workflow=run.workflow, max_tokens=600, timeout=8.0)
    if model and (await run.guard.check_output(model["summary_text"] + " " + model["spoken_text"])).ok:
        summary, spoken = clamp(model["summary_text"], MAX_BRIEFING), clamp(model["spoken_text"], 2000)
    await run.tools.call("reducer", {"name": "save_briefing", "args": {
        "person_id": person_id, "week_start_micros": since, "summary_text": summary, "spoken_text": spoken}})
    return {"summary_text": summary, "spoken_text": spoken}


PRACTICE_TEMPLATES = {
    "new_number": "Hi, it's me! I got a new phone and this is my new number. Text me back here when you can?",
    "toll": "Toll notice: you have an unpaid toll from last week. Reply to this message to see details.",
    "carrier_code": "This is your phone carrier's security team. We noticed unusual activity on your line. Reply to this message to talk to us.",
    "prize": "Congratulations! You've been selected for a special reward. Reply to this message to find out more.",
    "grandchild": "Grandpa, it's me. I'm in a bit of trouble and I don't want mom to know. Can you text me back?",
}


async def run_practice(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    drill_id = int(p.get("drill_id") or 0)
    if not drill_id:
        raise BadRequest("drill_id required")
    run.fields["drill_id"] = drill_id
    rows = await run.tools.call("read", {"query": f"SELECT * FROM svc_drill WHERE id = {drill_id}"})
    if not rows:
        raise NotFound("unknown drill")
    drill = rows[0]
    person = await run.tools.call("get_person", {"person_id": int(drill["person_id"])})
    if not person:
        raise NotFound("unknown person")
    if not person.get("practice_consent"):
        raise BadRequest("practice consent is off")
    template = PRACTICE_TEMPLATES.get(drill.get("template_key") or "", PRACTICE_TEMPLATES["new_number"])
    body = template
    model = await run.llm.json("writer", prompt("practice"), json.dumps({"template": template}),
                               "practice.model", workflow=run.workflow, timeout=6.0)
    if model:
        body = model["body"]
    if not (await run.guard.check_output(body, kind="practice")).ok:
        log("practice_rail_blocked", workflow=run.workflow, drill_id=drill_id)
        body = template
    body = clamp(body, 600)
    await run.tools.call("reducer", {"name": "enqueue_outbox", "args": outbox_args(
        person["phone_e164"], "imessage", "practice", body, "normal")})
    return {"body": body}
