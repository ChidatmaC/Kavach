"""Integration tests against SpacetimeDB `kavach-agents` and the running service on :8088.

    SPACETIME_DB_NAME=kavach-agents uv run uvicorn server:app --port 8088   # in another shell
    SPACETIME_DB_NAME=kavach-agents uv run pytest -m integration -v
"""
import json
import os
import subprocess
import time
import uuid
from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.integration
ROOT = Path(__file__).resolve().parents[2]
SVC = os.environ.get("AGENT_SERVICE_URL", "http://127.0.0.1:8088")
DB = os.environ.get("SPACETIME_DB_NAME", "kavach-agents")
if DB != "kavach-agents" and not os.environ.get("KAVACH_ALLOW_ANY_DB"):
    pytest.skip("integration tests only run against kavach-agents", allow_module_level=True)

from kavach.config import settings  # noqa: E402  (after env checks)

S = settings()
STDB = f"{S.spacetime_uri}/v1/database/{DB}"
AUTH = {"authorization": f"Bearer {S.service_token}"}
JOE, TOMMY, MARIA = "+15555550101", "+15555550102", "+15555550103"


def sql(query, token=None):
    r = httpx.post(f"{STDB}/sql", content=query, headers={"authorization": f"Bearer {token or S.agents_token}"}, timeout=10)
    r.raise_for_status()
    out = []
    for res in r.json():
        names = [e["name"]["some"] for e in res["schema"]["elements"]]
        out += [dict(zip(names, row)) for row in res["rows"]]
    return out


def call(reducer, args, token=None):
    r = httpx.post(f"{STDB}/call/{reducer}", json=args, headers={"authorization": f"Bearer {token or S.agents_token}"}, timeout=10)
    assert r.status_code // 100 == 2, r.text


def run(workflow, body, timeout=25):
    return httpx.post(f"{SVC}/run/{workflow}", json=body, headers=AUTH, timeout=timeout)


def wait_for(fn, timeout=15.0, every=0.25):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    return fn()


@pytest.fixture(scope="module", autouse=True)
def reset():
    try:
        httpx.get(f"{SVC}/health", timeout=3).raise_for_status()
    except Exception:
        pytest.skip("agent service not running on :8088")
    env = {**os.environ, "SPACETIME_DB_NAME": DB}
    subprocess.run(["npx", "tsx", "scripts/demo_reset.ts"], cwd=ROOT, env=env, check=True, capture_output=True)
    time.sleep(5.5)  # let the service's short corpus caches expire after the reset


@pytest.fixture(scope="module")
def joe():
    return sql(f"SELECT * FROM svc_person WHERE phone_e164 = '{JOE}'")[0]


def test_health_and_auth():
    assert httpx.get(f"{SVC}/health").json() == {"ok": True}
    assert httpx.post(f"{SVC}/run/router", json={"text": "help"}).status_code == 401


def test_a_seeded_toll_text_likely_scam_with_reply_under_10s(joe):
    text = next(m["text"] for m in json.loads((ROOT / "shared/seed/demo.json").read_text())["demo_messages"]
                if m["key"] == "toll_text")
    before = {r["id"] for r in sql("SELECT * FROM svc_outbox")}
    t0 = time.time()
    r = run("scam_check", {"person_id": joe["id"], "text": text, "source": "imessage",
                           "reply_to_e164": JOE, "reply_channel": "imessage"})
    assert r.status_code == 200, r.text
    out = r.json()
    rows = wait_for(lambda: [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{JOE}'")
                             if x["id"] not in before and x["kind"] == "reply"], 10)
    elapsed = time.time() - t0
    assert out["verdict"] == "likely_scam" and out["evidence_count"] >= 1 and out["campaign_id"] > 0
    checks = sql(f"SELECT * FROM svc_message_check WHERE person_id = {joe['id']}")
    assert checks[-1]["verdict"] == "likely_scam"
    assert rows and rows[0]["body"].startswith(f"{S.app_name}: Likely scam") and len(rows[0]["body"]) <= 600
    assert elapsed < 10, elapsed
    print(f"toll check -> reply row in {elapsed:.2f}s")


