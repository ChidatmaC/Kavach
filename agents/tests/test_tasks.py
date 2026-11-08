"""Agent task poller: claim -> run -> complete, contested claims, failures, bounded concurrency."""
import asyncio
import json

from kavach.stdb import ReducerError
from kavach.tasks import TaskPoller


class FakeDb:
    def __init__(self, tasks, taken=()):
        self.tasks = tasks
        self.taken = set(taken)
        self.calls = []

    async def sql(self, query, token=None):
        assert "svc_agent_task" in query and "queued" in query
        return [t for t in self.tasks if t["status"] == "queued"]

    async def call(self, reducer, args, token=None):
        self.calls.append((reducer, args))
        t = next(t for t in self.tasks if t["id"] == args["task_id"])
        if reducer == "claim_agent_task":
            if t["id"] in self.taken or t["status"] != "queued":
                raise ReducerError(reducer, 530, "task is running")
            t["status"] = "running"
        elif reducer == "complete_agent_task":
            t["status"] = "done" if args["ok"] else "failed"
            t["error"] = args["error"]


def task(i, wf="family_alert", payload=None):
    return {"id": i, "workflow": wf, "payload_json": json.dumps(payload or {"incident_id": i}), "status": "queued"}


async def _drain(p):
    await p.poll_once()
    while p._inflight:
        await asyncio.gather(*list(p._inflight.values()), return_exceptions=True)


def test_claims_runs_and_completes():
    ran = []

    async def runner(wf, payload):
        ran.append((wf, payload))
        return {"alerts": []}

    db = FakeDb([task(1), task(2, "briefing", {"person_id": 1})], taken={2})
    asyncio.run(_drain(TaskPoller(db, runner)))
    assert ran == [("family_alert", {"incident_id": 1})]  # task 2 was claimed by someone else
    assert db.tasks[0]["status"] == "done" and ("complete_agent_task", {"task_id": 1, "ok": True, "error": ""}) in db.calls


def test_failure_and_timeout_complete_with_ok_false():
    async def runner(wf, payload):
        if wf == "boom":
            raise RuntimeError("nope")
        await asyncio.sleep(1)

    db = FakeDb([task(1, "boom"), task(2, "slow")])
    asyncio.run(_drain(TaskPoller(db, runner, budget_s=0.05)))
    assert db.tasks[0]["status"] == "failed" and "RuntimeError" in db.tasks[0]["error"]
    assert db.tasks[1]["status"] == "failed" and db.tasks[1]["error"] == "timeout"


def test_bad_payload_fails_task():
    async def runner(wf, payload):
        return {}

    t = task(1)
    t["payload_json"] = "[1, 2]"
    db = FakeDb([t])
    asyncio.run(_drain(TaskPoller(db, runner)))
    assert db.tasks[0]["status"] == "failed"


def test_concurrency_is_bounded():
    peak = 0
    live = 0

    async def runner(wf, payload):
        nonlocal peak, live
        live += 1
        peak = max(peak, live)
        await asyncio.sleep(0.05)
        live -= 1

    async def go():
        db = FakeDb([task(i) for i in range(1, 11)])
        p = TaskPoller(db, runner, concurrency=4)
        started = await p.poll_once()
        assert started == 4
        assert await p.poll_once() == 0  # no free slots
        while any(t["status"] != "done" for t in db.tasks):
            await p.poll_once()
            await asyncio.sleep(0.01)
        return db

    db = asyncio.run(go())
    assert peak == 4 and all(t["status"] == "done" for t in db.tasks)
