import asyncio
import json
from types import SimpleNamespace

import pytest

from kavach.llm import LLM, ModelSet, _extract_json
from kavach.schemas import SchemaError, all_schema_names, is_valid, validate
from kavach.workflows.scam_check import fallback_output


def test_all_schemas_load():
    names = all_schema_names()
    for wf in ("router", "scam_check", "interview", "family_alert", "verify_relative", "trusted_sender", "briefing", "practice", "push"):
        assert f"{wf}.output" in names and f"{wf}.input" in names
    for n in names:
        validate(n, {}) if False else None  # check_schema runs on load
        from kavach.schemas import _validator
        _validator(n)


def test_scam_check_output_contract():
    good = {"verdict": "likely_scam", "reason": "r", "campaign_id": 2, "tips": ["a"], "evidence_count": 3}
    validate("scam_check.output", good)
    assert not is_valid("scam_check.output", {**good, "verdict": "scam"})
    assert not is_valid("scam_check.output", {**good, "extra": 1})
    assert is_valid("scam_check.output", fallback_output())


def test_family_alert_body_limit():
    assert not is_valid("family_alert.output", {"alerts": [{"contact_id": 1, "body": "x" * 601}]})


def test_interview_extract_rejects_unknown_items():
    assert is_valid("interview.extract", {"answers": {"q_shared": "card,link"}})
    assert not is_valid("interview.extract", {"answers": {"q_shared": "card,ssn"}})


def test_extract_json_handles_think_and_fences():
    assert _extract_json('<think>hmm {"x":1}</think>```json\n{"intent": "help"}\n```') == {"intent": "help"}
    assert _extract_json('Sure! {"a": "b}c"} trailing') == {"a": "b}c"}


class _FakeCompletions:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.calls = 0

    async def create(self, **kw):
        self.calls += 1
        content = self.outputs.pop(0)
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=content))])


def _llm(outputs):
    llm = LLM(ModelSet(fast="f", writer="w", base_url="http://x", api_key="k"))
    comp = _FakeCompletions(outputs)
    llm._client = SimpleNamespace(chat=SimpleNamespace(completions=comp))
    return llm, comp


def test_invalid_output_retried_once_then_valid():
    llm, comp = _llm(['{"intent": "weather"}', '{"intent": "scam_check"}'])
    out = asyncio.run(llm.json("fast", "s", "u", "router.model", workflow="router"))
    assert out == {"intent": "scam_check"} and comp.calls == 2


def test_invalid_twice_returns_none_for_fallback():
    llm, comp = _llm(["not json", '{"verdict": "maybe"}'])
    assert asyncio.run(llm.json("fast", "s", "u", "scam_check.model", workflow="scam_check")) is None
    assert comp.calls == 2


def test_no_key_means_no_call():
    llm = LLM(ModelSet(fast="f", writer="w", base_url="x", api_key=""))
    assert asyncio.run(llm.json("fast", "s", "u", "router.model", workflow="router")) is None


def test_validate_raises_schema_error():
    with pytest.raises(SchemaError):
        validate("push.output", {"sent": "yes"})
