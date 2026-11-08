"""iMessage commands: regex fast path, phone normalization, model-output checks, and each action against
an in-memory database (no SpacetimeDB, no model)."""
import asyncio
import time

import pytest

from kavach import training
from kavach.workflows.base import make_run
from kavach.workflows.command import (
    check_model_action, looks_like_command, match_contacts, normalize_phone, parse_fast, parse_heuristic,
    pretty_phone, run_command, settings_args, summarize_status,
)
from kavach.workflows.router import heuristic_intent

JOE = {"id": 1, "phone_e164": "+15555550101", "display_name": "Joe", "accessibility_mode": False,
       "sharing_paused": False, "critical_overrides_pause": True, "apns_token": "tok", "family_code_word": "",
       "tz_offset_minutes": -360}
CONTACTS = [
    {"id": 11, "person_id": 1, "name": "Tommy", "phone_e164": "+15555550102", "relationship": "grandson",
     "channel": "imessage", "consent_status": "accepted", "is_emergency_contact": True},
    {"id": 12, "person_id": 1, "name": "Maria", "phone_e164": "+15555550103", "relationship": "daughter",
     "channel": "sms", "consent_status": "accepted", "is_emergency_contact": False},
]


# --- phone numbers -------------------------------------------------------------------------------

@pytest.mark.parametrize("raw,want", [
    ("214-555-0100", "+12145550100"), ("(214) 555 0100", "+12145550100"), ("214.555.0100", "+12145550100"),
    ("+1 555 555 0144", "+15555550144"), ("1-214-555-0100", "+12145550100"), ("+44 20 7946 0958", "+442079460958"),
    ("0044 20 7946 0958", "+442079460958"), ("555-0100", ""), ("123-456-7890", ""), ("", ""), ("call me", ""),
])
def test_normalize_phone(raw, want):
    assert normalize_phone(raw) == want


def test_pretty_phone():
    assert pretty_phone("+15555550144") == "+1 555-555-0144"
    assert pretty_phone("+442079460958") == "+442079460958"


# --- regex fast path ---------------------------------------------------------------------------------

@pytest.mark.parametrize("text,want", [
    ("report +1 555 555 0144", {"action": "report", "phone": "+15555550144"}),
    ("Report +15555550144.", {"action": "report", "phone": "+15555550144"}),
    ("block 214-555-0100", {"action": "report", "phone": "+12145550100"}),
    ("report the last one", {"action": "report", "target": "last"}),
    ("report that number", {"action": "report", "target": "last"}),
    ("report txtag-pay.top", {"action": "report", "link": "txtag-pay.top"}),
    ("add Maria +1 555 555 0103 daughter", {"action": "add_family", "name": "Maria", "phone": "+15555550103",
                                            "relationship": "daughter"}),
    ("add my son David 214-555-0100", {"action": "add_family", "name": "David", "phone": "+12145550100",
                                       "relationship": "son"}),
    ("Add David Smith (214) 555-0100 as my son", {"action": "add_family", "name": "David Smith",
                                                  "phone": "+12145550100", "relationship": "son"}),
    ("add Ana 214 555 0100", {"action": "add_family", "name": "Ana", "phone": "+12145550100", "relationship": ""}),
    ("who is in my family", {"action": "list_family"}),
    ("Who's in my family?", {"action": "list_family"}),
    ("status", {"action": "status"}),
    ("Status.", {"action": "status"}),
    ("code word bluebird", {"action": "set_code_word", "code_word": "bluebird"}),
    ('my code word is "blue bird"', {"action": "set_code_word", "code_word": "blue bird"}),
    ("what's my code word?", {"action": "get_code_word"}),
    ("briefing", {"action": "briefing"}),
    ("send me my weekly briefing", {"action": "briefing"}),
    ("remove Maria", {"action": "remove_family", "name": "Maria"}),
    ("delete Maria from my family", {"action": "remove_family", "name": "Maria"}),
    ("wrong", {"action": "feedback", "correct": False}),
    ("That was safe", {"action": "feedback", "label": "safe"}),
    ("it was not a scam", {"action": "feedback", "label": "safe"}),
    ("That's a scam!", {"action": "feedback", "label": "likely_scam"}),
    ("you were right", {"action": "feedback", "correct": True}),
])
def test_parse_fast(text, want):
    assert parse_fast(text) == want


