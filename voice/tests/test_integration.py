"""HotlineSession against the real SpacetimeDB database `kavach-voice` and the stub agent server.

Prereq (repo root): publish kavach-voice with AGENT_SERVICE_URL=http://127.0.0.1:8097, mint tokens,
demo_reset (see voice/README.md). Skipped when SpacetimeDB is not reachable.
"""
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

from agent_client import AgentClient
from config import REPO_ROOT, Config
from fakes import Recorder
from hotline import STEP_TEXT, HotlineSession
from stdb import Stdb

DB = "kavach-voice"
STUB_PORT = 8097
JOE = "+15555550101"
VOICE_DIR = Path(__file__).resolve().parent.parent


def _stdb_up() -> bool:
    try:
        httpx.get("http://127.0.0.1:3000/v1/ping", timeout=2)
        return True
    except httpx.HTTPError:
        return False


pytestmark = pytest.mark.skipif(not _stdb_up(), reason="local SpacetimeDB not running")


@pytest.fixture(scope="module")
def stub_agent():
    env = {**os.environ, "SPACETIME_DB_NAME": DB, "STUB_AGENT_PORT": str(STUB_PORT)}
    if os.environ.get("VOICE_IT_RESET", "1") == "1":
        subprocess.run(["npx", "tsx", "scripts/demo_reset.ts"], cwd=REPO_ROOT, env=env, check=True,
                       capture_output=True, timeout=120)
    proc = subprocess.Popen([sys.executable, str(VOICE_DIR / "tests" / "stub_agent.py")], env=env, cwd=VOICE_DIR)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", STUB_PORT), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    yield
    proc.terminate()
    proc.wait(timeout=10)


@pytest.fixture
def cfg(monkeypatch, stub_agent):
    monkeypatch.setenv("SPACETIME_DB_NAME", DB)
    monkeypatch.setenv("AGENT_SERVICE_URL", f"http://127.0.0.1:{STUB_PORT}")
    monkeypatch.setenv("VOICE_FAMILY_ALERT_WAIT_S", "6")
    return Config.load()


async def test_gift_card_call_reaches_critical_and_family_is_told(cfg):
    rec = Recorder()
    stdb, agent = Stdb(cfg), AgentClient(cfg)
    s = HotlineSession(caller_e164=JOE, stdb=stdb, agent=agent, cfg=cfg, speak=rec.speak, hangup=rec.hangup)
    try:
        await s.start()
        t0 = time.monotonic()
        await s.on_utterance(
            "A man said he was from the IRS and asked me to buy gift cards. "
            "I bought gift cards and read him the numbers, and the code 482913.")
        turn_s = time.monotonic() - t0
        await s.on_utterance("no, that's okay")  # decline the stay-on-the-line offer
        inc = await stdb.incident(s.incident_id)
        alerts = await stdb.family_alerts(s.incident_id)
        evidence = [e for e in await stdb.hotline_evidence() if e["sender_e164"] == JOE]
    finally:
        await stdb.aclose()
        await agent.aclose()

    text = rec.text()
    print("\n--- simulated call ---\n" + text + f"\n--- verdict turn took {turn_s:.2f}s ---")
    assert inc["entry_point"] == "hotline" and inc["person_id"] == 1 and inc["caller_e164"] == JOE
    assert inc["severity"] == "critical" and "gift_card" in inc["shared_items"]
    assert "482913" not in inc["summary_redacted"] and inc["summary_redacted"].startswith("Hotline call.")
    assert "482913" not in inc["answers_json"]
    assert "This is a scam, and it's urgent." in rec.lines
    assert STEP_TEXT["gift_card_issuer"] in rec.lines
    assert any("stay on the line" in ln for ln in rec.lines)
    assert len(alerts) >= 2 and {a["to_e164"] for a in alerts} >= {"+15555550102", "+15555550103"}
    assert "I've told your family." in rec.lines and rec.hung_up
    assert len(evidence) >= 1  # the module's corpus row (no duplicate from voice)
    assert sum(1 for e in evidence if "Hotline call." in e["text_redacted"]) == 1


async def test_unknown_caller_medium_call(cfg):
    rec = Recorder()
    stdb, agent = Stdb(cfg), AgentClient(cfg)
    s = HotlineSession(caller_e164="+15555550999", stdb=stdb, agent=agent, cfg=cfg,
                       speak=rec.speak, hangup=rec.hangup)
    try:
        await s.start()
        await s.on_utterance("Someone said they were my grandson and asked for bail money "
                             "but I didn't send anything and hung up.")
        await s.on_utterance("no")   # secrecy / rush
        await s.on_utterance("no")   # want help now
        inc = await stdb.incident(s.incident_id)
    finally:
        await stdb.aclose()
        await agent.aclose()
    print("\n--- unknown caller ---\n" + rec.text())
    assert inc["person_id"] == 0 and inc["entry_point"] == "hotline"
    assert inc["severity"] == "medium"
    assert "This is very likely a scam." in rec.lines
    assert "Would you like me to tell your family?" not in rec.text()
    assert rec.hung_up
