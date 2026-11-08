"""Stub of the agent service (docs/CONTRACTS.md section 4) for voice tests and rehearsal.

Implements /run/router and /run/interview (mode voice) with keyword extraction instead of
Nemotron, and saves answers on the real SpacetimeDB with the `agents` service token, exactly
as the real interview workflow does. /run/family_alert returns 503 so the module's template
fallback queues the family alerts.

    uv run python tests/stub_agent.py      # listens on STUB_AGENT_PORT (default 8097)
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from config import REPO_ROOT, env  # noqa: E402

QUESTIONS = [
    ("q_identity", "Who did they say they were?"),
    ("q_ask", "Did they ask for money, codes, gift cards or personal details?"),
    ("q_shared", "Did you share or send anything? For example a code, card details, gift cards or money."),
    ("q_secrecy", "Did they ask you to keep it secret or rush you?"),
    ("q_help", "Do you want help right now?"),
]
CRITICAL = {"code", "pin", "password", "card", "gift_card", "money", "remote_app"}
SHARED_PATTERNS = [
    ("gift_card", r"gift ?cards?"), ("code", r"\bcode\b"), ("pin", r"\bpin\b"), ("password", r"password"),
    ("card", r"card (number|details)|credit card|debit card"), ("money", r"wire|sent (them )?money|zelle|venmo|paid"),
    ("remote_app", r"installed|remote|anydesk|teamviewer"), ("personal_details", r"social security|date of birth|address"),
    ("link", r"clicked|tapped|link"),
]

app = FastAPI()
_state: dict[int, dict] = {}
calls: list[dict] = []  # inspected by tests


def agents_token() -> str:
    if env("SPACETIME_TOKEN_AGENTS"):
        return env("SPACETIME_TOKEN_AGENTS")
    return json.loads((REPO_ROOT / ".spacetime-tokens.json").read_text())["agents"]


async def stdb_call(reducer: str, args: dict) -> None:
    base = f"{env('SPACETIME_URI', 'http://127.0.0.1:3000')}/v1/database/{env('SPACETIME_DB_NAME', 'kavach')}"
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(f"{base}/call/{reducer}", json=args, headers={"Authorization": f"Bearer {agents_token()}"})
        if r.status_code >= 300:
            raise RuntimeError(f"{reducer}: {r.status_code} {r.text}")


async def stdb_sql(q: str) -> list[dict]:
    base = f"{env('SPACETIME_URI', 'http://127.0.0.1:3000')}/v1/database/{env('SPACETIME_DB_NAME', 'kavach')}"
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(f"{base}/sql", content=q.encode(), headers={"Authorization": f"Bearer {agents_token()}"})
        res = r.json()[0]
        names = [e["name"]["some"] for e in res["schema"]["elements"]]
        return [dict(zip(names, row)) for row in res["rows"]]


def extract(text: str) -> dict[str, str]:
    t = text.lower()
    out: dict[str, str] = {}
    m = re.search(r"(?:said (?:they were|he was|she was|it was)|claimed to be|calling from|this is) ([a-z' ]{3,40}?)(?:[.,]| and |$)", t)
    if m:
        out["q_identity"] = m.group(1).strip()
    if re.search(r"asked (me )?(for|to)|wanted|demanded|told me to (buy|send|pay)", t):
        out["q_ask"] = "yes"
    items = [k for k, p in SHARED_PATTERNS if re.search(p, t)]
    if re.search(r"\b(bought|sent|gave|read|shared|paid|told them)\b", t) and items:
        out["q_shared"] = ",".join(items)
    elif re.search(r"didn'?t (share|send|give)|nothing|hung up", t):
        out["q_shared"] = "nothing"
    if re.search(r"secret|don'?t tell|hurry|right now|urgent", t):
        out["q_secrecy"] = "yes"
    return out


@app.get("/health")
async def health():
    return {"ok": True}


@app.post("/run/router")
async def router(req: Request):
    body = await req.json()
    calls.append({"workflow": "router", **body})
    text = body.get("text", "").lower()
    if re.search(r"weather|recipe|joke|sports", text):
        return {"intent": "out_of_scope", "args": {}}
    return {"intent": "interview", "args": {}}


@app.post("/run/interview")
async def interview(req: Request):
    body = await req.json()
    calls.append({"workflow": "interview", **body})
    inc_id = int(body["incident_id"])
    st = _state.setdefault(inc_id, {"answers": {}, "asked": None})
    if mode_delay := float(os.environ.get("STUB_INTERVIEW_DELAY_S", "0") or 0):
        import asyncio

        await asyncio.sleep(mode_delay)
    utt = body.get("utterance") or ""
    found = extract(utt)
    asked = st["asked"]
    if asked and asked not in found:
        yn = "yes" if re.search(r"\b(yes|yeah|yep)\b", utt.lower()) else "no" if re.search(r"\b(no|nope)\b", utt.lower()) else None
        if asked == "q_identity" and utt:
            found[asked] = utt[:60]
        elif asked == "q_shared" and yn == "no":
            found[asked] = "nothing"
        elif yn and asked in ("q_ask", "q_secrecy", "q_help"):
            found[asked] = yn
    for qid, ans in found.items():
        if qid in st["answers"]:
            continue
        st["answers"][qid] = ans
        await stdb_call("save_answer", {"incident_id": inc_id, "question_id": qid, "answer": ans})
    [inc] = await stdb_sql(f"SELECT * FROM svc_incident WHERE id = {inc_id}")
    sev = inc["severity"]
    shared = set(st["answers"].get("q_shared", "").split(","))
    if sev == "critical" or shared & CRITICAL:
        return {"say": "Thank you for telling me.", "done": True, "severity": sev}
    for qid, q in QUESTIONS:
        if qid not in st["answers"]:
            st["asked"] = qid
            return {"next_question": q, "question_id": qid, "say": "Thanks." if found else None, "done": False, "severity": sev}
    return {"say": "Thank you.", "done": True, "severity": sev}


@app.post("/run/family_alert")
async def family_alert(req: Request):
    calls.append({"workflow": "family_alert"})
    return JSONResponse({"error": "stub: use template fallback"}, status_code=503)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("STUB_AGENT_PORT", "8097")), log_level="warning")
