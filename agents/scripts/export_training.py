"""Export the training log as a NeMo Customizer chat-format dataset.

    cd agents && uv run python scripts/export_training.py [--dir data/training] [--out data/training/export]
                                                         [--val-fraction 0.1] [--seed kavach]

Reads decisions.jsonl + labels.jsonl (kavach/training.py), keeps decisions that have a label naming the
true verdict (latest label wins), and writes train.jsonl / val.jsonl with one example per line:

    {"messages": [{"role": "system", "content": <workflow prompt>},
                  {"role": "user", "content": <the JSON facts the model sees at inference>},
                  {"role": "assistant", "content": <the JSON verdict it should have returned>}]}

Inputs are already redacted in the log (codes, card and account numbers masked) and evidence is a summary
without anyone's report text. Duplicates (same workflow + same user content) keep the latest label.
The split is deterministic (hash of the example), about 90/10.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

LABEL_REASON = {
    "likely_scam": "This looks like a scam. It uses tricks scammers use, so don't reply, tap links or send anything.",
    "suspicious": "This could be a scam. Check with the person or company on a number you already know before doing anything.",
    "safe": "This looks safe. There are no requests for money, codes, links or personal details.",
}
LABEL_TIPS = {
    "likely_scam": ["Don't reply or tap any links.", "Never send money, gift cards or codes."],
    "suspicious": ["Check with them on a number you already know."],
    "safe": ["If anything changes, like a request for money, check again."],
}
MIN_INTERVIEW_WORDS = 4


def user_facts(d: dict) -> dict:
    """The model input at inference time, rebuilt from the log (no excerpts were ever stored)."""
    sig = d.get("signals") or {}
    floors = d.get("floors") or {}
    community_floor = floors.get("community") or "safe"
    if d.get("workflow") == "advise":
        return {"question_redacted": d.get("input_redacted", ""), "conversation_so_far": [],
                "detected_tactics": d.get("tactics", []), "red_flag_floor": floors.get("risk") or "safe",
                "community_evidence": d.get("evidence", []), "community_floor": community_floor,
                "minimum_verdict": _max(community_floor, floors.get("risk") or "safe")}
    return {"message_redacted": d.get("input_redacted", ""), "sender_e164": sig.get("sender_e164", ""),
            "claimed_identity": sig.get("claimed_identity", ""), "detected_tactics": d.get("tactics", []),
            "links": [{"domain": x} for x in sig.get("link_domains", [])],
            "community_evidence": d.get("evidence", []), "community_floor": community_floor}


def _max(a: str, b: str) -> str:
    rank = {"safe": 0, "suspicious": 1, "likely_scam": 2}
    return a if rank.get(a, 0) >= rank.get(b, 0) else b


def assistant_answer(d: dict, label: str) -> dict:
    agrees = d.get("final_verdict") == label and d.get("reason")
    reason = d["reason"] if agrees else LABEL_REASON[label]
    if d.get("workflow") == "advise":
        return {"verdict": label, "answer": reason[:360], "next_steps": LABEL_TIPS[label],
                "already_shared": bool(d.get("already_shared")), "tactics": d.get("tactics", [])[:8]}
    return {"verdict": label, "reason": reason[:300], "tactics": d.get("tactics", [])[:8], "tips": LABEL_TIPS[label]}


def build_examples(decisions: list[dict], labels: list[dict]) -> list[dict]:
    from kavach.llm import prompt

    latest: dict[str, dict] = {}
    for lb in labels:
        if lb.get("decision_id") and lb.get("label") in LABEL_REASON:
            latest[lb["decision_id"]] = lb
    by_key: dict[str, tuple[float, dict]] = {}
    systems = {"scam_check": prompt("scam_check"), "advise": prompt("advise"), "interview": prompt("scam_check")}
    for d in decisions:
        lb = latest.get(d.get("id", ""))
        wf = d.get("workflow")
        if not lb or wf not in systems or not d.get("input_redacted"):
            continue
        if wf == "interview" and len(d["input_redacted"].split()) < MIN_INTERVIEW_WORDS:
            continue
        user = json.dumps(user_facts(d), ensure_ascii=False, sort_keys=True)
        key = hashlib.sha256(f"{'advise' if wf == 'advise' else 'check'}|{' '.join(user.lower().split())}".encode()).hexdigest()
        ex = {"messages": [{"role": "system", "content": systems[wf]}, {"role": "user", "content": user},
                           {"role": "assistant", "content": json.dumps(assistant_answer(d, lb["label"]), ensure_ascii=False)}]}
        ts = float(lb.get("ts") or 0)
        if key not in by_key or ts >= by_key[key][0]:
            by_key[key] = (ts, {"key": key, "example": ex})
    return [v for _, v in sorted(by_key.values(), key=lambda x: x[1]["key"])]


def split(examples: list[dict], val_fraction: float, seed: str) -> tuple[list[dict], list[dict]]:
    train, val = [], []
    for e in examples:
        h = int(hashlib.sha256(f"{seed}|{e['key']}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
        (val if h < val_fraction else train).append(e["example"])
    if not val and len(train) >= 2 and val_fraction > 0:
        val.append(train.pop())  # always leave something to validate on
    return train, val


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dir", help="training log directory (default: KAVACH_TRAINING_DIR or agents/data/training)")
    ap.add_argument("--out", help="output directory (default: <dir>/export)")
    ap.add_argument("--val-fraction", type=float, default=0.1)
    ap.add_argument("--seed", default="kavach")
    a = ap.parse_args(argv)
    if a.dir:
        os.environ["KAVACH_TRAINING_DIR"] = a.dir
    from kavach import training

    out = Path(a.out) if a.out else training.training_dir() / "export"
    examples = build_examples(training.load_decisions(), training.load_labels())
    train, val = split(examples, a.val_fraction, a.seed)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in (("train.jsonl", train), ("val.jsonl", val)):
        with (out / name).open("w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(json.dumps({"examples": len(examples), "train": len(train), "val": len(val), "out": str(out)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
