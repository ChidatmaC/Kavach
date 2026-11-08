import asyncio

import pytest

from kavach.workflows.interview import extract_from_speech, parse_ask, parse_shared, parse_yes_no
from kavach.workflows.router import answer_like, heuristic_intent, parse_command


@pytest.mark.parametrize("text,intent,args", [
    ("verify Tommy", "verify_relative", {"relative_name": "Tommy"}),
    ("Verify my grandson", "verify_relative", {"relative_name": "Grandson"}),
    ("PAUSE", "pause", {}), ("resume", "resume", {}), ("Stop", "stop", {}), ("help", "help", {}),
    ("stop.", "stop", {}),
])
def test_commands(text, intent, args):
    assert parse_command(text) == (intent, args)


def test_non_commands():
    assert parse_command("Please stop calling me, you scammer") is None
    assert parse_command("TxTag: unpaid toll") is None


def test_heuristic_intents():
    assert heuristic_intent("I just got a call from someone saying they were my bank and I gave them my card number")[0] == "interview"
    assert heuristic_intent("Is this really Tommy texting me?") == ("verify_relative", {"relative_name": "Tommy"})
    assert heuristic_intent("You have won a prize! Claim at prize-now.xyz")[0] == "scam_check"


def test_answer_parsers():
    assert parse_yes_no("Yes they did") == "yes" and parse_yes_no("nope") == "no" and parse_yes_no("maybe?") is None
    assert parse_ask("I agreed to call them back") == "agreed"
    assert parse_shared("nothing") == "nothing"
    assert parse_shared("my card number and a code") == "code,card"
    assert parse_shared("gift card numbers") == "gift_card"
    assert parse_shared("I tapped the link and gave my address") == "personal_details,link"
    assert answer_like("yes", "q_secrecy") and not answer_like("TxTag: unpaid toll, pay at https://x.top/a", "q_shared")


def test_speech_extraction_ignores_refused_items():
    s = ("Someone called saying he was my grandson, he was in jail and asked for gift cards and said don't tell mom. "
         "I bought gift cards and read him the numbers but I didn't give my bank details.")
    out = extract_from_speech(s)
    assert out["q_ask"] == "yes"
    assert out["q_shared"] == "gift_card"
    assert out["q_secrecy"] == "yes"
    assert "grandson" in out["q_identity"].lower()
    assert extract_from_speech("They wanted my code but I hung up.")["q_shared"] == "nothing"


def test_router_off_topic_and_commands_without_db():
    from kavach.workflows.base import make_run
    from kavach.workflows.router import run_router

    class NoDb:
        db = "none"

    r = make_run("router", NoDb())
    out = asyncio.run(run_router(r, {"text": "What's the weather forecast for tomorrow?", "person_id": 0}))
    assert out["intent"] == "out_of_scope" and "scams" in out["args"]["reply"]
    out = asyncio.run(run_router(r, {"text": "verify Tommy", "person_id": 1}))
    assert out == {"intent": "verify_relative", "args": {"person_id": 1, "relative_name": "Tommy"}}
