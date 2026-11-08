"""Kavach agent service (docs/CONTRACTS.md section 4).

    uv run uvicorn server:app --host 127.0.0.1 --port 8088

/run/* and /push need `Authorization: Bearer $AGENT_SERVICE_TOKEN`; /app/* take the app's SpacetimeDB
token and resolve the person through `my_person`. Every response is validated against
shared/schemas/<workflow>.output.json. Each run has a 20 s budget, then the spec 13 fallback.
"""
from __future__ import annotations

import asyncio
import hmac
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from kavach import apns
from kavach.config import settings
from kavach.engine import ENGINE, db
from kavach.guard import guard
from kavach.log import log
from kavach.schemas import SchemaError, validate
from kavach.stdb import ReducerError, SqlError
from kavach.tasks import TaskPoller
from kavach.tools import ReducerNotAllowed, ToolBudgetExceeded
from kavach.workflows.base import BadRequest, NotFound, make_run
from kavach.workflows.interview import QUESTIONS, QUESTION_IDS
from kavach.workflows.router import HELP_TEXT
from kavach.workflows.scam_check import fallback_output, send_fallback_reply

WORKFLOWS = {"router", "scam_check", "interview", "family_alert", "verify_relative", "trusted_sender",
             "briefing", "practice"}


async def run_validated(workflow: str, payload: dict[str, Any]) -> dict[str, Any]:
    """The workflow function behind /run/{workflow} and the agent task poller: schema-checked in and out."""
    if workflow not in WORKFLOWS:
        raise BadRequest(f"unknown workflow {workflow}")
    validate(f"{workflow}.input", payload)
    out = await ENGINE.run(workflow, payload)
    validate(f"{workflow}.output", out)
    return out


POLLER = TaskPoller(db(), run_validated)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    guard()  # load NeMo Guardrails once
    await ENGINE.start()
    s = settings()
    if s.task_poller:
        POLLER.start()
    log("service_start", method=ENGINE.mode, model=s.model_fast if s.llm_enabled else "none(fallback)",
        path=f"{s.spacetime_uri}/{s.spacetime_db}", enabled=s.task_poller)
    yield
    await POLLER.stop()
    await ENGINE.stop()


app = FastAPI(title="Kavach agent service", lifespan=lifespan)


def _authorized(request: Request) -> bool:
    expected = settings().service_token
    got = request.headers.get("authorization", "")
    return bool(expected) and hmac.compare_digest(got.encode(), f"Bearer {expected}".encode())


def _err(status: int, msg: str) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=status)


async def _fallback(workflow: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """Spec 13 safe fallbacks. family_alert returns 503 so the module queues its template alert."""
    if workflow == "scam_check":
        try:
            await asyncio.wait_for(send_fallback_reply(make_run("scam_check", db()), payload), 3)
        except Exception as e:  # noqa: BLE001
            log("fallback_reply_failed", workflow=workflow, error=type(e).__name__)
        return 200, fallback_output()
    if workflow == "router":
        return 200, {"intent": "help", "args": {"reply": HELP_TEXT.format(app=settings().app_name)}}
    if workflow == "interview":
        return 200, {"done": False, "question_id": QUESTION_IDS[0], "next_question": QUESTIONS[QUESTION_IDS[0]],
                     "severity": "", "verdict": "suspicious", "reason": "I couldn't finish checking this right now.",
                     "evidence_count": 0, "campaign_id": 0, "alert_sent": False}
    return 503, {"error": f"{workflow} unavailable"}


async def execute(workflow: str, payload: dict[str, Any]) -> JSONResponse:
    t0 = time.perf_counter()
    ms = lambda: int((time.perf_counter() - t0) * 1000)  # noqa: E731
    try:
        validate(f"{workflow}.input", payload)
    except SchemaError as e:
        return _err(400, str(e))
    try:
        out = await asyncio.wait_for(run_validated(workflow, payload), settings().run_timeout_s)
        log("run", workflow=workflow, outcome="ok", latency_ms=ms(), incident_id=payload.get("incident_id"),
            person_id=payload.get("person_id"))
        return JSONResponse(out)
    except BadRequest as e:
        log("run", workflow=workflow, outcome="bad_request", latency_ms=ms())
        return _err(400, str(e))
    except NotFound as e:
        log("run", workflow=workflow, outcome="not_found", latency_ms=ms())
        return _err(404, str(e))
    except (asyncio.TimeoutError, ToolBudgetExceeded, ReducerNotAllowed, ReducerError, SqlError, SchemaError,
            Exception) as e:  # noqa: BLE001 - every failure gets the safe fallback
        status, body = await _fallback(workflow, payload)
        log("run", workflow=workflow, outcome="fallback", error=type(e).__name__, latency_ms=ms(),
            incident_id=payload.get("incident_id"), person_id=payload.get("person_id"))
        return JSONResponse(body, status_code=status)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True}


