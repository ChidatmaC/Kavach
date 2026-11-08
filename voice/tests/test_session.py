"""HotlineSession unit tests with in-memory fakes (no network)."""
import asyncio
import io
import logging

import pytest

import hotline
from config import Config
from fakes import FakeAgent, FakeStdb, Recorder, make_cfg
from hotline import FALLBACK, FILLER, GOODBYE, REPEAT_PROMPT, REPEAT_PROMPT_FIRST, SAFETY_LINE, HotlineSession

JOE = "+15555550101"
PERSONS = {JOE: {"id": 1, "phone_e164": JOE, "display_name": "Joe"}}


def session(stdb, agent, rec, caller=JOE, **cfg):
    return HotlineSession(caller_e164=caller, stdb=stdb, agent=agent, cfg=make_cfg(**cfg),
                          speak=rec.speak, hangup=rec.hangup, call_id="t")


async def test_greeting_uses_app_display_name(monkeypatch):
    monkeypatch.setenv("APP_DISPLAY_NAME", "Shieldy")
    cfg = Config.load()
    assert cfg.app_name == "Shieldy"
    rec, stdb = Recorder(), FakeStdb()
    s = HotlineSession(caller_e164=JOE, stdb=stdb, agent=FakeAgent(), cfg=cfg, speak=rec.speak)
    await s.start()
    assert rec.lines[0] == "Hi, this is Shieldy. Tell me what happened, and I'll help you work out if it's a scam."
    assert rec.lines[1] == SAFETY_LINE  # tells callers never to say codes, PINs, card or account numbers
    assert "Kavach" not in rec.text()


async def test_known_caller_opens_hotline_incident_for_person():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    s = session(stdb, FakeAgent(), rec)
    await s.start()
    await s._ensure_setup()
    [args] = stdb.reducer_calls("open_incident")
    assert args["person_id"] == 1 and args["entry_point"] == "hotline" and args["caller_e164"] == JOE
    assert s.incident_id == 1


async def test_unknown_caller_path():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"next_question": "Who did they say they were?", "done": False},
                       {"say": "Thank you.", "done": True, "set_severity": ("medium", [])}], stdb=stdb)
    s = session(stdb, agent, rec, caller="+15555550999")
    await s.start()
    await s.on_utterance("Someone called saying my grandson was in jail and needed bail")
    await s.on_utterance("He said he was my grandson")
    [args] = stdb.reducer_calls("open_incident")
    assert args["person_id"] == 0 and args["entry_point"] == "hotline"
    assert s.person is None
    assert not stdb.reducer_calls("tell_my_family")
    assert "Would you like me to tell your family?" not in rec.text()
    assert "set up Kavach on your phone" in rec.text()
    assert rec.hung_up


async def test_withheld_number_is_unknown_caller():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    s = session(stdb, FakeAgent(), rec, caller="anonymous")
    await s.start()
    await s._ensure_setup()
    assert stdb.reducer_calls("open_incident")[0]["caller_e164"] == ""


async def test_repeat_offer_and_dtmf_and_spoken_repeat():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"next_question": "Who did they say they were?", "done": False}])
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("I got a weird call")
    assert rec.lines[-2:] == ["Who did they say they were?", REPEAT_PROMPT_FIRST]
    n = len(rec.lines)
    await s.on_dtmf("1")
    assert rec.lines[n:] == ["Who did they say they were?", REPEAT_PROMPT]
    n = len(rec.lines)
    await s.on_utterance("can you repeat that")
    assert rec.lines[n:] == ["Who did they say they were?", REPEAT_PROMPT]
    n = len(rec.lines)
    await s.on_dtmf("5")  # other keys do nothing and are never stored
    assert rec.lines[n:] == []
    assert len(agent.interview_calls) == 1  # repeats never reach the agent


async def test_digits_are_redacted_before_leaving_the_process():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"next_question": "Did you share anything?", "done": False}])
    s = session(stdb, agent, rec)
    buf = io.StringIO()
    handler = logging.StreamHandler(buf)
    logging.getLogger("kavach.voice").addHandler(handler)
    try:
        await s.start()
        await s.on_utterance("They said they were my bank and I read them the code 482913, card 4111 1111 1111 1111")
    finally:
        logging.getLogger("kavach.voice").removeHandler(handler)
    sent = agent.interview_calls[0]["utterance"] + agent.router_calls[0]["text"]
    summary = stdb.reducer_calls("save_answer")[0]
    assert summary["question_id"] == "q_summary"
    for blob in (sent, summary["answer"], buf.getvalue()):
        assert "482913" not in blob and "4111" not in blob
    assert "bank" not in buf.getvalue()  # logs carry no contents at all
    assert '"event": "turn"' in buf.getvalue() and "first_audio_ms" in buf.getvalue()


