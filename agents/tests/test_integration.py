"""Integration tests against SpacetimeDB `kavach-agents` and the running service (AGENT_SERVICE_URL, default :8088).

    SPACETIME_DB_NAME=kavach-agents uv run uvicorn server:app --port 8088   # in another shell
    SPACETIME_DB_NAME=kavach-agents uv run pytest -m integration -v
"""
import json
import os
import subprocess
import time
import re
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
    # Cites the community pattern (7a acceptance); live models vary the exact wording.
    assert re.search(r"(many|other) people|reported|community", out["reason"], re.I), out
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


def _sign_in(tok: str, phone: str, name: str) -> None:
    """App sign-in (contracts §7): request a code, then verify. Demo numbers (+1555555…) accept 000000."""
    call("request_sign_in", {"phone": phone, "name": name}, token=tok)
    call("verify_sign_in", {"phone": phone, "code": "000000"}, token=tok)


def test_e_app_check_with_app_token():
    ident = httpx.post(f"{S.spacetime_uri}/v1/identity").json()
    tok = ident["token"]
    phone = f"+1555555{5000 + uuid.uuid4().int % 5000:04d}"
    _sign_in(tok, phone, "Ana")
    r = httpx.post(f"{SVC}/app/check", headers={"authorization": f"Bearer {tok}"},
                   json={"text": "Fund Recovery Unit: we found your lost money. Pay a $150 release fee to get your refund.",
                         "source": "app_paste"}, timeout=25)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["verdict"] in ("suspicious", "likely_scam") and set(out) - {"check_id"} == {"verdict", "reason", "campaign_id", "tips", "evidence_count"}
    me = sql("SELECT * FROM my_person", token=tok)[0]
    assert sql(f"SELECT * FROM svc_message_check WHERE person_id = {me['id']}")
    assert not [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{phone}'") if x["kind"] == "reply"]
    bad = httpx.post(f"{SVC}/app/check", headers={"authorization": "Bearer nope-not-a-token-xxxxx"}, json={"text": "x", "source": "app_paste"})
    assert bad.status_code == 401
    v = httpx.post(f"{SVC}/app/verify", headers={"authorization": f"Bearer {tok}"}, json={"relative_name": "Nobody"}, timeout=25)
    assert v.status_code == 200 and v.json()["verification_id"] == 0


def test_voice_interview_extracts_answers_and_reports_verdict(joe):
    key = str(uuid.uuid4())
    call("open_incident", {"request_key": key, "person_id": joe["id"], "entry_point": "app", "caller_e164": "+15555550188"})
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


# --- section 7: iMessage commands, training labels, call reports ----------------------------------

TRAINING = Path(__file__).resolve().parents[1] / "data" / "training"


def replies_after(before, to=JOE, timeout=10):
    return wait_for(lambda: [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{to}'")
                             if x["id"] not in before and x["kind"] == "reply"], timeout)


def outbox_ids():
    return {r["id"] for r in sql("SELECT * FROM svc_outbox")}


def route(text, dispatch=True):
    r = run("router", {"text": text, "from_e164": JOE, "channel": "imessage", "person_id": 0, "mode": "text",
                       "dispatch": dispatch})
    assert r.status_code == 200, r.text
    return r.json()


def report_count(value):
    rows = [r for r in sql("SELECT * FROM svc_community_report") if r["value"] == value]
    return rows[0]["reporter_count"] if rows else 0


def test_command_report_number_increases_count_and_replies(joe):
    before, n0 = outbox_ids(), report_count("+15555550144")
    out = route("report +15555550144")
    assert out["intent"] == "command" and out["result"]["action"] == "report" and out["result"]["ok"], out
    assert report_count("+15555550144") == n0 + 1
    rows = replies_after(before)
    assert rows and rows[-1]["body"].startswith(f"{S.app_name}: Reported +1 555-555-0144.")
    print("reply:", rows[-1]["body"])


def test_command_natural_report_of_last_call(joe):
    key = str(uuid.uuid4())
    call("open_incident", {"request_key": key, "person_id": joe["id"], "entry_point": "app", "caller_e164": "+15555550177"})
    before, n0 = outbox_ids(), report_count("+15555550177")
    out = route("can you report that number that just called me")
    assert out["intent"] == "command" and out["result"]["action"] == "report", out
    assert report_count("+15555550177") == n0 + 1
    print("reply:", replies_after(before)[-1]["body"])


def test_command_add_family_natural_phrasing(joe):
    before = outbox_ids()
    out = route("please add my son David, his number is 214-555-0100")
    assert out["intent"] == "command" and out["result"]["action"] == "add_family" and out["result"]["ok"], out
    c = [x for x in sql(f"SELECT * FROM svc_contact WHERE person_id = {joe['id']}") if x["phone_e164"] == "+12145550100"]
    assert c and c[0]["name"] == "David" and c[0]["relationship"] == "son" and c[0]["channel"] == "imessage"
    assert c[0]["consent_status"] == "invited"
    assert any("join Joe" in x["body"] for x in sql("SELECT * FROM svc_outbox WHERE to_e164 = '+12145550100'"))
    print("reply:", replies_after(before)[-1]["body"])


def test_command_list_family(joe):
    before = outbox_ids()
    out = route("who is in my family")
    assert out["result"]["action"] == "list_family"
    body = replies_after(before)[-1]["body"]
    assert "Tommy" in body and "Maria" in body
    print("reply:", body)


def test_command_status_counts(joe):
    before = outbox_ids()
    out = route("status")
    data = out["result"]["data"]
    assert out["result"]["action"] == "status" and data["checks"]["total"] >= 1, out
    body = replies_after(before)[-1]["body"]
    assert "This week you checked" in body
    print("reply:", body)


def test_command_code_word_keeps_settings(joe):
    route("code word bluebird")
    p = sql(f"SELECT * FROM svc_person WHERE id = {joe['id']}")[0]
    assert p["family_code_word"] == "bluebird" and p["critical_overrides_pause"] == joe["critical_overrides_pause"]
    assert '"bluebird"' in route("what's my code word?")["result"]["reply"]


def test_feedback_wrong_after_check_writes_label(joe):
    out = run("scam_check", {"person_id": joe["id"], "text": "Hi Joe, the church potluck moved to 6pm Sunday. Bring a dish!",
                             "source": "imessage", "reply_to_e164": JOE, "reply_channel": "imessage"}).json()
    labels_before = (TRAINING / "labels.jsonl").read_text().count("\n") if (TRAINING / "labels.jsonl").exists() else 0
    r = route("wrong")
    assert r["intent"] == "command" and r["result"]["action"] == "feedback" and r["result"]["ok"], r
    lines = (TRAINING / "labels.jsonl").read_text().splitlines()
    assert len(lines) == labels_before + 1
    lb = json.loads(lines[-1])
    assert lb["source"] == "imessage" and lb["correct"] is False and lb["previous_verdict"] == out["verdict"]
    d = [json.loads(x) for x in (TRAINING / "decisions.jsonl").read_text().splitlines()]
    assert any(x["id"] == lb["decision_id"] and x["workflow"] == "scam_check" for x in d)
    print("label:", lb["label"], "reply:", r["result"]["reply"])


def _app_identity(name="Rita"):
    tok = httpx.post(f"{S.spacetime_uri}/v1/identity").json()["token"]
    phone = f"+1555555{5000 + uuid.uuid4().int % 5000:04d}"
    _sign_in(tok, phone, name)
    return tok, phone


def test_app_feedback_labels_a_check():
    tok, _ = _app_identity()
    out = httpx.post(f"{SVC}/app/check", headers={"authorization": f"Bearer {tok}"},
                     json={"text": "Your Amazon order shipped and arrives Tuesday.", "source": "app_paste"}, timeout=25).json()
    cid = out.get("check_id") or sql("SELECT * FROM my_checks", token=tok)[-1]["id"]
    r = httpx.post(f"{SVC}/app/feedback", headers={"authorization": f"Bearer {tok}"},
                   json={"check_id": cid, "correct": False, "label": "likely_scam", "note": "it was fake"}, timeout=10)
    assert r.status_code == 200, r.text
    assert r.json()["label"] == "likely_scam" and r.json()["check_id"] == cid
    assert httpx.post(f"{SVC}/app/feedback", headers={"authorization": f"Bearer {tok}"},
                      json={"check_id": 999999, "correct": True}).status_code == 404


def test_ios_call_report_nested_payload():
    tok, _ = _app_identity("Sam")
    caller = f"+1555558{uuid.uuid4().int % 10000:04d}"
    body = {"userInfo": {"token": tok, "caller_e164": caller, "reported_at": int(time.time()),
                         "answers": {"q_identity": "Bank of America fraud department", "q_ask": "yes",
                                     "q_shared": "code", "q_secrecy": "yes", "q_help": "yes"}}}
    r = httpx.post(f"{SVC}/ios/call-report", json=body, timeout=25)
    assert r.status_code == 200, r.text
    out = r.json()
    inc = sql(f"SELECT * FROM svc_incident WHERE id = {out['incident_id']}")[0]
    assert inc["entry_point"] == "report_swipe" and inc["caller_e164"] == caller
    assert json.loads(inc["answers_json"])["q_shared"] == "code" and "code" in inc["shared_items"]
    assert out["severity"] == inc["severity"] and inc["severity"] in ("high", "critical")
    assert report_count(caller) == 1
    again = httpx.post(f"{SVC}/ios/call-report", json=body, timeout=25).json()
    assert again["duplicate"] is True and again["incident_id"] == out["incident_id"] and report_count(caller) == 1
    assert httpx.post(f"{SVC}/ios/call-report", json={"userInfo": {"token": "x" * 40}}).status_code == 401
    print("call report:", out)


def test_router_still_routes_forwarded_scams_and_questions(joe):
    assert route("Report suspicious activity on your account at chase-secure-login.top now", dispatch=False)["intent"] == "scam_check"
    assert route("my nephew wants gift cards for an emergency, should I?", dispatch=False)["intent"] == "advise"


# --- forwarded-message wrapper and the clarifying question (CONTRACTS section 7) -------------------

def _texter():
    """A fresh number per test: the router keeps per-person follow-up state in the service process."""
    return f"+1555557{uuid.uuid4().int % 10000:04d}"


def _say(phone, text):
    before = {r["id"] for r in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{phone}'")}
    r = run("router", {"text": text, "from_e164": phone, "channel": "imessage", "mode": "text", "dispatch": True})
    assert r.status_code == 200, r.text
    out = r.json()
    rows = wait_for(lambda: [x for x in sql(f"SELECT * FROM svc_outbox WHERE to_e164 = '{phone}'")
                             if x["id"] not in before and x["kind"] == "reply"], 12)
    print(f"\n>>> {text!r}\n    intent={out['intent']}\n    reply={rows[-1]['body'] if rows else None!r}")
    return out, rows


def test_wrapped_forward_is_scam_checked_on_the_inner_text_only():
    phone = _texter()
    out, rows = _say(phone, 'Forwarded message:\nFrom: +1 555 555 0144\n"USPS: your package is on hold, '
                            'update your address at usps-redelivery.info"')
    assert out["intent"] == "scam_check"
    assert out["args"]["text"] == "USPS: your package is on hold, update your address at usps-redelivery.info"
    assert out["args"]["sender_e164"] == "+15555550144" and "teach_wrapper" not in out["args"]
    assert out["result"]["verdict"] in ("suspicious", "likely_scam") and rows
    assert "Forwarded message:" not in rows[-1]["body"]


def test_plain_question_is_answered_not_scam_checked():
    out, rows = _say(_texter(), "should I send money to my grandson?")
    assert out["intent"] == "advise" and rows


def test_command_from_own_voice():
    out, rows = _say(_texter(), "can you report +1 555 555 0144")
    assert out["intent"] == "command" and out["result"]["action"] == "report" and rows


def test_ambiguous_text_asks_then_2_answers_the_question():
    phone = _texter()
    out, rows = _say(phone, "send money")
    assert out["intent"] == "clarify"
    assert rows and rows[-1]["body"].endswith("Reply 1 if you received it, 2 if it's your question.")
    out, rows = _say(phone, "2")
    assert out["intent"] == "advise" and out["args"]["text"] == "send money" and rows


def test_ambiguous_text_then_1_checks_it_and_teaches_the_wrapper_once():
    phone = _texter()
    _say(phone, "send money")
    out, rows = _say(phone, "1")
    assert out["intent"] == "scam_check" and out["args"]["text"] == "send money" and out["args"]["teach_wrapper"] is True
    assert rows and 'start a forwarded text with "Forwarded message:"' in rows[-1]["body"]
    out, rows = _say(phone, "Your account has been locked. Call us at 800-555-0100 to unlock it")
    assert out["intent"] == "scam_check" and not out["args"].get("teach_wrapper")
    assert rows and "Forwarded message:" not in rows[-1]["body"]