@app.get("/health/details")
async def health_details() -> dict[str, Any]:
    s = settings()
    return {"ok": True, "engine": ENGINE.mode, "nat_error": ENGINE.nat_error or None, "guardrails": guard().engine,
            "llm": s.llm_enabled, "demo_mode": s.demo_mode, "db": s.spacetime_db,
            "task_poller": {"running": POLLER.running, "enabled": POLLER.enabled}}


@app.post("/tasks/poller")
async def set_poller(request: Request):
    """Ops/test switch: {"enabled": false} pauses claiming agent tasks (the module then falls back after 20 s)."""
    if not _authorized(request):
        return _err(401, "unauthorized")
    body = await request.json()
    POLLER.enabled = bool(body.get("enabled", True))
    log("task_poller", outcome="enabled" if POLLER.enabled else "paused")
    return {"enabled": POLLER.enabled, "running": POLLER.running}


@app.post("/run/{workflow}")
async def run_workflow(workflow: str, request: Request):
    if not _authorized(request):
        return _err(401, "unauthorized")
    if workflow not in WORKFLOWS:
        return _err(404, f"unknown workflow {workflow}")
    try:
        payload = await request.json()
    except ValueError:
        return _err(400, "body must be JSON")
    if not isinstance(payload, dict):
        return _err(400, "body must be a JSON object")
    payload.pop("_no_reply", None)
    return await execute(workflow, payload)


@app.post("/push")
async def push(request: Request):
    if not _authorized(request):
        return _err(401, "unauthorized")
    try:
        body = await request.json()
        validate("push.input", body)
    except (ValueError, SchemaError) as e:
        return _err(400, str(e))
    try:
        out = await asyncio.wait_for(apns.send_push(db(), body), 15)
    except Exception as e:  # noqa: BLE001
        log("push", path="/push", outcome="error", error=type(e).__name__)
        out = {"sent": False}
    return JSONResponse(validate("push.output", out))


async def _app_person(request: Request) -> dict[str, Any] | None:
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer ") or len(auth) < 20:
        return None
    try:
        return await db().one("SELECT * FROM my_person", token=auth[7:].strip())
    except SqlError:
        return None


@app.post("/app/check")
async def app_check(request: Request):
    person = await _app_person(request)
    if not person:
        return _err(401, "unknown app identity; call register_person first")
    try:
        body = await request.json()
        validate("app_check.input", body)
    except (ValueError, SchemaError) as e:
        return _err(400, str(e))
    payload = {"person_id": int(person["id"]), "text": body.get("text", ""), "source": body["source"],
               "sender_e164": body.get("sender_e164", ""), "image_base64": body.get("image_base64", ""),
               "_no_reply": True}
    resp = await execute("scam_check", payload)
    return resp


@app.post("/app/verify")
async def app_verify(request: Request):
    person = await _app_person(request)
    if not person:
        return _err(401, "unknown app identity; call register_person first")
    try:
        body = await request.json()
        validate("app_verify.input", body)
    except (ValueError, SchemaError) as e:
        return _err(400, str(e))
    return await execute("verify_relative", {"person_id": int(person["id"]), "relative_name": body["relative_name"]})
