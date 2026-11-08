"""command: iMessage commands understood by Nemotron (docs/CONTRACTS.md section 7).

Actions: report, add_family, remove_family, list_family, status, set_code_word, get_code_word, briefing,
feedback (and help when nothing matched). Obvious forms ("report +1 555...", "add Maria +1 555...
daughter", "who is in my family", "status") take a regex fast path; anything else goes to MODEL_FAST,
which returns a schema-checked action (shared/schemas/command.model.json). Model fields are re-checked
against the text (a phone number, name or code word must actually appear in it), and phone numbers are
normalized to E.164 (US default). Every action replies through `enqueue_outbox`, result first.

Tool calls (max 6): at most 4 reads + 1 reducer (or one batch) + the reply.
"""
from __future__ import annotations

import json
import re
import time
from typing import Any

from .. import training
from ..llm import prompt
from ..log import log
from ..signals import extract_phones, extract_urls, registrable_domain, to_e164
from ..stdb import q
from .base import BadRequest, NotFound, Run, clamp, human_list, outbox_args

ACTIONS = ["report", "add_family", "remove_family", "list_family", "status", "set_code_word", "get_code_word",
           "briefing", "feedback", "help"]
VERDICT_WORDS = {"likely_scam": "Likely scam", "suspicious": "Suspicious", "safe": "Looks safe"}
WEEK_S = 7 * 24 * 3600
LABEL_THRESHOLD = 3

RELATIONSHIPS = [
    "grandson", "granddaughter", "grandchild", "grandmother", "grandfather", "grandma", "grandpa", "son", "daughter",
    "child", "wife", "husband", "partner", "spouse", "mother", "father", "mom", "dad", "brother", "sister", "nephew",
    "niece", "cousin", "aunt", "uncle", "friend", "neighbor", "neighbour", "caregiver", "son-in-law",
    "daughter-in-law", "sibling",
]
_REL_RE = "|".join(sorted((re.escape(r) for r in RELATIONSHIPS), key=len, reverse=True))
_NAME = r"[A-Za-z][A-Za-z'.-]*(?:\s+[A-Z][A-Za-z'.-]*)?"
_PHONE = r"\+?\(?\d[\d\s().-]{8,18}\d"
_END = r"\s*[.!?]*\s*$"

COMMAND_HELP = ("I can do these for you by text: \"report\" and a number or link (or \"report the last one\"), "
                "\"add\" a name and number to your family, \"remove\" a name, \"who is in my family\", \"status\", "
                "\"code word\" and a word, \"briefing\", or \"wrong\" / \"right\" about my last check.")

# --- phone numbers ----------------------------------------------------------------------------


def normalize_phone(raw: str) -> str:
    """E.164 with a US default: "214-555-0100" -> "+12145550100", "+44 20 7946 0958" kept. "" if invalid."""
    raw = (raw or "").strip()
    if not raw:
        return ""
    digits = re.sub(r"\D", "", raw)
    if raw.startswith("00") and 8 <= len(digits) - 2 <= 15:
        return "+" + digits[2:]
    e = to_e164(raw)
    if not e or not re.fullmatch(r"\+[1-9]\d{6,14}", e):
        return ""
    if e.startswith("+1") and (len(e) != 12 or e[2] in "01"):
        return ""  # NANP: 10 digits, area code can't start with 0/1
    return e


def pretty_phone(e164: str) -> str:
    if re.fullmatch(r"\+1\d{10}", e164 or ""):
        return f"+1 {e164[2:5]}-{e164[5:8]}-{e164[8:]}"
    return e164


def _digits_in(text: str, e164: str) -> bool:
    """The number's national digits really appear in the text (guards against model invention)."""
    d = re.sub(r"\D", "", text or "")
    national = e164[2:] if e164.startswith("+1") else e164[1:]
    return bool(national) and national in d


# --- fast path --------------------------------------------------------------------------------

_LAST = re.compile(
    r"(?i)^(?:the\s+)?(?:(?:last|latest|previous|most recent|recent)(?:\s+(?:one|message|text|number|link|call|caller|check|scam))?"
    r"|that(?:\s+(?:one|number|link|caller|call|message|text|scam))?|this(?:\s+(?:one|number|link))?|it|them|him|her)$")
_REPORT = re.compile(r"(?i)^\s*(?:please\s+)?(?:report|block)(?:\s+and\s+block)?\s+(?:this\s+|the\s+)?(?:number|link|site|website|scammer)?\s*:?\s*(?P<v>\S.{0,60}?)" + _END)
_ADD = re.compile(
    rf"(?i)^\s*(?:please\s+)?add\s+(?:my\s+(?P<rel1>{_REL_RE})\s*,?\s+)?(?P<name>{_NAME})\s*[,:-]?\s*(?:at\s+|on\s+)?"
    rf"(?P<phone>{_PHONE})\s*[,(-]?\s*(?:as\s+(?:my\s+)?|my\s+|\(?)?(?P<rel2>{_REL_RE})?\)?" + _END)
