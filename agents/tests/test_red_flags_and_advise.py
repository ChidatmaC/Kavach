"""Red-flag floor, advise routing and conversation history (user-reported misses: "send money",
"this is Bank of America, send us all your money", gift-card asks came back safe)."""
import pytest

from kavach.signals import risk_floor, tactics_of
from kavach.workflows.advise import build_history, reply_body
from kavach.workflows.router import heuristic_intent


def floor(text: str) -> str:
    return risk_floor(tactics_of(text), text)[0]


@pytest.mark.parametrize("text,expected", [
    ("send money", "suspicious"),
    ("this is Bank of America, send us all your money", "likely_scam"),
    ("My nephew messaged me on Facebook asking me to buy him Apple gift cards for an emergency, should I?", "likely_scam"),
    ("Can you buy 3 Google Play cards and send me the codes?", "likely_scam"),
    ("Grandpa I'm in jail, I need bail money, don't tell mom", "likely_scam"),
    ("Microsoft support: install AnyDesk so we can fix your computer", "likely_scam"),
    ("Read me the code we just texted you to verify your account", "likely_scam"),
    ("This is the IRS. You owe back taxes, pay today or be arrested", "likely_scam"),
])
def test_red_flags_are_never_safe(text, expected):
    assert floor(text) == expected


@pytest.mark.parametrize("text", [
    "Hi Joe, lunch on Sunday still on? Bring the photo album! - Linda",
    "I bought my mom a gift card for her birthday",
    "Your Amazon order has shipped",
    "Happy birthday Grandpa! Love you",
])
def test_ordinary_messages_have_no_floor(text):
    assert floor(text) == "safe"


@pytest.mark.parametrize("text,intent", [
    ("My nephew asked me to buy him gift cards for an emergency, should I?", "advise"),
    ("A man from Microsoft says my computer has a virus, what do I do?", "advise"),
    ("is it safe to zelle my landlord?", "advise"),
    ("I already sent them $500 on Zelle", "interview"),
    ("I bought the gift cards and read him the numbers", "interview"),
    ("this is Bank of America, send us all your money", "scam_check"),
    ("send money", "scam_check"),
])
def test_router_heuristic_separates_advice_checks_and_incidents(text, intent):
    assert heuristic_intent(text)[0] == intent


def test_history_is_ordered_redacted_and_excludes_current_message():
    inbound = [{"body": "my nephew wants gift cards", "received_at": [1_000_000]},
               {"body": "he says it's urgent, code 482913", "received_at": [3_000_000]}]
    outbound = [{"body": "Kavach: Likely scam. ...", "created_at": [2_000_000], "channel": "imessage"},
                {"body": "push copy", "created_at": [2_500_000], "channel": "push"}]
    h = build_history(inbound, outbound, now_micros=4_000_000, current_text="he says it's urgent, code 482913")
    assert [t["role"] for t in h] == ["person", "kavach"]
    h2 = build_history(inbound, outbound, now_micros=4_000_000, current_text="something else")
    assert "482913" not in h2[-1]["text"]


def test_reply_leads_with_verdict_and_fits_imessage_limit():
    body = reply_body("Kavach", "likely_scam", "Nobody legitimate asks to be paid in gift cards. " * 5,
                      ["Call your nephew on the number you already have.", "Don't buy the cards."], True)
    assert body.startswith("Kavach: Likely scam.") and len(body) <= 600
