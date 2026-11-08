"""POST /ios/call-report: flexible payload parsing (top level or nested), idempotent request_key, and the
reducer sequence run with the app's own token."""
import asyncio
import json

import pytest

from kavach.call_report import CallReportError, handle_call_report, parse_call_report

TOK = "eyJhbGciOi.app-token-for-joe.signature"
REPORT = {"token": TOK, "caller_e164": "+15555550188", "reported_at": 1794150000,
          "answers": {"q_identity": "Bank of America fraud dept", "q_ask": "yes", "q_shared": ["code", "personal details"],
                      "q_secrecy": True, "q_help": "no"}}


def test_top_level_payload():
    rep = parse_call_report(REPORT)
    assert rep["token"] == TOK and rep["caller_e164"] == "+15555550188"
    assert rep["answers"] == [("q_identity", "Bank of America fraud dept"), ("q_ask", "yes"), ("q_secrecy", "yes"),
                              ("q_help", "no"), ("q_shared", "code,personal_details")]
    assert rep["request_key"].startswith("callrep-") and len(rep["request_key"]) <= 64


@pytest.mark.parametrize("body", [
    {"userInfo": REPORT},
    {"userInfo": json.dumps(REPORT)},
    {"classification": {"action": "reportJunk", "userInfo": REPORT}},
    {"payload": {"report": REPORT}},
])
def test_nested_payloads(body):
    assert parse_call_report(body) == parse_call_report(REPORT)


def test_request_key_is_stable_and_specific():
    k = parse_call_report(REPORT)["request_key"]
    assert parse_call_report({**REPORT, "reported_at": 1794150000000})["request_key"] == k  # millis == seconds
    assert parse_call_report({**REPORT, "reported_at": "2026-11-08T12:20:00Z"})["request_key"] != k
    assert parse_call_report({**REPORT, "reported_at": 1794150060})["request_key"] != k
    assert parse_call_report({**REPORT, "caller_e164": "+15555550199"})["request_key"] != k


def test_loose_fields_and_bad_values():
    rep = parse_call_report({"userInfo": {"token": TOK, "caller": "(214) 555-0100", "q_ask": "maybe",
                                          "answers": {"q_shared": "nothing", "q_engaged": False, "q_bogus": "x",
                                                      "q_summary": "He wanted code 482913"}}})
    assert rep["caller_e164"] == "+12145550100"
    assert dict(rep["answers"]) == {"q_engaged": "no", "q_summary": "He wanted code [code]", "q_shared": "nothing"}


def test_token_from_bearer_and_rejections():
    rep = parse_call_report({"caller_e164": "+15555550188", "answers": {}}, bearer=TOK)
    assert rep["token"] == TOK
    with pytest.raises(CallReportError) as e:
        parse_call_report({"caller_e164": "+15555550188", "answers": {}})
    assert e.value.status == 401
    with pytest.raises(CallReportError) as e:
        parse_call_report(["not", "an", "object"])
    assert e.value.status == 400


class AppDb:
    """my_person / my_incidents for one app token; reducers recorded with the token they used."""

    def __init__(self):
        self.calls = []
        self.incidents = []

    async def one(self, query, token=None):
        rows = await self.sql(query, token)
        return rows[0] if rows else None

    async def sql(self, query, token=None):
        if token != TOK:
            return []
        if "my_person" in query:
            return [{"id": 1, "phone_e164": "+15555550101"}]
        if "my_incidents" in query:
            return [i for i in self.incidents if f"'{i['request_key']}'" in query or f"id = {i['id']}" in query]
        return []

    async def call(self, name, args, token=None):
        assert token == TOK
        self.calls.append((name, args))
        if name == "open_incident":
            self.incidents.append({"id": 9, "request_key": args["request_key"], "answers_json": "{}", "severity": "",
                                   "status": "open", "entry_point": args["entry_point"]})
        elif name == "save_answer":
            inc = self.incidents[0]
            answers = json.loads(inc["answers_json"])
            answers[args["question_id"]] = args["answer"]
            inc["answers_json"] = json.dumps(answers)
            if args["question_id"] == "q_shared" and "code" in args["answer"]:
                inc["severity"] = "critical"


def test_handle_runs_reducers_with_app_token_and_is_idempotent():
    db = AppDb()
    rep = parse_call_report({"userInfo": REPORT})
    out = asyncio.run(handle_call_report(db, rep))
    assert out == {"ok": True, "incident_id": 9, "severity": "critical", "request_key": rep["request_key"],
                   "duplicate": False, "answers_saved": 5, "reported": True}
    names = [n for n, _ in db.calls]
    assert names == ["open_incident"] + ["save_answer"] * 5 + ["report_number"]
    assert db.calls[0][1]["entry_point"] == "report_swipe" and db.calls[0][1]["caller_e164"] == "+15555550188"
    assert db.calls[-1][1] == {"person_id": 1, "kind": "number", "value": "+15555550188"}
    again = asyncio.run(handle_call_report(db, parse_call_report(REPORT)))
    assert again["duplicate"] is True and again["answers_saved"] == 0 and again["incident_id"] == 9
    assert [n for n, _ in db.calls].count("open_incident") == 1


def test_unknown_token_is_401():
    rep = parse_call_report({**REPORT, "token": "x" * 40})
    with pytest.raises(CallReportError) as e:
        asyncio.run(handle_call_report(AppDb(), rep))
    assert e.value.status == 401


def test_ios_request_key_is_used_so_app_replay_matches():
    from kavach.call_report import parse_call_report as parse_report
    payload = {"userInfo": {"token": "eyJ" + "x" * 40, "caller_e164": "+15555550199", "reported_at": 1794150000,
                            "request_key": "ios-report-" + "a" * 40, "answers": {"q_shared": "nothing"}}}
    assert parse_report(payload)["request_key"] == "ios-report-" + "a" * 40