_REMOVE = re.compile(r"(?i)^\s*(?:please\s+)?(?:remove|delete|drop)\s+(?:my\s+)?(?P<name>[A-Za-z][A-Za-z '.-]{0,40}?)"
                     r"(?:\s+from\s+(?:my\s+)?(?:family|contacts|list|family list))?" + _END)
_LIST = re.compile(r"(?i)^\s*(?:who(?:'?s|\s+is|\s+are)\s+(?:in\s+)?my\s+family(?:\s+(?:list|contacts))?|list(?:\s+my)?\s+family"
                   r"(?:\s+(?:members|contacts))?|(?:show\s+(?:me\s+)?)?my\s+family(?:\s+(?:list|contacts|members))?|family\s+list"
                   r"|family\s+members|family)" + _END)
_STATUS = re.compile(r"(?i)^\s*(?:status|my status|weekly status|summary|my summary|how am i doing)" + _END)
_GET_WORD = re.compile(r"(?i)^\s*(?:what(?:'?s|\s+is)\s+)?(?:my\s+|our\s+)?(?:family\s+)?code\s*-?word" + _END)
_SET_WORD = re.compile(r"(?i)^\s*(?:set\s+|change\s+|new\s+)?(?:my\s+|our\s+)?(?:family\s+)?code\s*-?word\s*(?:to\s+|is\s+|=\s*|:\s*)?"
                       r"[\"“'‘]?(?P<w>[^\"”'’?]{1,40}?)[\"”'’]?" + _END)
_BRIEFING = re.compile(r"(?i)^\s*(?:please\s+)?(?:send\s+(?:me\s+)?)?(?:my\s+)?(?:weekly\s+)?briefing(?:\s+please)?" + _END)
_FEEDBACK = [
    (re.compile(r"(?i)^\s*(?:(?:that|it)\s+(?:was|is)\s+(?:not|n'?t)\s+a\s+scam|not\s+a\s+scam|(?:that|it)(?:'s|\s+was|\s+is)\s+"
                r"(?:safe|fine|legit|real|ok(?:ay)?)|(?:that|it)\s+was\s+really\s+them)" + _END), None, "safe"),
    (re.compile(r"(?i)^\s*(?:(?:that|it)(?:'s|\s+was|\s+is)\s+(?:definitely\s+)?a\s+scam|(?:that|it)\s+was\s+a\s+scammer|scam)" + _END),
     None, "likely_scam"),
    (re.compile(r"(?i)^\s*(?:wrong|(?:that(?:'s|\s+is|\s+was)|you(?:'re|\s+are|\s+were))\s+wrong|that'?s\s+not\s+right|incorrect|nope,?\s+wrong)" + _END),
     False, ""),
    (re.compile(r"(?i)^\s*(?:right|correct|(?:that(?:'s|\s+is|\s+was)|you(?:'re|\s+are|\s+were))\s+(?:right|correct)|good\s+call|spot\s+on|you\s+got\s+it)" + _END),
     True, ""),
]
_NOT_A_NAME = {"your", "this", "that", "message", "messages", "account", "it", "all", "everything", "these", "app",
               "text", "texts", "now", "here", "link", "off", "out", "from"}
_STOP_NAMES = {"my", "the", "a", "an", "him", "her", "them", "number", "contact", "family", "please", "his", "is", "to",
               "and", "can", "you", "add", "new", "as", "their"}


def parse_feedback(text: str) -> dict[str, Any] | None:
    for rx, correct, label in _FEEDBACK:
        if rx.match(text or ""):
            out: dict[str, Any] = {"action": "feedback"}
            if correct is not None:
                out["correct"] = correct
            if label:
                out["label"] = label
            return out
    return None


def _report_target(v: str) -> dict[str, Any] | None:
    v = v.strip().strip("\"'“”")
    if _LAST.match(v):
        return {"action": "report", "target": "last"}
    phone = normalize_phone(v) if re.fullmatch(_PHONE, v) else ""
    if phone:
        return {"action": "report", "phone": phone}
    urls = extract_urls(v)
    if len(urls) == 1 and len(v.split()) == 1:
        return {"action": "report", "link": registrable_domain(urls[0])}
    return None


def parse_fast(text: str) -> dict[str, Any] | None:
    """Regex parse of the obvious forms. None means "ask the model"."""
    t = " ".join((text or "").split())
    if not t or len(t) > 160:
        return None
    m = _REPORT.match(t)
    if m:
        return _report_target(m.group("v"))
    m = _ADD.match(t)
    if m:
        phone = normalize_phone(m.group("phone"))
        name = clean_name(m.group("name"))
        if phone and name:
            rel = (m.group("rel1") or m.group("rel2") or "").lower()
            return {"action": "add_family", "name": name, "phone": phone, "relationship": rel}
    if _LIST.match(t):
        return {"action": "list_family"}
    if _STATUS.match(t):
        return {"action": "status"}
    if _GET_WORD.match(t):
        return {"action": "get_code_word"}
    m = _SET_WORD.match(t)
    if m and clean_code_word(m.group("w")):
        return {"action": "set_code_word", "code_word": clean_code_word(m.group("w"))}
    if _BRIEFING.match(t):
        return {"action": "briefing"}
    m = _REMOVE.match(t)
    if m and clean_name(m.group("name")) and len(m.group("name").split()) <= 3 \
            and not set(m.group("name").lower().split()) & _NOT_A_NAME:
        return {"action": "remove_family", "name": clean_name(m.group("name"))}
    return parse_feedback(t)


