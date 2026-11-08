"""Runs workflows: through NeMo Agent Toolkit (configs/<workflow>.yml) when it loads, else plain Python.
Both paths execute the same workflow code; NAT supplies model config and wraps every tool call."""
from __future__ import annotations

import contextlib
import time
from typing import Any

from .config import CONFIGS_DIR, settings
from .llm import ModelSet
from .log import log
from .stdb import Stdb
from .workflows.base import make_run
from .workflows.advise import run_advise
from .workflows.briefing import run_briefing
from .workflows.command import run_command
from .workflows.family_alert import run_family_alert
from .workflows.interview import run_interview
from .workflows.router import run_router
from .workflows.scam_check import run_scam_check
from .workflows.verify import run_trusted_sender, run_verify_relative

_db: Stdb | None = None


def db() -> Stdb:
    global _db
    if _db is None:
        _db = Stdb()
    return _db


async def run_python_workflow(workflow: str, payload: dict[str, Any], models: ModelSet | None = None,
                              nat_tools: dict | None = None) -> dict[str, Any]:
    run = make_run(workflow, db(), models, nat_tools)
    t0 = time.perf_counter()
    try:
        if workflow == "router":
            out = await run_router(run, payload, dispatcher=ENGINE.run)
        elif workflow == "scam_check":
            out = await run_scam_check(run, payload, queue_reply=not payload.get("_no_reply"))
        elif workflow == "advise":
            out = await run_advise(run, payload)
        elif workflow == "interview":
            out = await run_interview(run, payload)
        elif workflow == "family_alert":
            out = await run_family_alert(run, payload)
        elif workflow == "verify_relative":
            out = await run_verify_relative(run, payload)
        elif workflow == "trusted_sender":
            out = await run_trusted_sender(run, payload)
        elif workflow == "briefing":
            out = await run_briefing(run, payload)
        elif workflow == "command":
            out = await run_command(run, payload)
        else:
            raise KeyError(workflow)
        log("workflow_done", workflow=workflow, outcome="ok", tool_calls=run.tools.calls,
            latency_ms=int((time.perf_counter() - t0) * 1000), **run.fields)
        return out
    except Exception as e:
        log("workflow_done", workflow=workflow, outcome="error", error=type(e).__name__, tool_calls=run.tools.calls,
            latency_ms=int((time.perf_counter() - t0) * 1000), **run.fields)
        raise


class Engine:
    def __init__(self) -> None:
        self.mode = "python"
        self._stack: contextlib.AsyncExitStack | None = None
        self._fns: dict[str, Any] = {}
        self.nat_error = ""

    async def start(self) -> None:
        if not settings().use_nat:
            return
        try:
            from nat.builder.workflow_builder import WorkflowBuilder
            from nat.runtime.loader import load_config

            from . import nat_plugin

            stack = contextlib.AsyncExitStack()
            for wf in nat_plugin.WORKFLOW_NAMES:
                cfg = load_config(CONFIGS_DIR / f"{wf}.yml")
                builder = await stack.enter_async_context(WorkflowBuilder.from_config(config=cfg))
                self._fns[wf] = builder.get_workflow()
            self._stack = stack
            self.mode = "nat"
            log("engine_ready", method="nat", count=len(self._fns))
        except Exception as e:  # noqa: BLE001 - never block the service on the framework
            self.nat_error = f"{type(e).__name__}: {str(e)[:200]}"
            log("engine_ready", method="python", error=self.nat_error)

    async def stop(self) -> None:
        if self._stack:
            await self._stack.aclose()

    async def run(self, workflow: str, payload: dict[str, Any]) -> dict[str, Any]:
        fn = self._fns.get(workflow)
        if fn is not None:
            return await fn.ainvoke(payload)
        return await run_python_workflow(workflow, payload)


ENGINE = Engine()
