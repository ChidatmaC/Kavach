"""Server contract: bearer auth, input validation, 20 s budget with spec 13 fallbacks (no DB needed)."""
import asyncio

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("AGENT_SERVICE_TOKEN", "test-token")
    monkeypatch.setenv("AGENT_RUN_TIMEOUT_S", "0.2")
    monkeypatch.setenv("KAVACH_USE_NAT", "false")
    monkeypatch.setenv("AGENT_TASK_POLLER", "false")
    monkeypatch.setenv("KAVACH_OUTCOME_WATCHER", "false")
    from kavach import config

    config.settings.cache_clear()
    import server

    async def slow(workflow, payload):
        await asyncio.sleep(5)

    async def no_reply(run, payload):
        return None

    monkeypatch.setattr(server.ENGINE, "run", slow)
    monkeypatch.setattr(server, "send_fallback_reply", no_reply)
    with TestClient(server.app) as c:
        yield c


H = {"authorization": "Bearer test-token"}


def test_auth_required(client):
    assert client.get("/health").json() == {"ok": True}
    assert client.post("/run/scam_check", json={"person_id": 1, "text": "x"}).status_code == 401
    assert client.post("/run/scam_check", headers={"authorization": "Bearer wrong"}, json={}).status_code == 401


def test_input_validation(client):
    r = client.post("/run/scam_check", headers=H, json={"text": "no person"})
    assert r.status_code == 400
    assert client.post("/run/nope", headers=H, json={}).status_code == 404


def test_timeout_gives_scam_check_fallback_reply(client):
    r = client.post("/run/scam_check", headers=H, json={"person_id": 1, "text": "hi", "source": "imessage"})
    assert r.status_code == 200
    assert r.json()["reason"].startswith("I couldn't check this right now. Don't reply or tap any links")


def test_timeout_family_alert_returns_503_so_module_sends_template(client):
    r = client.post("/run/family_alert", headers=H, json={"incident_id": 1, "priority": "normal"})
    assert r.status_code == 503