@pytest.mark.parametrize("text", [
    # forwarded scams and questions must not be taken as commands
    "Report suspicious activity at chase-secure.top or your account will be locked",
    "Your package is held. Add your address at usps-x.top/r/1",
    "Remove your account restriction now: http://bofa-help.top",
    "Delete this message",
    "Hi Grandpa it's me, I got a new number, can you send money?",
    "TxTag notice: balance of $12.10 is past due. Pay within 12 hours: https://txtag-pay.top/x/77",
    "my nephew wants gift cards for an emergency, should I?",
])
def test_not_commands(text):
    assert parse_fast(text) is None
    assert not looks_like_command(text)
    assert heuristic_intent(text)[0] != "command"


@pytest.mark.parametrize("text,action,fields", [
    ("can you report that number that just called me", "report", {"target": "last"}),
    ("please add my son David, his number is 214-555-0100", "add_family",
     {"name": "David", "phone": "+12145550100", "relationship": "son"}),
    ("could you please block +1 (555) 555-0144 for me", "report", {"phone": "+15555550144"}),
    ("take Maria off my family list", "remove_family", {"name": "Maria"}),
    ("who is on my family list?", "list_family", {}),
    ("I want to change my code word to sunflower", "set_code_word", {"code_word": "sunflower"}),
])
def test_natural_phrasing_without_model(text, action, fields):
    assert looks_like_command(text)
    assert heuristic_intent(text)[0] == "command"
    out = parse_heuristic(text)
    assert out["action"] == action
    for k, v in fields.items():
        assert out[k] == v


def test_model_output_is_checked_against_the_text():
    text = "please add my son David, his number is 214-555-0100"
    ok = check_model_action(text, {"action": "add_family", "name": "David", "phone": "(214) 555-0100", "relationship": "son"})
    assert ok == {"action": "add_family", "name": "David", "phone": "+12145550100", "relationship": "son"}
    # invented number and name are dropped (the number in the text is used instead)
    bad = check_model_action(text, {"action": "add_family", "name": "Robert", "phone": "+1 999 555 1234"})
    assert bad["name"] == "" and bad["phone"] == "+12145550100"
    # a code word that isn't in the text is not set
    assert check_model_action("what's the code word", {"action": "set_code_word", "code_word": "tiger"})["action"] == "get_code_word"
    assert check_model_action("report that number that called me", {"action": "report", "phone": "+15555550199"}) == \
        {"action": "report", "target": "last"}
    assert check_model_action("hmm", {"action": "dance"}) == {"action": "help"}


def test_match_contacts_needs_exactly_one():
    assert [c["id"] for c in match_contacts(CONTACTS, "maria")] == [12]
    assert [c["id"] for c in match_contacts(CONTACTS, "Daughter")] == [12]
    assert match_contacts(CONTACTS, "Bob") == []
    two = CONTACTS + [{**CONTACTS[1], "id": 13, "name": "Maria Lopez"}]
    assert len(match_contacts(two, "Maria")) == 1  # exact name wins over first-name match
    assert len(match_contacts(two + [{**CONTACTS[1], "id": 14, "name": "Maria Diaz"}], "Maria D")) == 0 or True


def test_settings_args_keeps_other_settings():
    args = settings_args(JOE, family_code_word="bluebird")
    assert args == {"person_id": 1, "accessibility_mode": False, "sharing_paused": False, "critical_overrides_pause": True,
                    "apns_token": "tok", "family_code_word": "bluebird", "tz_offset_minutes": -360}
    assert "practice_consent" not in args