def clean_name(raw: str) -> str:
    words = [w for w in re.findall(r"[A-Za-z][A-Za-z'.-]*", raw or "") if w.lower() not in _STOP_NAMES]
    name = " ".join(words[:3]).strip(" .-'")
    return name[:1].upper() + name[1:] if name and name.lower() not in RELATIONSHIPS else (name.title() if name else "")


def clean_code_word(raw: str) -> str:
    w = " ".join((raw or "").strip().strip("\"'“”‘’.!").split())
    if not w or len(w) > 40 or w.lower() in ("to", "is", "please", "?"):
        return ""
    return w


# --- looser heuristics (no model) ---------------------------------------------------------------

_ASK_PREFIX = r"(?:(?:hey|hi|ok|okay)[, ]+)?(?:kavach[,:]?\s+)?(?:please\s+|pls\s+|can you\s+|could you\s+|would you\s+|will you\s+|i want to\s+|i'?d like to\s+|i need to\s+|help me\s+|go ahead and\s+)*"
_H_REPORT = re.compile(rf"(?i)^\s*{_ASK_PREFIX}(?:please\s+)?(?:report|block)\b")
_H_ADD = re.compile(rf"(?i)^\s*{_ASK_PREFIX}(?:please\s+)?add\b|\badd\b.{{0,40}}\b(?:to|in)\s+my\s+(?:family|contacts)\b")
_H_REMOVE = re.compile(rf"(?i)^\s*{_ASK_PREFIX}(?:please\s+)?(?:remove|delete|take)\b.{{0,40}}(?:\bfrom\s+my\s+(?:family|contacts|list)\b|$)")
_H_LIST = re.compile(r"(?i)\b(?:who(?:'?s|\s+is|\s+are)\s+(?:in|on)\s+my\s+family|(?:list|show)(?:\s+me)?\s+my\s+family|my\s+family\s+(?:list|members|contacts))\b")
_H_STATUS = re.compile(r"(?i)^\s*(?:what'?s\s+)?(?:my\s+)?(?:status|summary)\b|\bhow\s+am\s+i\s+doing\b|\b(?:this|the)\s+week'?s?\s+(?:summary|status)\b")
_H_WORD = re.compile(r"(?i)\bcode\s*-?\s*word\b")
_H_BRIEFING = re.compile(r"(?i)\bbriefing\b")


_REF_WORDS = re.compile(r"(?i)\b(number|that|it|this|them|last|latest|caller|called|call|scammer|him|her|one)\b")


def _heuristic_action(t: str) -> str:
    """Which command a loosely phrased request is, or "" (forwarded scam texts must not match)."""
    words = len(t.split())
    phones = re.findall(_PHONE, t)
    if _H_REPORT.search(t) and words <= 16 and not extract_urls(t) and (phones or _REF_WORDS.search(t)):
        return "report"
    if _H_ADD.search(t) and words <= 30 and phones and (re.search(rf"(?i)\b(?:{_REL_RE}|family)\b", t)
                                                       or re.search(r"\b[A-Z][a-z]+\b", t[1:])):
        return "add_family"
    if _H_REMOVE.search(t) and words <= 10 and not extract_urls(t):
        m = re.search(r"(?i)\b(?:remove|delete|take)\s+(?:my\s+)?(.+?)(?:\s+(?:off|out\s+of|from)\b.*)?[.!?]*$", t)
        target = (m.group(1) if m else "").lower().split()
        if target and len(target) <= 3 and not set(target) & _NOT_A_NAME:
            return "remove_family"
    if _H_LIST.search(t) and words <= 14:
        return "list_family"
    if _H_WORD.search(t) and words <= 14:
        return "code_word"
    if _H_BRIEFING.search(t) and words <= 10:
        return "briefing"
    if _H_STATUS.search(t) and words <= 10:
        return "status"
    return ""


def looks_like_command(text: str) -> bool:
    t = " ".join((text or "").split())
    if not t or len(t) > 240:
        return False
    return bool(parse_fast(t)) or bool(_heuristic_action(t))


