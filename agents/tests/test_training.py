"""Training log: redaction, evidence summaries, labels (feedback and automatic outcomes), few-shot
retrieval into the scam_check prompt, and the NeMo Customizer export."""
import asyncio
import json
import sys
from pathlib import Path

from conftest import FakeStdb
from kavach import training
from kavach.workflows.base import make_run
from kavach.workflows.scam_check import run_scam_check

AGENTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(AGENTS / "scripts"))
import export_training  # noqa: E402

SECRET_TEXT = ("Your bank: we blocked card 4111 1111 1111 1111. Reply with code 482913 and your account 123456789 "
               "to unlock. Call +15555550188")


def _raw_files() -> str:
    d = training.training_dir()
    return "".join(p.read_text() for p in d.glob("*.jsonl"))


def _decision(text, verdict="likely_scam", wf="scam_check", person=1, **kw):
    return training.log_decision(workflow=wf, person_id=person, text=text, tactics=kw.pop("tactics", ["urgency"]),
                                 evidence=kw.pop("evidence", []), model_verdict=kw.pop("model_verdict", verdict),
                                 final_verdict=verdict, floors=kw.pop("floors", {}), **kw)


def test_decision_is_redacted_and_evidence_has_no_report_text():
    from kavach.community import Evidence

    ev = [Evidence(kind="similar_report", score=0.71234, reporter_count=4, campaign_id=2, campaign_title="Toll scam",
                   tactics=["urgency"], verdict="likely_scam", excerpt="Somebody else's reported message text")]
    did = _decision(SECRET_TEXT, evidence=ev, reason="code 482913 was asked", check_request_key="k1")
    raw = _raw_files()
    for secret in ("4111", "482913", "123456789", "Somebody else's"):
        assert secret not in raw, secret
    d = training.decision_by_id(did)
    assert "[card number]" in d["input_redacted"] and "[code]" in d["input_redacted"]
    assert d["evidence"] == [{"kind": "similar_report", "score": 0.712, "reporter_count": 4, "campaign_id": 2,
                              "campaign_title": "Toll scam", "tactics": ["urgency"], "verdict": "likely_scam"}]
    assert "+15555550188" in d["input_redacted"]  # the scammer's number stays (it is what gets reported)
    assert training.decision_for_check("k1")["id"] == did


def test_labels_from_feedback_words():
    did = _decision("Pay the toll now at txtag-pay.top", verdict="likely_scam")
    d = training.decision_by_id(did)
    assert training.add_label(decision=d, person_id=1, source="imessage", correct=False)["label"] == "safe"
    assert training.add_label(decision=d, person_id=1, source="imessage", correct=True)["label"] == "likely_scam"
    lb = training.add_label(decision=d, person_id=1, source="app", correct=False, label="suspicious",
                            note="my PIN is 4321, it was the real toll company")
    assert lb["label"] == "suspicious" and lb["correct"] is False and "4321" not in lb["note"]
    safe = training.decision_by_id(_decision("Lunch at noon?", verdict="safe"))
    assert training.add_label(decision=safe, person_id=1, source="imessage", correct=False)["label"] == "suspicious"
    assert training.latest_labels()[did]["label"] == "suspicious"  # latest wins


def test_latest_decision_is_per_person_and_recent():
    _decision("a scam text for person two", person=2)
    mine = _decision("a scam text for person one", person=1)
    assert training.latest_decision(1)["id"] == mine
    assert training.latest_decision(3) is None


def test_automatic_labels_are_idempotent():
    d1 = _decision("caller said he was my grandson in jail", wf="interview", incident_id=77)
    assert training.label_incident(77, "high", 1) == 1
    assert training.label_incident(77, "critical", 1) == 0  # same decision, same key
    assert training.label_incident(77, "medium", 1) == 0
    assert training.latest_labels()[d1]["source"] == "incident_severity"

    import time

    chk = _decision("Hi Grandpa it's me, new number, send $500", verdict="suspicious")
    assert training.label_verification_denied(5, 1, time.time()) == 1
    assert training.label_verification_denied(5, 1, time.time()) == 0
    assert training.latest_labels()[chk]["label"] == "likely_scam"


def test_few_shot_top3_by_similarity_only_confirmed():
    texts = {
        "toll": "TxTag: your toll balance is past due, pay now at txtag-pay.top or face fees",
        "toll2": "Unpaid toll notice: pay your overdue toll today to avoid penalties",
        "toll3": "NTTA toll reminder: overdue balance, settle now to avoid a fine",
        "toll4": "Toll account past due. Pay the toll balance now",
        "lunch": "Want to grab lunch on Friday at the diner?",
        "unlabeled": "Toll payment overdue, pay now",
    }
    ids = {k: _decision(v, verdict="likely_scam") for k, v in texts.items()}
    for k in ("toll", "toll2", "toll3", "toll4", "lunch"):
        training.add_label(decision=training.decision_by_id(ids[k]), person_id=1, source="app", correct=True)
    shots = training.few_shot("Your toll is overdue. Pay the balance now to avoid fees.")
    assert len(shots) == 3
    assert all("toll" in s["message_redacted"].lower() for s in shots)
    assert all(s["correct_verdict"] == "likely_scam" for s in shots)
    assert shots[0]["similarity"] >= shots[-1]["similarity"]
    assert texts["unlabeled"] not in [s["message_redacted"] for s in shots]
    assert training.few_shot("completely unrelated words about gardening tomatoes") == []


