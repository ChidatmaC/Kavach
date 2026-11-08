"""Automatic training labels from what happened next (docs/CONTRACTS.md section 7, training log).

Polls SpacetimeDB every few seconds:
- a verification the relative denied ("it wasn't me") -> likely_scam label for the check that led to it;
- an incident at High/Critical -> likely_scam labels for that incident's interview decisions.
Labels are idempotent (keyed), so restarts and overlapping polls are harmless.
"""
from __future__ import annotations

import asyncio
import contextlib

from . import training
from .log import log
from .stdb import Stdb


def _micros(v) -> int:
    if isinstance(v, list):
        v = v[0] if v else 0
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


class OutcomeWatcher:
    def __init__(self, db: Stdb, interval: float = 5.0):
        self.db = db
        self.interval = interval
        self._task: asyncio.Task | None = None
        self._seen_v: set[int] = set()
        self._seen_i: set[int] = set()

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._task
            self._task = None

    async def _loop(self) -> None:
        while True:
            try:
                await self.poll_once()
            except Exception as e:  # noqa: BLE001 - never let the watcher die
                log("outcome_watcher_error", error=type(e).__name__)
            await asyncio.sleep(self.interval)

    async def poll_once(self) -> int:
        n = 0
        for v in await self.db.sql("SELECT * FROM svc_verification WHERE status = 'denied'"):
            vid = int(v["id"])
            if vid in self._seen_v:
                continue
            self._seen_v.add(vid)
            n += training.label_verification_denied(vid, int(v.get("person_id") or 0), _micros(v.get("created_at")) / 1e6)
        for inc in await self.db.sql("SELECT * FROM svc_incident"):
            iid, sev = int(inc["id"]), inc.get("severity") or ""
            if sev not in ("high", "critical") or iid in self._seen_i:
                continue
            self._seen_i.add(iid)
            n += training.label_incident(iid, sev, int(inc.get("person_id") or 0))
        return n
