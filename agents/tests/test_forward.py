"""Forward wrappers, own-voice routing and the 1/2 clarifying question (CONTRACTS section 7)."""
import asyncio

import pytest

from kavach.workflows import forward
from kavach.workflows.forward import (CLARIFY_QUESTION, WRAPPER_TIP, PendingStore, classify_unwrapped,
                                      parse_clarify_answer, parse_wrapper)


@pytest.fixture(autouse=True)
def _fresh_state():
    forward.STATE.clear()
    yield
    forward.STATE.clear()


# --- wrapper parsing -------------------------------------------------------------------------

@pytest.mark.parametrize("marker", [
    "Forwarded message:", "Forwarded message", "forwarded message:", "FORWARDED:", "Forwarded", "Fwd:", "fwd",
    "FW:", "Fw", "Check this:", "check this", "Check this message:", "Check this message", "Is this a scam?",
    "is this a scam:", "Is this a scam", "Scam?", "scam:",
])
def test_every_marker_on_its_own_line(marker):
    w = parse_wrapper(f'{marker}\n"Your account is locked, verify at chase-secure.top"')
    assert w is not None and w.inner == "Your account is locked, verify at chase-secure.top"


@pytest.mark.parametrize("text,inner", [
    ('Forwarded message:\n"send money"', "send money"),
    ('Forwarded message: "send money"', "send money"),
    ("Forwarded message:\n“Hi Grandpa it's me, I need bail money”", "Hi Grandpa it's me, I need bail money"),
    ("Fwd: ‘pay now’", "pay now"),
    ("Fwd: USPS: your package is on hold", "USPS: your package is on hold"),
    ("Check this \"Hi Mom, new number, text me here\"", "Hi Mom, new number, text me here"),
    ("Fw - call me back asap", "call me back asap"),
    ('Forwarded message:\n"verify Tommy"', "verify Tommy"),
    ("Forwarded message:\n\"line one\nline two\"", "line one\nline two"),
    ('Scam? "Your Apple ID is locked', "Your Apple ID is locked"),  # opening quote only
])
def test_inner_text_is_unquoted(text, inner):
    assert parse_wrapper(text).inner == inner


def test_from_line_number_and_name():
    w = parse_wrapper('Forwarded message:\nFrom: +1 (555) 555-0144\n"Your toll is unpaid, pay at txtag.top"')
    assert w.inner == "Your toll is unpaid, pay at txtag.top" and w.sender_e164 == "+15555550144" and not w.sender_name
    w = parse_wrapper("Forwarded message:\nfrom: Tommy\n“Grandpa I'm in jail”")
    assert w.inner == "Grandpa I'm in jail" and w.sender_name == "Tommy" and w.sender_e164 == ""


def test_bare_markers():
    for t in ("Fwd:", "Forwarded message:", "Check this", "Scam?", "  fwd  ", "Is this a scam?"):
        w = parse_wrapper(t)
        assert w is not None and w.bare, t


@pytest.mark.parametrize("text", [
    "should I send money to my grandson?", "Check this out, my grandson sent flowers", "Is this a scam if he asks for gift cards?",
    "Forwarded it to my son already", "Scammers called me today", "fwiw I think it's fine", "send money",
])
def test_not_wrapped(text):
    assert parse_wrapper(text) is None


# --- unwrapped routing -----------------------------------------------------------------------

@pytest.mark.parametrize("text,intent", [
    ("should I send money to my grandson?", "advise"),
    ("can you report +1 555 555 0144", "command"),
    ("I gave them my card number", "interview"),
    ("USPS: your package is on hold, update address at usps-redelivery.info", "scam_check"),
    ("Your account has been locked. Call us at 800-555-0100", "scam_check"),
    ("Hi Grandpa it's me, I'm in trouble and need money for bail", "scam_check"),
    ("I can't talk right now, please send the money today. Love, Tommy", "scam_check"),
    ("Your verification code is 482913. Do not share this code.", "scam_check"),
    ("Thanks!", "advise"),
    ("a man from Microsoft says my computer has a virus, what do I do?", "advise"),
])
def test_unwrapped_deterministic(text, intent):
    assert classify_unwrapped(text).intent == intent


