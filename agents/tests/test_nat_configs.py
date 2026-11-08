"""Every configs/<workflow>.yml validates against NAT's Config schema and builds with the kavach_* types."""
import asyncio

import pytest

from kavach.config import CONFIGS_DIR

WORKFLOWS = ["router", "scam_check", "interview", "family_alert", "verify_relative", "trusted_sender", "briefing", "practice"]


@pytest.mark.parametrize("wf", WORKFLOWS)
def test_config_loads_and_builds(wf):
    from nat.builder.workflow_builder import WorkflowBuilder
    from nat.runtime.loader import load_config

    import kavach.nat_plugin  # noqa: F401  registers kavach_tool and kavach_<workflow>

    cfg = load_config(CONFIGS_DIR / f"{wf}.yml")
    assert cfg.workflow.type == f"kavach_{wf}"
    assert set(cfg.llms) == {"nemotron_fast", "nemotron_writer"}

    async def build():
        async with WorkflowBuilder.from_config(config=cfg) as b:
            return b.get_workflow() is not None

    assert asyncio.run(build())