def test_a2_uncached_toll_variant_also_likely_scam(joe):
    r = run("scam_check", {"person_id": joe["id"], "source": "share",
                           "text": "TxTag notice: balance of $12.10 is past due. Pay within 12 hours: https://txtag-pay.top/x/77"})
    assert r.json()["verdict"] == "likely_scam"


def test_b_paraphrase_of_campaign_is_at_least_suspicious_citing_pattern(joe):
    text = "Reminder from the tollway: your account has an overdue toll charge. Settle it today or extra penalties will be added."
    out = run("scam_check", {"person_id": joe["id"], "text": text, "source": "app_paste"}).json()
    assert out["verdict"] in ("suspicious", "likely_scam"), out
    assert "pattern many people have reported" in out["reason"], out
    assert out["evidence_count"] >= 1
    # reports are never quoted
    for ev in sql("SELECT * FROM svc_report_evidence"):
        assert ev["text_redacted"][:40].lower() not in out["reason"].lower()


def test_b_fresh_message_from_reported_number_is_likely_scam_even_if_model_says_safe(joe):
    out = run("scam_check", {"person_id": joe["id"], "text": "Hi, hope you're having a nice day. Talk soon!",
                             "sender_e164": "+15555550188", "source": "imessage"}).json()
    assert out["verdict"] == "likely_scam", out
    row = sql(f"SELECT * FROM svc_message_check WHERE person_id = {joe['id']}")[-1]
    # The floor holds whatever the model said (a live model may already say likely_scam).
    assert row["verdict"] == "likely_scam" and row["model_verdict"] in ("safe", "suspicious", "likely_scam")


def family_task(incident_id):
    for t in sql("SELECT * FROM svc_agent_task WHERE workflow = 'family_alert'"):
        if json.loads(t["payload_json"]).get("incident_id") == incident_id:
            return t
    return None


def drive_to(joe, shared, identity="T-Mobile fraud department"):
    key = str(uuid.uuid4())
    call("open_incident", {"request_key": key, "person_id": joe["id"], "entry_point": "app", "caller_e164": "+15555550199"})
    inc = sql(f"SELECT * FROM svc_incident WHERE request_key = '{key}'")[0]
    call("save_answer", {"incident_id": inc["id"], "question_id": "q_identity", "answer": identity})
    call("save_answer", {"incident_id": inc["id"], "question_id": "q_ask", "answer": "yes"})
    call("save_answer", {"incident_id": inc["id"], "question_id": "q_shared", "answer": shared})
    return sql(f"SELECT * FROM svc_incident WHERE id = {inc['id']}")[0]


def alert_rows(incident_id):
    return [x for x in sql(f"SELECT * FROM svc_outbox WHERE related_incident_id = {incident_id}") if x["kind"] == "family_alert"]


def test_c_high_incident_alerts_via_task_poller(joe):
    """No direct /run call: save_answer -> module agent_task -> our poller -> family_alert workflow."""
    t0 = time.time()
    inc = drive_to(joe, "personal_details")
    assert inc["severity"] == "high"
    rows = wait_for(lambda: (lambda r: r if len(r) >= 2 else None)(alert_rows(inc["id"])), 15)
    elapsed = time.time() - t0
    assert rows, "no family alerts from the poller"
    contacts = {c["phone_e164"]: c for c in sql(f"SELECT * FROM svc_contact WHERE person_id = {joe['id']}")}
    by = {r["to_e164"]: r for r in rows}
    assert len(rows) == 2 and set(by) == {TOMMY, MARIA}
    assert by[TOMMY]["channel"] == "imessage" and by[MARIA]["channel"] == "sms"
    for r in rows:
        body = r["body"]
        assert len(body) <= 600 and r["priority"] == "normal"
        assert r["group_key"] == f"family:{joe['id']}:{inc['id']}"
        assert r["recipient_contact_id"] == contacts[r["to_e164"]]["id"]
        assert "was contacted by" not in body  # written by our workflow, not the module template
        low = body.lower()
        # Spec 7 format elements, phrasing-agnostic (live models word it their own way).
        assert "claimed" in low and "personal" in low and "freeze" in low  # credit_freeze is the first vetted step
        assert "check" in low  # "check in" / "check-in"
    task = wait_for(lambda: (lambda t: t if t and t["status"] in ("done", "failed") else None)(family_task(inc["id"])), 5)
    assert task and task["status"] == "done", task
    assert elapsed < 15
    print(f"poller family alerts in {elapsed:.2f}s:\n{rows[0]['body']}")


