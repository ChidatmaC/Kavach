"""Shared tools (spec 7 tools table) plus the per-run tool-call budget.

Every tool is also registered as a NAT function (kavach/nat_plugin.py). Workflows call tools only
through `Toolbox`, which enforces the 6-call cap and the per-workflow reducer allowlist.
"""
from __future__ import annotations

from typing import Any, Awaitable, Callable

from . import community
from .log import log
from .recovery import recovery_steps
from .signals import check_link
from .stdb import ReducerError, Stdb

# Reducer allowlist per workflow (spec 7: "the allowlist is per workflow").
REDUCER_ALLOWLIST: dict[str, set[str]] = {
    "router": {"open_incident", "enqueue_outbox", "ensure_person"},
    "scam_check": {"save_message_check", "enqueue_outbox"},
    "advise": {"save_message_check", "enqueue_outbox"},
    "interview": {"save_answer", "set_incident_context", "enqueue_outbox"},
    "family_alert": {"enqueue_outbox"},
    "verify_relative": {"start_verification", "enqueue_outbox"},
    "trusted_sender": {"start_verification", "enqueue_outbox"},
    "briefing": {"save_briefing"},
    # iMessage commands (report, family list, code word, briefing...). The module enforces person access.
    "command": {"report_number", "upsert_contact", "remove_contact", "update_settings", "request_briefing",
                "open_incident", "enqueue_outbox"},
}


# NAT tool functions are global; they find the run's client here by reference.
DB_REGISTRY: dict[str, Stdb] = {}


class ToolBudgetExceeded(RuntimeError):
    pass


class ReducerNotAllowed(PermissionError):
    pass


ToolFn = Callable[[dict[str, Any]], Awaitable[Any]]


class Toolbox:
    """One per run. `call(name, args)` goes through NAT functions when provided, else plain Python."""

    def __init__(self, workflow: str, db: Stdb, max_calls: int = 6, nat_tools: dict[str, Any] | None = None):
        self.workflow = workflow
        self.db = db
        self.max_calls = max_calls
        self.calls = 0
        self.nat_tools = nat_tools or {}

    async def call(self, name: str, args: dict[str, Any]) -> Any:
        self.calls += 1
        if self.calls > self.max_calls:
            raise ToolBudgetExceeded(f"{self.workflow}: more than {self.max_calls} tool calls")
        if name == "reducer" and args.get("name") not in REDUCER_ALLOWLIST.get(self.workflow, set()):
            raise ReducerNotAllowed(f"{self.workflow} may not call {args.get('name')}")
        nat_fn = self.nat_tools.get(name)
        if nat_fn is not None:
            DB_REGISTRY[str(id(self.db))] = self.db
            return await nat_fn.ainvoke({"args": args, "db_ref": str(id(self.db))})
        return await TOOLS[name](self.db, args)


# --- tool implementations: (db, args) -> result ------------------------------------------------

async def _get_person(db: Stdb, a: dict) -> dict | None:
    return await db.person(int(a["person_id"]))


async def _get_contacts(db: Stdb, a: dict) -> list[dict]:
    return await db.contacts(int(a["person_id"]))


async def _get_incident(db: Stdb, a: dict) -> dict | None:
    return await db.incident(int(a["incident_id"]))


# Incidents for which the family_alert workflow queued at least one alert (this process).
ALERTED_INCIDENTS: set[int] = set()
_HELP_ROW = "asked for help during a call"  # the module's Call Companion notice, not an incident alert


async def _incident_state(db: Stdb, a: dict) -> dict:
    """Incident row plus whether the family has been alerted about it. With wait_alerts, when severity just
    rose to high/critical, waits briefly for the scheduled family_alert run (or its template fallback)."""
    import asyncio
    import time as _t

    iid = int(a["incident_id"])
    deadline = _t.monotonic() + float(a.get("wait_s", 4.0))
    while True:
        inc = await db.incident(iid)
        rows = await db.sql(f"SELECT * FROM svc_outbox WHERE related_incident_id = {iid}")
        alerts = [r for r in rows if r.get("kind") == "family_alert" and _HELP_ROW not in r.get("body", "")]
        sent = iid in ALERTED_INCIDENTS or bool(alerts)
        sev = (inc or {}).get("severity") or ""
        rose = sev in ("high", "critical") and sev != a.get("severity_before", "")
        if sent or not a.get("wait_alerts") or not rose or _t.monotonic() > deadline:
            return {"incident": inc, "alert_sent": sent, "alert_count": len(alerts)}
        await asyncio.sleep(0.25)


async def _sql(db: Stdb, a: dict) -> list[dict]:
    query = str(a["query"])
    if not query.lstrip().lower().startswith("select") or ";" in query:
        raise ValueError("read tool only runs single SELECT statements")
    return await db.sql(query)


async def _search_community(db: Stdb, a: dict) -> community.SearchResult:
    return await community.search_community(db, a.get("text", ""), a.get("sender_e164", ""), a.get("extra_context", ""))


async def _lookup_community(db: Stdb, a: dict) -> dict:
    return await community.lookup_community(db, a["value"])


async def _check_links(db: Stdb, a: dict) -> list[dict]:
    return [check_link(u).as_dict() for u in a.get("urls", [])]


async def _recovery_steps(db: Stdb, a: dict) -> list[dict]:
    return recovery_steps(list(a.get("shared_items", [])), bool(a.get("critical", False)))


async def _reducer(db: Stdb, a: dict) -> None:
    await db.call(a["name"], a["args"])


async def _reducers(db: Stdb, a: dict) -> list[dict]:
    """Batch of reducer calls as one tool step (e.g. one family alert row per contact).
    Refusals are expected (consent, pause, opt-out) and reported per item instead of raising."""
    results = []
    for item in a["calls"]:
        try:
            await db.call(item["name"], item["args"])
            results.append({"ok": True})
        except ReducerError as e:
            results.append({"ok": False, "status": e.status, "error": e.text[:200]})
    return results


TOOLS: dict[str, Callable[[Stdb, dict], Awaitable[Any]]] = {
    "get_person": _get_person,
    "get_contacts": _get_contacts,
    "get_incident": _get_incident,
    "incident_state": _incident_state,
    "read": _sql,
    "search_community": _search_community,
    "lookup_community": _lookup_community,
    "check_link": _check_links,
    "recovery_steps": _recovery_steps,
    "reducer": _reducer,
    "reducers": _reducers,
}


async def checked_reducers(tb: Toolbox, calls: list[dict]) -> list[dict]:
    allowed = REDUCER_ALLOWLIST.get(tb.workflow, set())
    for c in calls:
        if c["name"] not in allowed:
            raise ReducerNotAllowed(f"{tb.workflow} may not call {c['name']}")
    res = await tb.call("reducers", {"calls": calls})
    refused = sum(1 for r in res if not r["ok"])
    if refused:
        log("reducer_refused", workflow=tb.workflow, refused=refused, count=len(calls))
    return res
