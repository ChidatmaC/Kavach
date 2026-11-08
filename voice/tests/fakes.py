"""In-memory fakes for SpacetimeDB and the agent service (unit tests, no network)."""
from __future__ import annotations

import asyncio
from typing import Any

from config import Config


def make_cfg(**over) -> Config:
    base = dict(
        app_name="Kavach", spacetime_uri="http://x", db_name="t", voice_token="tok",
        agent_url="http://a", agent_token="", agent_timeout_s=2.0, filler_after_s=5.0,
        family_alert_wait_s=0.3,
    )
    base.update(over)
    return Config(**base)


class FakeStdb:
    def __init__(self, persons: dict[str, dict] | None = None):
        self.persons = persons or {}
        self.calls: list[tuple[str, dict]] = []
        self.incidents: dict[int, dict] = {}
        self.steps: list[dict] = []
        self.alerts: list[dict] = []
        self.evidence: list[dict] = []
        self.reports: dict[str, int] = {}

    async def call(self, reducer: str, args: dict[str, Any]) -> None:
        self.calls.append((reducer, dict(args)))
        if reducer == "open_incident":
            iid = len(self.incidents) + 1
            self.incidents[iid] = {"id": iid, "request_key": args["request_key"], "person_id": args["person_id"],
                                   "severity": "", "shared_items": [], "answers_json": "{}", "tactics": [],
                                   "claimed_identity": "", "campaign_id": 0, "summary_redacted": ""}
        elif reducer == "save_answer" and args["question_id"] == "q_summary":
            self.incidents[args["incident_id"]]["summary_redacted"] = args["answer"]

    async def aclose(self):
        pass

    def reducer_calls(self, name: str) -> list[dict]:
        return [a for r, a in self.calls if r == name]

    async def person_by_phone(self, phone):
        return self.persons.get(phone)

    async def incident_by_key(self, key):
        return next((i for i in self.incidents.values() if i["request_key"] == key), None)

    async def incident(self, iid):
        return self.incidents.get(iid)

    async def recovery_steps(self, iid):
        return self.steps

    async def family_alerts(self, iid):
        return self.alerts

    async def number_report(self, phone):
        n = self.reports.get(phone)
        return {"kind": "number", "value": phone, "reporter_count": n} if n else None

    async def hotline_evidence(self):
        return self.evidence

    def set_severity(self, sev: str, shared: list[str] | None = None):
        for inc in self.incidents.values():
            inc["severity"] = sev
            inc["shared_items"] = shared or []


class FakeAgent:
    """Scripted interview: returns the queued responses in order."""

    def __init__(self, script: list[dict] | None = None, stdb: FakeStdb | None = None,
                 delay: float = 0.0, intent: str = "interview"):
        self.script = list(script or [])
        self.stdb = stdb
        self.delay = delay
        self.intent = intent
        self.interview_calls: list[dict] = []
        self.router_calls: list[dict] = []

    async def aclose(self):
        pass

    async def router(self, **kw):
        self.router_calls.append(kw)
        return {"intent": self.intent, "args": {}}

    async def interview(self, **kw):
        self.interview_calls.append(kw)
        if self.delay:
            await asyncio.sleep(self.delay)
        step = self.script.pop(0) if self.script else {"done": True, "severity": ""}
        if self.stdb is not None and "set_severity" in step:
            self.stdb.set_severity(*step["set_severity"])
        return {k: v for k, v in step.items() if k != "set_severity"}


class Recorder:
    def __init__(self):
        self.lines: list[str] = []
        self.hung_up = False

    async def speak(self, text: str):
        self.lines.append(text)

    async def hangup(self):
        self.hung_up = True

    def text(self) -> str:
        return "\n".join(self.lines)