class CheckDb(FakeStdb):
    def __init__(self):
        super().__init__()
        self.checks = []

    async def person(self, pid):
        return {"id": pid, "phone_e164": "+15555550101", "display_name": "Joe", "recovery_watch_until": 0,
                "campaign_watch_until": 0}

    async def call(self, name, args, token=None):
        if name == "save_message_check":
            self.checks.append({"id": len(self.checks) + 1, "request_key": args["request_key"],
                                "verdict": args["model_verdict"], "campaign_id": args["campaign_id"]})

    async def sql(self, query, token=None):
        if "svc_message_check" in query:
            return [c for c in self.checks if c["request_key"] in query]
        return await super().sql(query, token)


def test_scam_check_logs_decision_and_uses_few_shot(monkeypatch):
    # A confirmed example: people said this kind of message was safe.
    ex = _decision("Your Costco order 5521 is ready for pickup at the Plano warehouse today", verdict="likely_scam")
    training.add_label(decision=training.decision_by_id(ex), person_id=1, source="app", correct=False, label="safe")

    seen = {}

    async def fake_json(self, tier, system, user, schema, **kw):
        seen.setdefault(schema, json.loads(user))
        if schema == "scam_check.model":
            return {"verdict": "safe", "reason": "This is a normal pickup notice.", "tactics": [], "tips": []}
        return None

    monkeypatch.setattr("kavach.llm.LLM.json", fake_json)
    monkeypatch.setattr("kavach.llm.ModelSet.enabled", property(lambda self: True))
    db = CheckDb()
    run = make_run("scam_check", db)
    out = asyncio.run(run_scam_check(run, {"person_id": 1, "text": "Your Costco order is ready for pickup at the Plano warehouse",
                                           "source": "app_paste"}, queue_reply=False))
    shots = seen["scam_check.model"]["labeled_examples"]
    assert shots and shots[0]["correct_verdict"] == "safe" and "similarity" not in shots[0]
    assert out["verdict"] == "safe" and out["check_id"] == 1
    d = training.latest_decision(1)
    assert d["workflow"] == "scam_check" and d["check_request_key"] == db.checks[0]["request_key"]
    assert d["final_verdict"] == "safe" and "fewshot1" in d["method"] and set(d["floors"]) >= {"community", "risk", "stored"}


def test_export_dedupes_and_splits(tmp_path):
    for i in range(30):
        did = _decision(f"Toll notice number {i}: pay the overdue balance now", verdict="likely_scam")
        training.add_label(decision=training.decision_by_id(did), person_id=1, source="app", correct=True)
    dup = _decision("Toll notice number 0: pay the overdue balance now", verdict="likely_scam")
    training.add_label(decision=training.decision_by_id(dup), person_id=1, source="app", correct=False, label="suspicious")
    adv = _decision("my nephew wants gift cards, should I?", wf="advise", reason="Gift cards are a scam sign.")
    training.add_label(decision=training.decision_by_id(adv), person_id=1, source="imessage", correct=True)
    _decision("unlabeled message", verdict="safe")
    short = _decision("no", wf="interview", incident_id=3)
    training.label_incident(3, "high", 1)
    assert short

    out = tmp_path / "export"
    assert export_training.main(["--dir", str(training.training_dir()), "--out", str(out)]) == 0
    train = [json.loads(x) for x in (out / "train.jsonl").read_text().splitlines()]
    val = [json.loads(x) for x in (out / "val.jsonl").read_text().splitlines()]
    assert len(train) + len(val) == 31 and 1 <= len(val) <= 8
    rows = train + val
    for r in rows:
        assert [m["role"] for m in r["messages"]] == ["system", "user", "assistant"]
        json.loads(r["messages"][1]["content"])
        ans = json.loads(r["messages"][2]["content"])
        assert ans["verdict"] in ("safe", "suspicious", "likely_scam")
    zero = [r for r in rows if "number 0:" in r["messages"][1]["content"]]
    assert len(zero) == 1 and json.loads(zero[0]["messages"][2]["content"])["verdict"] == "suspicious"
    advise = [r for r in rows if "question_redacted" in r["messages"][1]["content"]]
    assert len(advise) == 1 and "answer" in json.loads(advise[0]["messages"][2]["content"])
    # deterministic split
    assert export_training.main(["--dir", str(training.training_dir()), "--out", str(out)]) == 0
    assert [json.loads(x) for x in (out / "val.jsonl").read_text().splitlines()] == val