def parse_heuristic(text: str) -> dict[str, Any]:
    """Best-effort parse when the model is unavailable."""
    fast = parse_fast(text)
    if fast:
        return fast
    t = " ".join((text or "").split())
    phones = [p for p in (normalize_phone(x) for x in re.findall(_PHONE, t)) if p]
    kind = _heuristic_action(t)
    if not kind:
        # Already routed here as a command: accept looser forms ("please add my son David").
        kind = ("add_family" if _H_ADD.search(t) else "report" if _H_REPORT.search(t) and not extract_urls(t)
                else "remove_family" if _H_REMOVE.search(t) else "")
    if kind == "report":
        return {"action": "report", "phone": phones[0]} if phones else {"action": "report", "target": "last"}
    if kind == "add_family":
        rel_m = re.search(rf"(?i)\b({_REL_RE})\b", t)
        name = ""
        m = (re.search(rf"(?i)\b(?:{_REL_RE})\s*,?\s+([A-Z][a-z'.-]+)", t) or re.search(r"\b(?i:add)\s+(?:(?i:my)\s+)?([A-Z][a-z'.-]+)", t)
             or re.search(r"\b([A-Z][a-z'.-]+)(?:'s)?\s+(?:number|phone|cell)\b", t))
        if m:
            name = clean_name(m.group(1))
        return {"action": "add_family", "name": name, "phone": phones[0] if phones else "",
                "relationship": rel_m.group(1).lower() if rel_m else ""}
    if kind == "list_family":
        return {"action": "list_family"}
    if kind == "remove_family":
        m = re.search(r"(?i)\b(?:remove|delete|take)\s+(?:my\s+)?([A-Za-z][A-Za-z'.-]*(?:\s+(?!(?i:off|out|from)\b)[A-Z][A-Za-z'.-]*)?)", t)
        return {"action": "remove_family", "name": clean_name(m.group(1)) if m else ""}
    if kind == "code_word":
        m = re.search(r"(?i)code\s*-?\s*word\s+(?:to|is|=|:)\s*[\"“'‘]?([^\"”'’?.!]{1,40})", t)
        if m and clean_code_word(m.group(1)) and not re.search(r"(?i)\bwhat\b", t):
            return {"action": "set_code_word", "code_word": clean_code_word(m.group(1))}
        return {"action": "get_code_word"}
    if kind in ("briefing", "status"):
        return {"action": kind}
    return {"action": "help"}


def check_model_action(text: str, m: dict[str, Any]) -> dict[str, Any]:
    """Keep only model fields that the text supports; normalize phone numbers and links."""
    action = m.get("action") if m.get("action") in ACTIONS else "help"
    out: dict[str, Any] = {"action": action}
    low = (text or "").lower()
    if action == "report":
        phone = normalize_phone(str(m.get("phone") or ""))
        link = str(m.get("link") or "").strip()
        if phone and _digits_in(text, phone):
            out["phone"] = phone
        elif link and extract_urls(link) and registrable_domain(link) and registrable_domain(link) in low:
            out["link"] = registrable_domain(link)
        else:
            phones = [p for p in (normalize_phone(x) for x in re.findall(_PHONE, text or "")) if p]
            urls = extract_urls(text or "")
            if phones:
                out["phone"] = phones[0]
            elif urls:
                out["link"] = registrable_domain(urls[0])
            else:
                out["target"] = "last"
    elif action in ("add_family", "remove_family"):
        name = clean_name(str(m.get("name") or ""))
        if name and name.split()[0].lower() in low:
            out["name"] = name
        else:
            out["name"] = ""
        if action == "add_family":
            phone = normalize_phone(str(m.get("phone") or ""))
            if not (phone and _digits_in(text, phone)):
                phones = [p for p in (normalize_phone(x) for x in re.findall(_PHONE, text or "")) if p]
                phone = phones[0] if phones else ""
            out["phone"] = phone
            rel = str(m.get("relationship") or "").lower().strip()
            out["relationship"] = rel if rel in RELATIONSHIPS and rel in low else ""
        elif not out["name"]:
            rel = str(m.get("relationship") or "").lower().strip()
            if rel in RELATIONSHIPS and rel in low:
                out["name"] = rel
    elif action == "set_code_word":
        w = clean_code_word(str(m.get("code_word") or ""))
        if w and w.lower() in low:
            out["code_word"] = w
        else:
            out["action"] = "get_code_word"
    elif action == "feedback":
        label = m.get("label") if m.get("label") in VERDICT_WORDS else ""
        if label:
            out["label"] = label
        if isinstance(m.get("correct"), bool):
            out["correct"] = m["correct"]
        if not label and "correct" not in out:
            out["correct"] = False
    return out


async def parse_command(run: Run, text: str, hint: str = "") -> tuple[dict[str, Any], str]:
    """(action dict, method). Regex fast path, else MODEL_FAST, else heuristics."""
    fast = parse_fast(text)
    if fast:
        return fast, "regex"
    model = await run.llm.json("fast", prompt("command"), json.dumps({"text": text[:600], "hint": hint},
                               ensure_ascii=False), "command.model", workflow=run.workflow, max_tokens=150, timeout=5.0)
    if model:
        return check_model_action(text, model), "model"
    return parse_heuristic(text), "heuristic"