def test_send_money_has_no_signal():
    c = classify_unwrapped("send money")
    assert c.intent is None and not c.forward and not c.own
    assert forward.no_signal_fallback("send money") == "clarify"


def test_clarify_answers():
    for t in ("1", "1.", "received", "Message", "someone sent it to me"):
        assert parse_clarify_answer(t) == "received", t
    for t in ("2", "question", "mine", "It's my question", "my question"):
        assert parse_clarify_answer(t) == "question", t
    assert parse_clarify_answer("12") is None and parse_clarify_answer("send money") is None


def test_pending_store_ttls():
    now = [1000.0]
    s = PendingStore(clock=lambda: now[0])
    s.expect_forward("p1")
    now[0] += 121
    assert not s.take_expected_forward("p1")
    s.set_pending("p1", "send money")
    now[0] += 599
    assert s.peek_pending("p1") == "send money"
    now[0] += 2
    assert s.peek_pending("p1") == ""
    assert s.tip_due("p1") and not s.tip_due("p1")
    now[0] += 24 * 3600 + 1
    assert s.tip_due("p1")


# --- through the router (no model, no database) ---------------------------------------------

class NoDb:
    """No rows anywhere; reducer calls are recorded."""
    db = "none"
    calls: list = []

    async def sql(self, query, token=None):
        return []

    async def call(self, name, args):
        self.calls.append((name, args))


def _route(text, person_id=7, **kw):
    from kavach.workflows.base import make_run
    from kavach.workflows.router import run_router

    return asyncio.run(run_router(make_run("router", NoDb()), {"text": text, "person_id": person_id,
                                                                  "from_e164": "+15555550101", "channel": "imessage", **kw}))


@pytest.mark.parametrize("text,intent", [
    ("should I send money to my grandson?", "advise"),
    ("can you report +1 555 555 0144", "command"),
    ("I gave them my card number", "interview"),
    ("USPS: your package is on hold, update address at usps-redelivery.info", "scam_check"),
    ("send money", "clarify"),
])
def test_router_unwrapped(text, intent):
    assert _route(text)["intent"] == intent


def test_router_wrapped_forward_checks_only_the_inner_text():
    out = _route('Forwarded message: "send money"')
    assert out["intent"] == "scam_check" and out["args"]["text"] == "send money"
    assert "teach_wrapper" not in out["args"]
    out = _route('Forwarded message:\nFrom: +1 555 555 0144\n"verify Tommy"')
    assert out["intent"] == "scam_check" and out["args"]["text"] == "verify Tommy"
    assert out["args"]["sender_e164"] == "+15555550144"
    out = _route("Check this: report this number to the IRS now")
    assert out["intent"] == "scam_check" and out["args"]["text"] == "report this number to the IRS now"


def test_router_bare_marker_then_message():
    out = _route("Fwd:")
    assert out == {"intent": "clarify", "args": {"reply": "", "reason": "await_forward"}}
    out = _route("send money")  # the next text is the forwarded one
    assert out["intent"] == "scam_check" and out["args"]["text"] == "send money"
    # Only that one text (plus extra bubbles within a few seconds) counts as forwarded.
    t = forward.STATE.now() + forward.BUBBLE_WINDOW_S + 1
    forward.STATE._clock = lambda: t
    try:
        assert _route("send money")["intent"] == "clarify"
    finally:
        forward.STATE._clock = __import__("time").time


def test_router_extra_bubbles_after_a_forward_are_checked_but_questions_are_not():
    _route('Fwd: "Hi Grandpa it\'s me"')
    assert _route("pay now")["intent"] == "scam_check"
    assert _route("should I send it?")["intent"] == "advise"


