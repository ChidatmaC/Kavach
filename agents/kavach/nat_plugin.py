"""NVIDIA NeMo Agent Toolkit registration.

Each workflow is a NAT function type (`kavach_<workflow>`) configured by agents/configs/<workflow>.yml.
Its `llms:` section supplies the two Nemotron tiers (D4) and its `functions:` section lists the
shared tools (`kavach_tool`), which the workflow invokes through NAT (`Function.ainvoke`), so
NAT's builder, config validation and profiling hooks see every tool call.
"""
from __future__ import annotations

from typing import Any

from nat.builder.builder import Builder
from nat.builder.function_info import FunctionInfo
from nat.cli.register_workflow import register_function
from nat.data_models.component_ref import FunctionRef, LLMRef
from nat.data_models.function import FunctionBaseConfig

from .llm import ModelSet
from .tools import DB_REGISTRY, TOOLS


class KavachToolConfig(FunctionBaseConfig, name="kavach_tool"):
    """A shared Kavach tool (spec 7 tools table): SpacetimeDB reads, reducer calls, community search, links."""
    tool: str


@register_function(config_type=KavachToolConfig)
async def kavach_tool(config: KavachToolConfig, builder: Builder):
    impl = TOOLS[config.tool]

    async def _run(payload: dict) -> Any:
        return await impl(DB_REGISTRY[payload["db_ref"]], payload["args"])

    yield FunctionInfo.from_fn(_run, description=f"Kavach tool {config.tool}")


class _WorkflowBase(FunctionBaseConfig):
    llm_fast: LLMRef
    llm_writer: LLMRef
    tool_names: list[FunctionRef] = []
    max_tool_calls: int = 6
    timeout_s: float = 20.0


def _models(builder: Builder, cfg: _WorkflowBase) -> ModelSet:
    fast = builder.get_llm_config(cfg.llm_fast)
    writer = builder.get_llm_config(cfg.llm_writer)
    key = fast.api_key.get_secret_value() if getattr(fast, "api_key", None) else ""
    return ModelSet(fast=fast.model_name, writer=writer.model_name,
                    base_url=fast.base_url or "https://integrate.api.nvidia.com/v1", api_key=key)


def _make(workflow: str):
    cls = type(f"Kavach{workflow.title().replace('_', '')}Config", (_WorkflowBase,), {
        "__doc__": f"Kavach {workflow} workflow", "__module__": __name__}, name=f"kavach_{workflow}")

    async def build(config, builder: Builder):
        from .engine import run_python_workflow

        models = _models(builder, config)
        tools = {str(n): await builder.get_function(n) for n in config.tool_names}

        async def _run(payload: dict) -> dict:
            return await run_python_workflow(workflow, payload, models=models, nat_tools=tools)

        yield FunctionInfo.from_fn(_run, description=f"Kavach {workflow} workflow")

    build.__name__ = f"kavach_{workflow}"
    register_function(config_type=cls)(build)
    return cls


WORKFLOW_NAMES = ["router", "scam_check", "advise", "command", "interview", "family_alert", "verify_relative",
                  "trusted_sender", "briefing"]
CONFIG_TYPES = {w: _make(w) for w in WORKFLOW_NAMES}
