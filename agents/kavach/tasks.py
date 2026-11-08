"""Agent task queue poller (module `agent_task`, D7: services connect as clients).

Every 500 ms: read `svc_agent_task WHERE status = 'queued'`, claim each task with `claim_agent_task`
(a refusal means another poller has it), run the same workflow function `/run/{workflow}` uses,
then `complete_agent_task(ok, error)`. The module gives each task 20 s; ok=false or no completion
marks it failed and, for family_alert, queues the template alert. Concurrency is bounded.
"""
from __future__ import annotations

import asyncio
import json
import time
from typing import Any, Awaitable, Callable

from .log import log
from .stdb import ReducerError, Stdb

Runner = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]
RUN_BUDGET_S = 18.0  # inside the module's 20 s task budget, leaving time to report completion


class TaskPoller:
    def __init__(self, db: Stdb, runner: Runner, interval: float = 0.5, concurrency: int = 4,
                 budget_s: float = RUN_BUDGET_S):
        self.db = db
        self.runner = runner
        self.interval = interval
        self.concurrency = concurrency
        self.budget_s = budget_s
        self.enabled = True
        self._inflight: dict[int, asyncio.Task] = {}
        self._loop_task: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self._loop_task is not None and not self._loop_task.done()

    def start(self) -> None:
        if not self.running:
            self._loop_task = asyncio.create_task(self._loop(), name="agent-task-poller")
            log("task_poller", outcome="started", count=self.concurrency)

    async def stop(self) -> None:
        if self._loop_task:
            self._loop_task.cancel()
            try:
                await self._loop_task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
            self._loop_task = None
        if self._inflight:
            await asyncio.gather(*self._inflight.values(), return_exceptions=True)

    async def _loop(self) -> None:
        while True:
            try:
                if self.enabled:
                    await self.poll_once()
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 - keep polling through transient DB errors
                log("task_poll_error", error=type(e).__name__)
            await asyncio.sleep(self.interval)

    async def poll_once(self) -> int:
        """Claim and start as many queued tasks as free slots allow. Returns the number started."""
        free = self.concurrency - len(self._inflight)
        if free <= 0:
            return 0
        rows = await self.db.sql("SELECT * FROM svc_agent_task WHERE status = 'queued'")
        started = 0
        for row in sorted(rows, key=lambda r: int(r["id"])):
            if started >= free:
                break
            tid = int(row["id"])
            if tid in self._inflight:
                continue
            try:
                await self.db.call("claim_agent_task", {"task_id": tid})
            except ReducerError:
                continue  # someone else has it (or it timed out)
            t = asyncio.create_task(self._handle(row))
            self._inflight[tid] = t
            t.add_done_callback(lambda _t, tid=tid: self._inflight.pop(tid, None))
            started += 1
        return started

    async def _handle(self, row: dict[str, Any]) -> None:
        tid, workflow = int(row["id"]), str(row["workflow"])
        t0 = time.perf_counter()
        ok, error = True, ""
        try:
            payload = json.loads(row.get("payload_json") or "{}")
            if not isinstance(payload, dict):
                raise ValueError("payload must be an object")
            await asyncio.wait_for(self.runner(workflow, payload), self.budget_s)
        except asyncio.TimeoutError:
            ok, error = False, "timeout"
        except Exception as e:  # noqa: BLE001
            ok, error = False, f"{type(e).__name__}: {str(e)[:150]}"
        try:
            await self.db.call("complete_agent_task", {"task_id": tid, "ok": ok, "error": error})
        except ReducerError as e:
            log("task_complete_error", workflow=workflow, task_id=tid, status=e.status, error=e.text[:120])
        log("agent_task", workflow=workflow, task_id=tid,
            outcome="done" if ok else "failed", error=error or None,
            latency_ms=int((time.perf_counter() - t0) * 1000))
