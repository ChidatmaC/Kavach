"""shared/recovery_library.yaml must agree with spacetime/src/recovery.ts (D10)."""
import json
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
TS = (ROOT / "spacetime" / "src" / "recovery.ts").read_text()
LIB = yaml.safe_load((ROOT / "shared" / "recovery_library.yaml").read_text())


def _ts_object(name: str) -> str:
    m = re.search(rf"export const {name}[^=]*=\s*(\{{.*?\n\}}|\[.*?\]);", TS, re.S)
    assert m, name
    return m.group(1)


def _to_json(src: str):
    src = re.sub(r"//.*", "", src)
    src = re.sub(r"([{\s,])([a-z0-9_]+)\s*:", r'\1"\2":', src)
    src = src.replace("'", '"')
    src = re.sub(r",\s*([}\]])", r"\1", src)
    return json.loads(src)


def test_step_priorities_match():
    ts = _to_json(_ts_object("STEP_PRIORITY"))
    yml = {k: v["priority"] for k, v in LIB["steps"].items()}
    assert ts == yml


def test_item_steps_match_in_order():
    assert _to_json(_ts_object("ITEM_STEPS")) == LIB["items"]


def test_critical_always_matches():
    assert _to_json(_ts_object("CRITICAL_ALWAYS")) == LIB["critical_always"]


def test_every_referenced_step_has_text():
    keys = {k for ks in LIB["items"].values() for k in ks} | set(LIB["critical_always"])
    assert keys <= set(LIB["steps"])
    assert all(LIB["steps"][k]["text"].strip() for k in keys)


def test_python_ordering_matches_module_rule():
    from kavach.recovery import recovery_steps

    steps = recovery_steps(["money", "link"], critical=True)
    pri = [s["priority"] for s in steps]
    assert pri == sorted(pri, key=["now", "today", "this_week"].index)
    assert [s["key"] for s in steps][:1] == ["call_bank_stop_transfer"]
    assert "tell_family" in [s["key"] for s in steps]