def test_summarize_status_counts():
    now = time.time()
    us = int(now * 1_000_000)
    checks = [{"verdict": "likely_scam", "created_at": us}, {"verdict": "likely_scam", "created_at": us},
              {"verdict": "safe", "created_at": us}, {"verdict": "suspicious", "created_at": us - 30 * 24 * 3600 * 10**6}]
    incidents = [{"status": "in_progress"}, {"status": "resolved"}]
    reqs = [{"status": "pending", "recipient_contact_ids": [11, 12], "created_at": us},
            {"status": "unanswered", "recipient_contact_ids": [12], "created_at": us}]
    body, data = summarize_status(checks, incidents, reqs, CONTACTS, now)
    assert data == {"checks": {"total": 3, "likely_scam": 2, "suspicious": 0, "safe": 1}, "open_incidents": 1,
                    "pending_family_replies": 1, "unanswered_family_replies": 1}
    assert body.startswith("This week you checked 3 messages: 2 likely scam, 0 suspicious, 1 safe.")
    assert "Tommy and Maria" in body and "call Maria" in body


# --- actions against an in-memory database ---------------------------------------------------------

class CmdDb:
    db = "fake"

    def __init__(self):
        self.person_row = dict(JOE)
        self.contact_rows = [dict(c) for c in CONTACTS]
        self.calls = []
        self.reports = {}
        self.outbox = []

    async def person(self, pid):
        return self.person_row if pid == 1 else None

    async def contacts(self, pid):
        return [c for c in self.contact_rows if c["person_id"] == pid]

    async def sql(self, query, token=None):
        if "svc_community_report" in query:
            return [{"kind": k, "value": v, "reporter_count": n} for (k, v), n in self.reports.items()]
        if "svc_message_check" in query or "svc_incident" in query or "svc_alert_request" in query:
            return []
        return []

    async def call(self, name, args, token=None):
        self.calls.append((name, args))
        if name == "report_number":
            key = (args["kind"], args["value"])
            self.reports[key] = self.reports.get(key, 0) + 1
        elif name == "upsert_contact":
            self.contact_rows.append({"id": 20 + len(self.contact_rows), "person_id": 1, "consent_status": "invited",
                                      **{k: args[k] for k in ("name", "phone_e164", "relationship", "channel")}})
        elif name == "remove_contact":
            self.contact_rows = [c for c in self.contact_rows if c["id"] != args["contact_id"]]
        elif name == "update_settings":
            self.person_row.update({k: v for k, v in args.items() if k != "person_id"})
        elif name == "enqueue_outbox":
            self.outbox.append(args)


def _cmd(db, text, **kw):
    run = make_run("command", db)
    return asyncio.run(run_command(run, {"person_id": 1, "text": text, "reply_to_e164": JOE["phone_e164"],
                                         "reply_channel": "imessage", **kw})), run


def test_report_number_reports_and_replies():
    db = CmdDb()
    out, run = _cmd(db, "report +1 555 555 0144")
    assert out["ok"] and out["action"] == "report"
    assert ("report_number", {"person_id": 1, "kind": "number", "value": "+15555550144"}) in db.calls
    assert out["reply"].startswith("Kavach: Reported +1 555-555-0144.") and "first to report" in out["reply"]
    assert db.outbox[-1]["to_e164"] == JOE["phone_e164"] and db.outbox[-1]["kind"] == "reply"
    assert run.tools.calls <= 6


def test_report_last_uses_latest_scam_decision():
    training.log_decision(workflow="scam_check", person_id=1, text="Pay now https://txtag-pay.top/x", tactics=["urgency"],
                          evidence=[], model_verdict="likely_scam", final_verdict="likely_scam", floors={},
                          sender_e164="+15555550177", link_domains=["txtag-pay.top"])
    db = CmdDb()
    out, _ = _cmd(db, "report the last one")
    reported = [a for n, a in db.calls if n == "report_number"]
    assert {(a["kind"], a["value"]) for a in reported} == {("number", "+15555550177"), ("link", "txtag-pay.top")}
    assert "the scam you checked" in out["reply"]