async def test_medium_ends_with_family_offer_and_yes_tells_family():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"say": "Thank you.", "done": True, "set_severity": ("medium", [])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("A man said I won a prize and asked for my bank details but I hung up")
    assert "This is very likely a scam." in rec.text()
    assert "I've marked the risk as medium." in rec.text()
    assert rec.lines[-2:] == ["Would you like me to tell your family? Say yes or no.", REPEAT_PROMPT]
    assert "I've told your family." not in rec.text()
    await s.on_utterance("yes please")
    assert stdb.reducer_calls("tell_my_family") == [{"incident_id": 1}]
    assert "Okay. I've told your family." in rec.lines
    assert rec.lines[-1] == GOODBYE[0] and rec.hung_up


async def test_medium_no_does_not_tell_family():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"done": True, "set_severity": ("medium", [])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("Someone asked for gift cards and I said no and hung up")
    await s.on_utterance("no thanks")
    assert not stdb.reducer_calls("tell_my_family")
    assert "Okay. I won't tell them." in rec.lines


async def test_high_with_alert_sent_says_family_told():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    stdb.steps = [{"step_key": "credit_freeze", "priority": "today", "done": False, "sort_order": 0}]
    stdb.alerts = [{"kind": "family_alert", "related_incident_id": 1}]
    agent = FakeAgent([{"done": True, "set_severity": ("high", ["personal_details"])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("I gave them my date of birth")
    assert "This looks like a scam." in rec.text()
    assert hotline.STEP_TEXT["credit_freeze"] in rec.lines
    assert "I've told your family." in rec.lines
    assert "Would you like me to tell your family?" not in rec.text()


async def test_high_without_alert_does_not_claim_family_told():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"done": True, "set_severity": ("high", ["link"])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("I tapped a link in a text")
    assert "I've told your family." not in rec.text()
    assert "Please tell someone you trust what happened today." in rec.lines


async def test_critical_offers_to_stay_on_the_line():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    stdb.alerts = [{"kind": "family_alert"}]
    agent = FakeAgent([{"done": True, "set_severity": ("critical", ["gift_card"])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("I bought gift cards and read them the numbers")
    assert "This is a scam, and it's urgent." in rec.lines
    assert any("stay on the line" in ln for ln in rec.lines)
    await s.on_utterance("yes")
    assert "Okay. I'll stay right here." in rec.lines
    n = len(rec.lines)
    await s.on_utterance("thank you for calling Chase bank how can I help")  # bank call on speaker: stay quiet
    assert rec.lines[n:] == []
    await s.on_utterance("okay I'm back")
    assert "I've told your family." in rec.lines and rec.hung_up


async def test_timeout_gives_spoken_fallback():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"next_question": "too late", "done": False}], delay=1.0)
    s = session(stdb, agent, rec, agent_timeout_s=0.3, filler_after_s=0.1)
    await s.start()
    await s.on_utterance("someone called about my account")
    assert FILLER in rec.lines  # something is said within the latency target
    assert rec.lines[-len(FALLBACK) - 1:-1] == FALLBACK
    assert "too late" not in rec.text()
    assert s.phase.value == "describe"  # the next utterance retries the agent


async def test_agent_error_gives_spoken_fallback():
    class Broken(FakeAgent):
        async def interview(self, **kw):
            raise RuntimeError("boom")

    rec, stdb = Recorder(), FakeStdb(PERSONS)
    s = session(stdb, Broken(), rec)
    await s.start()
    await s.on_utterance("someone called")
    assert FALLBACK[0] in rec.lines


async def test_out_of_scope():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    s = session(stdb, FakeAgent([{"next_question": "x", "done": False}], intent="out_of_scope"), rec)
    await s.start()
    await s.on_utterance("what's the weather tomorrow")
    assert "I can only help with scams and staying safe." in rec.lines


async def test_hangup_adds_evidence_when_module_did_not():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"next_question": "Did you share anything?", "done": False}])
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("They said they were Medicare and asked for my number")
    stdb.incidents[1]["answers_json"] = '{"q_ask": "yes"}'
    await s.on_hangup()
    [ev] = stdb.reducer_calls("add_report_evidence")
    assert ev["source"] == "hotline" and ev["verdict"] == "suspicious" and ev["sender_e164"] == JOE
    await s.on_hangup()  # idempotent
    assert len(stdb.reducer_calls("add_report_evidence")) == 1


async def test_no_evidence_when_already_present():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"done": True, "set_severity": ("medium", [])}], stdb=stdb)
    stdb.evidence = [{"sender_e164": JOE, "created_at": [hotline.now_micros()], "text_redacted": "x"}]
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("they asked for money, I said no")
    await s.on_utterance("no")
    assert not stdb.reducer_calls("add_report_evidence")


async def test_utterances_after_goodbye_are_ignored():
    rec, stdb = Recorder(), FakeStdb(PERSONS)
    agent = FakeAgent([{"done": True, "set_severity": ("low", [])}], stdb=stdb)
    s = session(stdb, agent, rec)
    await s.start()
    await s.on_utterance("I just hung up on them")
    assert rec.hung_up
    n = len(rec.lines)
    await s.on_utterance("hello?")
    assert rec.lines[n:] == []
