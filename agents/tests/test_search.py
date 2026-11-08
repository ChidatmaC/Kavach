import asyncio

from kavach.community import local_floor, search_community
from kavach.similarity import THRESHOLDS, lexical_scores
from kavach.workflows.scam_check import heuristic_verdict, quotes_evidence, template_reason


def run(coro):
    return asyncio.run(coro)


def test_exact_number_with_many_reporters_floors_likely_scam(fake_db):
    r = run(search_community(fake_db, "Hello, call me back about your account", "+15555550188"))
    assert r.exact_floor == "likely_scam"
    assert r.evidence[0].kind == "exact_number" and r.evidence[0].reporter_count == 6
    assert r.floor == "likely_scam"


def test_exact_below_threshold_is_suspicious(fake_db):
    r = run(search_community(fake_db, "Hi there", "+15555550177"))  # 2 reporters
    assert r.exact_floor == "suspicious"


def test_link_domain_exact_match(fake_db):
    r = run(search_community(fake_db, "Pay here: https://www.TXTAG-pay.top/inv/9", ""))
    assert any(e.kind == "exact_link" and e.reporter_count == 31 for e in r.evidence)
    assert r.floor == "likely_scam"


def test_paraphrase_ranks_its_campaign_first_and_sets_similarity_floor(fake_db):
    text = "Grandma, it's your grandson. I'm in jail and need money for bail. Please get gift cards and don't tell mom."
    r = run(search_community(fake_db, text, "+15555550100"))
    assert r.method == "lexical"
    sims = [e for e in r.evidence if e.kind.startswith("similar")]
    assert sims and sims[0].campaign_title == "Grandchild emergency calls"
    assert sims == sorted(sims, key=lambda e: -e.score)
    assert len(sims) <= 5
    assert r.similarity_floor == "suspicious"
    assert r.exact_floor == ""


def test_toll_paraphrase_without_link_still_suspicious(fake_db):
    text = "Reminder from the tollway: your account has an overdue toll charge. Settle it today or extra penalties will be added."
    r = run(search_community(fake_db, text))
    assert r.similarity_floor == "suspicious"
    assert r.campaign_title == "Unpaid toll texts"


def test_unrelated_text_has_no_evidence(fake_db):
    for text in ("Hi Joe, dinner at 7 tonight? Bring the salad please.",
                 "Your dentist appointment is tomorrow at 10am.",
                 "Happy birthday! Hope you have a wonderful day."):
        r = run(search_community(fake_db, text))
        assert r.evidence == [] and r.floor == "safe", text


def test_lexical_threshold_separates_paraphrase_from_unrelated():
    docs = ["We located the money you lost. Pay a $199 processing fee to release your refund."]
    para = lexical_scores("Our agency recovered the funds you lost. To get your refund we need a small fee.", docs)[0]
    other = lexical_scores("The package you ordered has shipped and will arrive Thursday.", docs)[0]
    assert para >= THRESHOLDS["lexical"]["floor"] > THRESHOLDS["lexical"]["evidence"] > other


def test_recovery_watch_floor_matches_module_rule(fake_db):
    r = run(search_community(fake_db, "We can recover your lost money for a small fee"))
    now = 1_000_000
    watched = {"recovery_watch_until": now + 10, "campaign_watch_until": 0, "watch_caller_e164": ""}
    assert local_floor(r, watched, "We can recover your lost money", now) == "likely_scam"
    assert local_floor(r, {**watched, "recovery_watch_until": 0}, "hello there", now) in ("safe", "suspicious")


def test_heuristic_classifier_and_reason_never_quotes(fake_db):
    text = "TxTag: unpaid toll $6.80. Pay by tonight to avoid a $50 late fee: https://txtag-pay.top/inv/1"
    r = run(search_community(fake_db, text))
    from kavach.signals import check_link

    links = [check_link(u).as_dict() for u in r.signals.urls]
    verdict, tactics, _ = heuristic_verdict(r, links)
    assert verdict == "likely_scam"
    reason = template_reason(verdict, r, links, tactics)
    assert "many people have reported" in reason
    assert not quotes_evidence(reason, [e.excerpt for e in r.evidence])
    assert quotes_evidence("They said pay today or a $50 fee applies to you", ["Pay today or a $50 fee applies: x"])