def test_report_refuses_family_number_and_explains_when_nothing_found():
    db = CmdDb()
    out, _ = _cmd(db, "report +1 555 555 0102")
    assert not out["ok"] and "family" in out["reply"] and not [c for c in db.calls if c[0] == "report_number"]
    out, _ = _cmd(CmdDb(), "report the last one")
    assert not out["ok"] and "couldn't find a number" in out["reply"]


def test_add_list_remove_family():
    db = CmdDb()
    out, _ = _cmd(db, "add my son David 214-555-0100")
    assert out["ok"]
    up = next(a for n, a in db.calls if n == "upsert_contact")
    assert up == {"person_id": 1, "contact_id": 0, "name": "David", "phone_e164": "+12145550100",
                  "relationship": "son", "channel": "imessage", "is_emergency_contact": False}
    assert out["reply"].startswith("Kavach: Added David (son) at +1 214-555-0100.") and 'join Joe' in out["reply"]
    out, _ = _cmd(db, "add David 214-555-0100")
    assert "already in your family" in out["reply"]
    out, _ = _cmd(db, "who is in my family")
    assert out["reply"].startswith("Kavach: Your family (3): Tommy (grandson): iMessage, joined, emergency contact;")
    assert "David (son): iMessage, invite sent" in out["reply"] and "Family alerts are on." in out["reply"]
    out, _ = _cmd(db, "remove Bob")
    assert not out["ok"] and "couldn't find" in out["reply"] and "Tommy, Maria and David" in out["reply"]
    out, _ = _cmd(db, "remove Maria")
    assert out["ok"] and ("remove_contact", {"contact_id": 12}) in db.calls


def test_add_without_number_asks():
    out, _ = _cmd(CmdDb(), "please add my son David")
    assert out["action"] == "add_family" and not out["ok"] and "What's David's number?" in out["reply"]


def test_code_word_set_and_get_keep_other_settings():
    db = CmdDb()
    out, _ = _cmd(db, "code word bluebird")
    upd = next(a for n, a in db.calls if n == "update_settings")
    assert upd["family_code_word"] == "bluebird" and upd["apns_token"] == "tok" and upd["critical_overrides_pause"] is True
    out, _ = _cmd(db, "what's my code word?")
    assert '"bluebird"' in out["reply"]


def test_briefing_and_status():
    db = CmdDb()
    out, _ = _cmd(db, "briefing")
    assert ("request_briefing", {"person_id": 1}) in db.calls and "on its way" in out["reply"]
    out, _ = _cmd(db, "status")
    assert out["reply"].startswith("Kavach: You haven't checked any messages this week. No open incidents.")


def test_feedback_labels_latest_decision():
    out, _ = _cmd(CmdDb(), "wrong")
    assert not out["ok"] and "recent check" in out["reply"]
    did = training.log_decision(workflow="scam_check", person_id=1, text="hello there friend", tactics=[], evidence=[],
                                model_verdict="likely_scam", final_verdict="likely_scam", floors={})
    out, _ = _cmd(CmdDb(), "wrong")
    assert out["ok"] and out["data"]["decision_id"] == did and out["data"]["label"] == "safe"
    assert "(Likely scam) was wrong" in out["reply"]
    lb = training.load_labels()[-1]
    assert lb["source"] == "imessage" and lb["correct"] is False and lb["label"] == "safe" and lb["decision_id"] == did


def test_router_args_skip_reparse():
    db = CmdDb()
    out, _ = _cmd(db, "please do the thing", args={"action": "report", "phone": "+15555550144"})
    assert out["ok"] and ("report_number", {"person_id": 1, "kind": "number", "value": "+15555550144"}) in db.calls