def test_c2_paused_sharing_critical_reaches_only_emergency_contact(joe):
    call("set_sharing_paused", {"person_id": joe["id"], "paused": True})
    try:
        inc = drive_to(joe, "money", "your bank")
        assert inc["severity"] == "critical"
        task = wait_for(lambda: (lambda t: t if t and t["status"] in ("done", "failed") else None)(family_task(inc["id"])), 15)
        assert task and task["status"] == "done", task
        rows = alert_rows(inc["id"])
        assert rows and all(r["to_e164"] == TOMMY and r["priority"] == "urgent" for r in rows)
        assert "URGENT" in rows[0]["body"].upper() and "was contacted by" not in rows[0]["body"]
    finally:
        call("set_sharing_paused", {"person_id": joe["id"], "paused": False})


def test_c3_poller_paused_module_falls_back_to_template_after_20s(joe):
    r = httpx.post(f"{SVC}/tasks/poller", headers=AUTH, json={"enabled": False})
    assert r.json()["enabled"] is False
    try:
        t0 = time.time()
        inc = drive_to(joe, "link", "Amazon support")
        rows = wait_for(lambda: alert_rows(inc["id"]) or None, 30, 0.5)
        elapsed = time.time() - t0
        assert rows and all("was contacted by" in r["body"] for r in rows), rows  # module template
        assert {r["to_e164"] for r in rows} == {TOMMY, MARIA}
        assert 18 <= elapsed <= 30, elapsed
        task = family_task(inc["id"])
        assert task["status"] == "failed" and task["attempts"] == 0
        print(f"template fallback after {elapsed:.1f}s")
    finally:
        httpx.post(f"{SVC}/tasks/poller", headers=AUTH, json={"enabled": True})


