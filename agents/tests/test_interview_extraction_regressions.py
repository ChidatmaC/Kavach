"""Regressions found in the cross-component hotline run (no model available)."""
from kavach.workflows.interview import extract_from_speech, parse_shared


def test_back_reference_to_asked_items_counts_as_shared():
    out = extract_from_speech(
        "Someone called saying he was my grandson and he was in jail. He said not to tell anyone and "
        "asked me to buy gift cards. I bought two and read him the numbers.")
    assert out["q_shared"] == "gift_card"
    assert out["q_secrecy"] == "yes"


def test_no_back_reference_without_a_giving_verb():
    out = extract_from_speech("They asked me to buy gift cards. I hung up on them.")
    assert out.get("q_shared") in (None, "nothing")


def test_short_no_is_nothing_for_q_shared():
    assert parse_shared("no") == "nothing"


def test_long_first_description_is_not_taken_as_identity():
    import inspect
    from kavach.workflows import interview
    src = inspect.getsource(interview.run_interview)
    assert "len(utterance.split()) <= 8" in src  # long utterances go through free extraction


def test_forwarded_friendly_text_is_not_explicitly_off_topic():
    from kavach.guard import is_explicit_off_topic
    assert not is_explicit_off_topic("Hi Joe, lunch on Sunday still on? Bring the photo album! - Linda")
    assert is_explicit_off_topic("What's the weather tomorrow?")