# --- the workflow ---------------------------------------------------------------------------------


def _micros(v: Any) -> int:
    if isinstance(v, list):
        v = v[0] if v else 0
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


class _Ctx:
    def __init__(self, run: Run, person_id: int):
        self.run = run
        self.person_id = person_id
        self._person: dict | None = None

    async def person(self) -> dict:
        if self._person is None:
            self._person = await self.run.tools.call("get_person", {"person_id": self.person_id})
            if not self._person:
                raise NotFound("unknown person")
        return self._person

    async def read(self, query: str) -> list[dict]:
        return await self.run.tools.call("read", {"query": query}) or []

    async def reducer(self, name: str, args: dict) -> str:
        """Returns "" on success, else the refusal text."""
        from ..stdb import ReducerError

        try:
            await self.run.tools.call("reducer", {"name": name, "args": args})
            return ""
        except ReducerError as e:
            log("reducer_refused", workflow=self.run.workflow, error=e.text[:120], status=e.status)
            return e.text or "refused"


async def run_command(run: Run, p: dict[str, Any]) -> dict[str, Any]:
    person_id = int(p.get("person_id") or 0)
    text = (p.get("text") or "").strip()
    if not person_id:
        raise BadRequest("person_id required")
    run.fields["person_id"] = person_id
    ctx = _Ctx(run, person_id)

    given = p.get("args") if isinstance(p.get("args"), dict) else {}
    if given.get("action") in ACTIONS and given.get("action") != "help" and _complete(given):
        action, method = dict(given), "router"
    elif text:
        action, method = await parse_command(run, text, hint=str(given.get("action") or ""))
    elif given.get("action") in ACTIONS:
        action, method = dict(given), "args"
    else:
        raise BadRequest("text or args.action required")
    name = action["action"]
    run.fields.update(action=name, method=method)

    to = p.get("reply_to_e164") or ""
    if not to and not p.get("_no_reply"):
        to = (await ctx.person()).get("phone_e164") or ""
    handler = HANDLERS.get(name, _help)
    ok, reply, data = await handler(ctx, action, text)
    reply = clamp(f"{run.app}: {reply}")

    incident_id = 0
    if data.get("incident_request_key"):
        rows = await ctx.read(f"SELECT * FROM svc_incident WHERE request_key = {q(data['incident_request_key'])}")
        incident_id = int(rows[0]["id"]) if rows else 0
        if incident_id:
            from .interview import QUESTIONS

            data["incident_id"] = incident_id
            reply = clamp(f"{reply} Tell me what happened so we can protect you (1 of 5): {QUESTIONS['q_identity']}")
    if to and not p.get("_no_reply"):
        channel = p.get("reply_channel") or "imessage"
        await run.tools.call("reducer", {"name": "enqueue_outbox", "args": outbox_args(
            to, channel if channel != "push" else "imessage", "reply", reply, "normal", incident_id)})
    log("command", workflow=run.workflow, action=name, method=method, outcome="ok" if ok else "not_done")
    return {"action": name, "ok": ok, "reply": reply, "data": data}


def _complete(a: dict) -> bool:
    """Router-supplied args are used as-is only when they carry what the action needs."""
    need = {"report": lambda: a.get("phone") or a.get("link") or a.get("target") == "last",
            "add_family": lambda: a.get("name") and a.get("phone"),
            "remove_family": lambda: a.get("name"),
            "set_code_word": lambda: a.get("code_word")}
    return bool(need.get(a.get("action"), lambda: True)())


# --- report -------------------------------------------------------------------------------------

async def _last_reportable(ctx: _Ctx, text: str) -> tuple[list[tuple[str, str]], str]:
    """(kind, value) pairs from the person's most recent suspicious/likely_scam check, or the latest
    reported call when they talk about a call. Second item says where it came from."""
    best: tuple[float, list[tuple[str, str]], str] = (0.0, [], "")
    d = training.latest_decision(ctx.person_id, workflows=("scam_check", "advise"), verdicts=("suspicious", "likely_scam"))
    if d:
        vals: list[tuple[str, str]] = []
        sig = d.get("signals") or {}
        if sig.get("sender_e164"):
            vals.append(("number", sig["sender_e164"]))
        vals += [("link", x) for x in sig.get("link_domains") or []]
        vals += [("number", x) for x in extract_phones(d.get("input_redacted", "")) if ("number", x) not in vals]
        if vals:
            best = (float(d.get("ts") or 0), vals[:3], "message")
    if not best[1]:
        checks = [c for c in await ctx.read(f"SELECT * FROM svc_message_check WHERE person_id = {ctx.person_id}")
                  if c.get("verdict") in ("suspicious", "likely_scam")]
        if checks:
            c = max(checks, key=lambda r: _micros(r.get("created_at")))
            content = c.get("content_redacted") or ""
            vals = [("number", x) for x in extract_phones(content)]
            vals += [("link", registrable_domain(u)) for u in extract_urls(content)]
            if vals:
                best = (_micros(c.get("created_at")) / 1e6, vals[:3], "message")
    if re.search(r"(?i)\bcall(?:ed|er|ing)?\b|\brang\b|\bphoned\b", text or "") or not best[1]:
        incs = [i for i in await ctx.read(f"SELECT * FROM svc_incident WHERE person_id = {ctx.person_id}")
                if i.get("caller_e164")]
        if incs:
            i = max(incs, key=lambda r: _micros(r.get("created_at")))
            ts = _micros(i.get("created_at")) / 1e6
            if not best[1] or ts > best[0] or re.search(r"(?i)\bcall", text or ""):
                best = (ts, [("number", i["caller_e164"])], "call")
    return best[1], best[2]