def test_d_verify_tommy_creates_pending_verification_and_message(joe):
    out = run("verify_relative", {"person_id": joe["id"], "relative_name": "Tommy"}).json()
    assert out["verification_id"] > 0
    v = sql(f"SELECT * FROM svc_verification WHERE id = {out['verification_id']}")[0]
    assert v["status"] == "pending" and v["kind"] == "relay"
    msgs = [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{TOMMY}'") if x["kind"] == "verification"]
    assert msgs and "Was it really you?" in msgs[-1]["body"]
    assert any(m["to_e164"] == TOMMY for m in out["messages"])


def test_e_app_check_with_app_token():
    ident = httpx.post(f"{S.spacetime_uri}/v1/identity").json()
    tok = ident["token"]
    phone = f"+1555556{uuid.uuid4().int % 10000:04d}"
    call("register_person", {"phone": phone, "name": "Ana"}, token=tok)
    r = httpx.post(f"{SVC}/app/check", headers={"authorization": f"Bearer {tok}"},
                   json={"text": "Fund Recovery Unit: we found your lost money. Pay a $150 release fee to get your refund.",
                         "source": "app_paste"}, timeout=25)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["verdict"] in ("suspicious", "likely_scam") and set(out) == {"verdict", "reason", "campaign_id", "tips", "evidence_count"}
    me = sql("SELECT * FROM my_person", token=tok)[0]
    assert sql(f"SELECT * FROM svc_message_check WHERE person_id = {me['id']}")
    assert not [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{phone}'") if x["kind"] == "reply"]
    bad = httpx.post(f"{SVC}/app/check", headers={"authorization": "Bearer nope-not-a-token-xxxxx"}, json={"text": "x", "source": "app_paste"})
    assert bad.status_code == 401
    v = httpx.post(f"{SVC}/app/verify", headers={"authorization": f"Bearer {tok}"}, json={"relative_name": "Nobody"}, timeout=25)
    assert v.status_code == 200 and v.json()["verification_id"] == 0


def test_voice_interview_extracts_answers_and_reports_verdict(joe):
    key = str(uuid.uuid4())
    call("open_incident", {"request_key": key, "person_id": joe["id"], "entry_point": "hotline", "caller_e164": "+15555550188"})
    inc = sql(f"SELECT * FROM svc_incident WHERE request_key = '{key}'")[0]
    out = run("interview", {"incident_id": inc["id"], "mode": "voice", "utterance":
              "A man called saying he was my grandson and he was in jail. He asked me for gift cards for bail and said "
              "don't tell his mom. I bought two gift cards and read him the numbers."}).json()
    assert out["severity"] == "critical" and out["done"] is True
    assert out["verdict"] == "likely_scam" and out["evidence_count"] >= 1
    assert out["alert_sent"] is True and "I've told your family" in out["say"]
    row = sql(f"SELECT * FROM svc_incident WHERE id = {inc['id']}")[0]
    assert "gift_card" in row["shared_items"] and row["tactics"] and "grandson" in row["claimed_identity"].lower()


def test_text_interview_queues_next_question(joe):
    key = str(uuid.uuid4())
    call("open_incident", {"request_key": key, "person_id": joe["id"], "entry_point": "imessage", "caller_e164": ""})
    inc = sql(f"SELECT * FROM svc_incident WHERE request_key = '{key}'")[0]
    out = run("interview", {"incident_id": inc["id"], "mode": "text", "utterance": "my bank"}).json()
    assert out["question_id"] == "q_ask" and out["done"] is False
    q = [x for x in sql(f"SELECT * FROM svc_outbox WHERE related_incident_id = {inc['id']}") if x["to_e164"] == JOE]
    assert q and "(2 of 5)" in q[-1]["body"]
    out = run("interview", {"incident_id": inc["id"], "checkin": True}).json()
    assert out["question_id"] == "q_shared"
    assert any(x["kind"] == "checkin" for x in sql(f"SELECT * FROM svc_outbox WHERE related_incident_id = {inc['id']}"))


def test_router_routes_forwarded_text_and_commands(joe):
    r = run("router", {"text": "verify Tommy", "from_e164": JOE, "channel": "imessage", "person_id": 0, "mode": "text"}).json()
    assert r["intent"] == "verify_relative" and r["args"]["person_id"] == joe["id"]
    r = run("router", {"text": "What's the weather tomorrow?", "from_e164": JOE, "channel": "imessage", "mode": "text"}).json()
    assert r["intent"] == "out_of_scope"
    r = run("router", {"text": "Congrats! You won a $500 gift card, claim at https://bit.ly/3xYz", "from_e164": JOE,
                       "channel": "imessage", "mode": "text", "dispatch": True}).json()
    assert r["intent"] == "scam_check" and r["result"]["verdict"] in ("suspicious", "likely_scam")


def test_briefing_and_push_without_keys(joe):
    out = run("briefing", {"person_id": joe["id"]}).json()
    assert out["summary_text"].startswith(f"{S.app_name} weekly briefing") and len(out["summary_text"]) <= 1200
    assert sql(f"SELECT * FROM svc_briefing WHERE person_id = {joe['id']}")
    p = httpx.post(f"{SVC}/push", headers=AUTH, json={"to_e164": TOMMY, "title": "t", "body": "Did you send this?", "category": "TRUSTED_SENDER"})
    assert p.json() == {"sent": False}
