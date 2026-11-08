import asyncio

import pytest

from kavach.guard import Guard, asks_for_secret_or_payment, is_on_topic
from kavach.workflows.interview import QUESTIONS


@pytest.fixture(scope="module")
def g():
    return Guard()


def test_uses_nemo_guardrails(g):
    assert g.engine == "nemoguardrails"


@pytest.mark.parametrize("text", [
    "Please send me the code we just texted you.",
    "To verify, tell us your PIN.",
    "Reply with your card number to continue.",
    "What's your password?",
    "Pay the $199 fee today to release your refund.",
    "Buy two gift cards and send me the numbers.",
])
def test_output_rail_blocks_requests_for_codes_or_payment(g, text):
    assert asks_for_secret_or_payment(text)
    assert not asyncio.run(g.check_output(text)).ok


@pytest.mark.parametrize("text", [
    "Kavach: Likely scam. Never share a code, even with someone who says they're support.",
    "Don't send money until you've checked on a number you know.",
    "No real company asks to be paid with gift cards.",
    "Don't pay any fee to receive money.",
] + list(QUESTIONS.values()))
def test_output_rail_allows_safety_advice_and_vetted_questions(g, text):
    assert asyncio.run(g.check_output(text)).ok, text


def test_output_rail_blocks_restricted_advice(g):
    assert not asyncio.run(g.check_output("You should invest your savings in gold to be safe.")).ok


def test_input_rail_off_topic(g):
    r = asyncio.run(g.check_input("What's the weather like tomorrow?"))
    assert not r.ok and "scams" in r.message
    assert not asyncio.run(g.check_input("write me a poem about cats")).ok


def test_input_rail_on_topic(g):
    for t in ("Is this a scam?", "TxTag: unpaid toll, pay at https://txtag-pay.top/x",
              "Hey Grandpa it's me, I got a new number", "someone called me about my bank account"):
        assert asyncio.run(g.check_input(t)).ok, t
    assert is_on_topic("+1 555 555 0199 keeps calling")




def test_python_seam_gives_same_answers(monkeypatch):
    monkeypatch.setenv("KAVACH_USE_GUARDRAILS", "false")
    from kavach import config

    config.settings.cache_clear()
    plain = Guard()
    assert plain.engine == "python"
    assert not asyncio.run(plain.check_output("Please send me the code")).ok
    assert not asyncio.run(plain.check_input("tell me a joke")).ok