async def _report(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    if a.get("phone"):
        values, origin = [("number", a["phone"])], "given"
    elif a.get("link"):
        values, origin = [("link", a["link"])], "given"
    else:
        values, origin = await _last_reportable(ctx, text)
    if not values:
        return False, ("I couldn't find a number or link to report. Text \"report\" and the number, like "
                       "\"report +1 555 555 0144\"."), {}
    contacts = {c.get("phone_e164") for c in await ctx.run.tools.call("get_contacts", {"person_id": ctx.person_id}) or []}
    if any(k == "number" and v in contacts for k, v in values):
        return False, ("That number belongs to someone in your family list, so I didn't report it. If their phone was "
                       "hacked, call them on a number you trust."), {"values": [v for _, v in values]}
    from ..tools import checked_reducers

    calls = [{"name": "report_number", "args": {"person_id": ctx.person_id, "kind": k, "value": v}} for k, v in values]
    res = await checked_reducers(ctx.run.tools, calls)
    done = [(k, v) for (k, v), r in zip(values, res) if r["ok"]]
    if not done:
        return False, "I couldn't file that report right now. Please try again in a minute.", {}
    # Leave room for the reply (and the follow-up questionnaire) within the 6-call budget.
    reports = await ctx.read("SELECT * FROM svc_community_report") if ctx.run.tools.calls <= 2 else []
    counts = {(r.get("kind"), r.get("value")): int(r.get("reporter_count") or 0) for r in reports}
    k0, v0 = done[0]
    shown = pretty_phone(v0) if k0 == "number" else v0
    n = counts.get((k0, v0.lower() if k0 == "link" else v0), 1)
    what = "the number that called you" if origin == "call" else "the scam you checked" if origin == "message" else ""
    lead = f"Reported {shown}{f' ({what})' if what else ''}."
    extra = f" I also reported {human_list([pretty_phone(v) if k == 'number' else v for k, v in done[1:]])}." if len(done) > 1 else ""
    if n >= LABEL_THRESHOLD:
        social = f" {n} people have reported it, so it's now flagged as a scam for everyone using {ctx.run.app}."
    elif n == 2:
        social = " You're the second person to report it. Thanks for protecting others."
    else:
        social = " You're the first to report it. Thanks for protecting others."
    tail = " Don't call or text it back." if k0 == "number" else " Don't open it."
    data = {"reported": [{"kind": k, "value": v} for k, v in done], "reporter_count": n, "origin": origin}
    if k0 == "number" and ctx.run.tools.calls <= 3:
        # Follow through: open an incident for this caller so the 5-question report gets answered
        # (data collection, spec 8). The reply asks the first question; answers continue by text.
        from ..stdb import new_key

        key = new_key()
        await ctx.run.tools.call("reducer", {"name": "open_incident", "args": {
            "request_key": key, "person_id": ctx.person_id, "entry_point": "imessage", "caller_e164": v0}})
        data["incident_request_key"] = key
    return True, lead + extra + social + tail, data


# --- family ---------------------------------------------------------------------------------------

CONSENT_WORDS = {"accepted": "joined", "invited": "invite sent, not joined yet", "declined": "declined"}
CHANNEL_WORDS = {"imessage": "iMessage", "sms": "SMS", "rcs": "RCS", "whatsapp": "WhatsApp"}


def _describe(c: dict) -> str:
    rel = f" ({c['relationship']})" if c.get("relationship") else ""
    em = ", emergency contact" if c.get("is_emergency_contact") else ""
    return (f"{c.get('name')}{rel}: {CHANNEL_WORDS.get(c.get('channel'), c.get('channel'))}, "
            f"{CONSENT_WORDS.get(c.get('consent_status'), c.get('consent_status'))}{em}")


async def _list_family(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    person = await ctx.person()
    contacts = await ctx.run.tools.call("get_contacts", {"person_id": ctx.person_id}) or []
    if not contacts:
        return True, ("Your family list is empty. Text \"add\", a name and a number, like \"add Maria 214-555-0100 "
                      "daughter\"."), {"contacts": []}
    paused = bool(person.get("sharing_paused"))
    state = ("Family alerts are paused (text \"resume\" to turn them back on)." if paused
             else "Family alerts are on.")
    body = f"Your family ({len(contacts)}): " + "; ".join(_describe(c) for c in contacts) + ". " + state
    return True, body, {"contacts": [{"id": int(c["id"]), "name": c.get("name"), "channel": c.get("channel"),
                                      "consent_status": c.get("consent_status"),
                                      "relationship": c.get("relationship")} for c in contacts],
                        "sharing_paused": paused}


async def _add_family(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    name, phone, rel = a.get("name") or "", a.get("phone") or "", (a.get("relationship") or "")[:40]
    if not name and phone:
        return False, f"What's their name? Text \"add\", their name and number, like \"add Maria {pretty_phone(phone)}\".", {}
    if not phone:
        who = name or "them"
        return False, f"What's {who}'s number? Text \"add {name or 'Maria'}\" and the number, like \"add {name or 'Maria'} 214-555-0100\".", {}
    person = await ctx.person()
    if phone == person.get("phone_e164"):
        return False, "That's your own number. Send the number of the family member you want to add.", {}
    contacts = await ctx.run.tools.call("get_contacts", {"person_id": ctx.person_id}) or []
    same = next((c for c in contacts if c.get("phone_e164") == phone), None)
    if same:
        return True, f"{same.get('name')} is already in your family at {pretty_phone(phone)}.", {"contact_id": int(same["id"])}
    err = await ctx.reducer("upsert_contact", {
        "person_id": ctx.person_id, "contact_id": 0, "name": name, "phone_e164": phone, "relationship": rel,
        "channel": "imessage", "is_emergency_contact": False})
    if err:
        return False, f"I couldn't add {name} right now. Please check the number and try again.", {}
    rel_txt = f" ({rel})" if rel else ""
    me = person.get("display_name") or "you"
    return True, (f"Added {name}{rel_txt} at {pretty_phone(phone)}. I've texted {name} an invite; they'll get your "
                  f"scam alerts after they reply \"join {me}\"."), {"name": name, "phone_e164": phone,
                                                                  "relationship": rel}


def match_contacts(contacts: list[dict], name: str) -> list[dict]:
    n = (name or "").strip().lower()
    if not n:
        return []
    exact = [c for c in contacts if str(c.get("name", "")).strip().lower() == n]
    if exact:
        return exact
    first = [c for c in contacts if str(c.get("name", "")).strip().lower().split(" ")[0] == n.split(" ")[0]]
    if first:
        return first
    return [c for c in contacts if str(c.get("relationship", "")).strip().lower() == n]


async def _remove_family(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    contacts = await ctx.run.tools.call("get_contacts", {"person_id": ctx.person_id}) or []
    hits = match_contacts(contacts, a.get("name") or "")
    names = [c.get("name") for c in contacts]
    if len(hits) != 1:
        if not contacts:
            return False, "Your family list is empty, so there's nobody to remove.", {}
        which = "Which one should I remove? " if hits else f"I couldn't find \"{a.get('name') or ''}\" in your family. "
        options = [c.get("name") for c in (hits or contacts)]
        return False, f"{which}Your family: {human_list(options)}. Text \"remove\" and the exact name.", \
            {"candidates": options}
    c = hits[0]
    err = await ctx.reducer("remove_contact", {"contact_id": int(c["id"])})
    if err:
        return False, f"I couldn't remove {c.get('name')} right now. Please try again.", {}
    left = [n for n in names if n != c.get("name")]
    tail = f" Still in your family: {human_list(left)}." if left else " Your family list is now empty."
    return True, f"Removed {c.get('name')}. They won't get your alerts anymore.{tail}", {"removed_contact_id": int(c["id"])}


# --- status ---------------------------------------------------------------------------------------

def summarize_status(checks: list[dict], incidents: list[dict], requests: list[dict], contacts: list[dict],
                     now_s: float | None = None) -> tuple[str, dict]:
    now_s = now_s or time.time()
    since = (now_s - WEEK_S) * 1_000_000
    week = [c for c in checks if _micros(c.get("created_at")) >= since]
    by = {v: sum(1 for c in week if c.get("verdict") == v) for v in ("likely_scam", "suspicious", "safe")}
    open_inc = [i for i in incidents if i.get("status") != "resolved"]
    names = {int(c["id"]): c.get("name") for c in contacts}
    pending = [r for r in requests if r.get("status") == "pending"]
    unanswered = [r for r in requests if r.get("status") == "unanswered" and _micros(r.get("created_at")) >= since]
    parts = []
    if week:
        parts.append(f"This week you checked {len(week)} message{'s' if len(week) != 1 else ''}: "
                     f"{by['likely_scam']} likely scam, {by['suspicious']} suspicious, {by['safe']} safe.")
    else:
        parts.append("You haven't checked any messages this week.")
    parts.append(f"{len(open_inc)} open incident{'s' if len(open_inc) != 1 else ''}." if open_inc else "No open incidents.")

    def who(rs: list[dict]) -> str:
        ids = []
        for r in rs:
            for cid in r.get("recipient_contact_ids") or []:
                if int(cid) in names and names[int(cid)] not in ids:
                    ids.append(names[int(cid)])
        return human_list(ids)

    if pending:
        parts.append(f"Waiting for a family reply on {len(pending)} alert{'s' if len(pending) != 1 else ''}"
                     + (f" (sent to {who(pending)})." if who(pending) else "."))
    if unanswered:
        parts.append(f"{len(unanswered)} alert{'s' if len(unanswered) != 1 else ''} got no family reply"
                     + (f"; you may want to call {who(unanswered)}." if who(unanswered) else "."))
    if not pending and not unanswered:
        parts.append("No family replies pending.")
    data = {"checks": {"total": len(week), **by}, "open_incidents": len(open_inc), "pending_family_replies": len(pending),
            "unanswered_family_replies": len(unanswered)}
    return " ".join(parts), data


async def _status(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    pid = ctx.person_id
    checks = await ctx.read(f"SELECT * FROM svc_message_check WHERE person_id = {pid}")
    incidents = await ctx.read(f"SELECT * FROM svc_incident WHERE person_id = {pid}")
    requests = await ctx.read(f"SELECT * FROM svc_alert_request WHERE person_id = {pid}")
    contacts = await ctx.run.tools.call("get_contacts", {"person_id": pid}) or []
    body, data = summarize_status(checks, incidents, requests, contacts)
    return True, body, data


# --- settings -------------------------------------------------------------------------------------

def settings_args(person: dict, **changes: Any) -> dict[str, Any]:
    """update_settings takes every field: keep the current values, change only what was asked."""
    args = {
        "person_id": int(person["id"]), "accessibility_mode": bool(person.get("accessibility_mode")),
        "sharing_paused": bool(person.get("sharing_paused")),
        "critical_overrides_pause": bool(person.get("critical_overrides_pause")),
        "apns_token": person.get("apns_token") or "", "family_code_word": person.get("family_code_word") or "",
        "tz_offset_minutes": int(person.get("tz_offset_minutes") or 0),
    }
    args.update(changes)
    return args


async def _set_code_word(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    word = clean_code_word(a.get("code_word") or "")
    if not word:
        return False, "What should the code word be? Text \"code word\" and the word, like \"code word bluebird\".", {}
    person = await ctx.person()
    err = await ctx.reducer("update_settings", settings_args(person, family_code_word=word))
    if err:
        return False, "I couldn't save the code word right now. Please try again.", {}
    return True, (f"Your family code word is now \"{word}\". If someone says they're family and can't tell you "
                  "the code word, hang up and call them on a number you know."), {"set": True}


async def _get_code_word(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    word = (await ctx.person()).get("family_code_word") or ""
    if not word:
        return True, ("You haven't set a family code word yet. Text \"code word\" and a word only your family knows, "
                      "like \"code word bluebird\"."), {"set": False}
    return True, (f"Your family code word is \"{word}\". Ask anyone who says they're family for it before you send "
                  "anything."), {"set": True}


async def _briefing(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    err = await ctx.reducer("request_briefing", {"person_id": ctx.person_id})
    if err:
        return False, "I couldn't start your briefing right now. Please try again later.", {}
    return True, "Your weekly briefing is on its way. It'll arrive here in a moment.", {}


# --- feedback -------------------------------------------------------------------------------------

async def _feedback(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    d = training.latest_decision(ctx.person_id)
    if not d:
        return False, "I don't have a recent check to rate. Forward me a message and I'll check it.", {}
    correct = a.get("correct") if isinstance(a.get("correct"), bool) else None
    lb = training.add_label(decision=d, person_id=ctx.person_id, source="imessage", correct=correct,
                            label=a.get("label") or "", note="")
    if not lb:
        return False, "Thanks. I couldn't save that right now.", {}
    prev = VERDICT_WORDS.get(d.get("final_verdict", ""), d.get("final_verdict", ""))
    label = lb["label"]
    if lb["correct"] is True:
        body = f"Thanks for confirming. My last answer ({prev}) was right, and I'll remember that."
    else:
        body = f"Thanks for telling me. I've noted that my last answer ({prev}) was wrong, so I can learn from it."
        if label == "safe":
            body += " Even so, never share codes or send money because of a message."
        elif label in ("suspicious", "likely_scam"):
            body += " Don't reply, tap links, or send anything to them."
    return True, body, {"decision_id": d.get("id"), "label": label, "correct": lb["correct"]}


async def _help(ctx: _Ctx, a: dict, text: str) -> tuple[bool, str, dict]:
    return False, COMMAND_HELP, {}


HANDLERS = {
    "report": _report, "add_family": _add_family, "remove_family": _remove_family, "list_family": _list_family,
    "status": _status, "set_code_word": _set_code_word, "get_code_word": _get_code_word, "briefing": _briefing,
    "feedback": _feedback, "help": _help,
}