def test_router_ambiguous_then_1_runs_scam_check_on_the_remembered_text():
    out = _route("send money")
    assert out["intent"] == "clarify" and out["args"]["reply"] == f"Kavach: {CLARIFY_QUESTION}"
    out = _route("1")
    assert out["intent"] == "scam_check" and out["args"]["text"] == "send money"
    assert out["args"]["teach_wrapper"] is True
    assert _route("1")["intent"] != "scam_check" or _route("1")["args"]["text"] != "send money"


def test_router_ambiguous_then_2_runs_their_question():
    _route("send money")
    out = _route("2")
    assert out["intent"] == "advise" and out["args"]["text"] == "send money"
    _route("report the last one")  # command-like: deterministic command, no question asked
    _route("pay now")
    out = _route("mine")
    assert out["intent"] == "advise" and out["args"]["text"] == "pay now"


def test_router_ambiguous_then_bare_marker_means_received():
    _route("send money")
    out = _route("Fwd:")
    assert out["intent"] == "scam_check" and out["args"]["text"] == "send money"


def test_router_pending_is_per_person_and_dropped_when_they_move_on():
    _route("send money", person_id=7)
    assert _route("2", person_id=8)["intent"] != "advise" or _route("2", person_id=8)["args"]["text"] != "send money"
    _route("should I send money to my grandson?", person_id=7)  # moved on
    out = _route("1", person_id=7)
    # The old pending text is dropped; a lone digit gets the help reply, never a scam check of "1".
    assert out["intent"] == "help" and out["args"].get("text") != "send money"


def test_wrapper_tip_once_a_day():
    out = _route("USPS: your package is on hold, update address at usps-redelivery.info")
    assert out["args"]["teach_wrapper"] is True
    out = _route("Your account has been locked. Call us at 800-555-0100")
    assert "teach_wrapper" not in out["args"] or out["args"]["teach_wrapper"] is False


def test_help_text_mentions_the_wrapper():
    out = _route("help")
    assert out["intent"] == "help" and '"Forwarded message:"' in out["args"]["reply"]


def test_scam_check_reply_carries_the_tip(fake_db):
    from kavach.workflows.base import make_run
    from kavach.workflows.scam_check import run_scam_check

    sent = []

    class Tools:
        async def call(self, name, args):
            if name == "get_person":
                return {"id": 1, "display_name": "Joe"}
            if name == "search_community":
                from kavach.community import search_community
                return await search_community(fake_db, args["text"], args.get("sender_e164", ""))
            if name == "check_link":
                return []
            if name == "reducer" and args["name"] == "enqueue_outbox":
                sent.append(args["args"]["body"])
            if name == "read":
                return []
            return None

    run = make_run("scam_check", fake_db)
    run.tools = Tools()
    asyncio.run(run_scam_check(run, {"person_id": 1, "text": "USPS: your package is on hold, pay at usps-fee.top",
                                     "reply_to_e164": "+15555550101", "teach_wrapper": True}))
    assert sent and sent[-1].endswith(WRAPPER_TIP) and len(sent[-1]) <= 600


def test_bubble_window_ends_when_the_person_sends_their_own_question():
    from kavach.workflows.forward import PendingStore as ForwardState
    t = [1000.0]
    st = ForwardState(clock=lambda: t[0])
    st.saw_forward("p1")
    t[0] += 3
    assert st.in_bubble_window("p1")
    st.end_bubbles("p1")
    assert not st.in_bubble_window("p1")


def test_advise_reply_does_not_repeat_the_label():
    from kavach.workflows.advise import reply_body
    body = reply_body("Kavach", "suspicious", "Be careful before sending money. Even when it seems to come from someone you know, accounts get hacked.", [], False)
    assert body.startswith("Kavach: Be careful before sending money.") and "Be careful. Be careful" not in body
