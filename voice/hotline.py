"""HotlineSession: the transport-independent conversation core of the scam hotline (spec 10).

The Pipecat pipeline (pipeline.py) and the text simulator (simulate.py) drive it the same way:

    session = HotlineSession(caller_e164=..., stdb=..., agent=..., cfg=..., speak=..., hangup=...)
    await session.start()              # greeting; opens the incident in the background
    await session.on_utterance(text)   # one final caller utterance (STT output)
    await session.on_dtmf("1")         # keypad press
    await session.on_hangup()          # caller hung up (idempotent finalisation)

`speak(text)` is awaited for every sentence block the caller should hear; `hangup()` is awaited
once after the goodbye. Nothing the caller says leaves this object unredacted, and no caller
content is logged.
"""
from __future__ import annotations

import asyncio
import re
import time
import uuid
from enum import Enum
from pathlib import Path
from typing import Any, Awaitable, Callable

import yaml

from agent_client import AgentClient, AgentError
from config import REPO_ROOT, Config
from logs import log
from redact import redact
from stdb import Stdb, StdbError

Speak = Callable[[str], Awaitable[None]]
Hangup = Callable[[], Awaitable[None]]

E164 = re.compile(r"^\+[1-9]\d{6,14}$")
LABEL_THRESHOLD = 3
LATENCY_TARGET_MS = 1500

REPEAT_PROMPT_FIRST = "To hear that again, press 1 or say repeat."
REPEAT_PROMPT = "Press 1 or say repeat."
SAFETY_LINE = "Please don't tell me any codes, PINs, card numbers or account numbers. I will never ask for them."
FILLER = "One moment while I check."
FALLBACK = [
    "Sorry, I couldn't check that just now.",
    "If someone asked for money, gift cards or a code, treat it as a scam.",
    "Don't send anything, and don't call them back.",
    "You can tell me more, or call your bank using the number on your card.",
]
OUT_OF_SCOPE = [
    "I can only help with scams and staying safe.",
    "Tell me about a call or message that worried you.",
]
GOODBYE = ["Thank you for calling. Take care. Goodbye."]

LEVEL_WORDS = {"critical": "critical", "high": "high", "medium": "medium", "low": "low"}
SHARED_WORDS = {
    "code": "a security code", "pin": "a PIN", "password": "a password", "card": "card details",
    "gift_card": "gift card numbers", "money": "money", "remote_app": "an app install",
    "personal_details": "personal details", "link": "a tapped link",
}

_YES = re.compile(r"\b(yes|yeah|yep|yup|sure|please|ok|okay|alright|all right|go ahead|do it|stay|tell them|correct)\b", re.I)
_NO = re.compile(r"\b(no|nope|nah|don't|do not|not now|no thanks|never mind)\b", re.I)
_REPEAT = re.compile(r"\b(repeat|say (that|it) again|come again|pardon)\b", re.I)
_BACK = re.compile(r"\b(back|done|finished|ok|okay|hello|i'm here|im here|yes|ready)\b", re.I)


def _load_steps() -> dict[str, str]:
    path = REPO_ROOT / "shared" / "recovery_library.yaml"
    try:
        data = yaml.safe_load(Path(path).read_text()) or {}
        return {k: v.get("text", "") for k, v in (data.get("steps") or {}).items()}
    except (OSError, yaml.YAMLError):
        return {}


STEP_TEXT = _load_steps()


class Phase(str, Enum):
    NEW = "new"
    DESCRIBE = "describe"
    INTERVIEW = "interview"
    STAY_OFFER = "stay_offer"
    HOLDING = "holding"
    FAMILY_OFFER = "family_offer"
    ENDED = "ended"


def greeting(app_name: str) -> str:
    return f"Hi, this is {app_name}. Tell me what happened, and I'll help you work out if it's a scam."


def is_repeat(text: str) -> bool:
    words = text.split()
    return bool(_REPEAT.search(text)) and len(words) <= 6


def yes_no(text: str) -> bool | None:
    if _NO.search(text):
        return False
    if _YES.search(text):
        return True
    return None


def shared_words(items: list[str]) -> str:
    words = [SHARED_WORDS.get(i, i) for i in items if i != "nothing"]
    if not words:
        return "nothing"
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]


def now_micros() -> int:
    return int(time.time() * 1_000_000)


def ts_micros(v: Any) -> int:
    if isinstance(v, list) and v:
        return int(v[0])
    return int(v or 0)


class HotlineSession:
    def __init__(
        self,
        *,
        caller_e164: str,
        stdb: Stdb,
        agent: AgentClient,
        cfg: Config,
        speak: Speak,
        hangup: Hangup | None = None,
        call_id: str | None = None,
    ):
        self.cfg = cfg
        self.stdb = stdb
        self.agent = agent
        self._speak_cb = speak
        self._hangup_cb = hangup
        self.call_id = call_id or uuid.uuid4().hex[:12]
        self.caller_e164 = caller_e164 if caller_e164 and E164.match(caller_e164) else ""
        self.phase = Phase.NEW
        self.person: dict[str, Any] | None = None
        self.incident_id: int = 0
        self.request_key = str(uuid.uuid4())
        self.severity = ""
        self.family_told = False
        self.caller_reports = 0
        self.router_intent = ""
        self.description: list[str] = []
        self.summary_saved = False
        self.last_response: list[str] = []
        self._repeat_offered = False
        self._lock = asyncio.Lock()
        self._setup: asyncio.Task | None = None
        self._family_poll: asyncio.Task | None = None
        self._finalized = False
        self._started_micros = now_micros()
        self._turn_t0: float | None = None
        self._first_audio_ms: int | None = None
        self._unclear = 0

    # --- output -------------------------------------------------------------------

    async def _emit(self, text: str) -> None:
        if self._turn_t0 is not None and self._first_audio_ms is None:
            self._first_audio_ms = int((time.monotonic() - self._turn_t0) * 1000)
        await self._speak_cb(text)

    async def _respond(self, lines: list[str], *, offer_repeat: bool = True) -> None:
        """Speak an answer, remember it for "repeat", then offer the repeat option (spec 10)."""
        lines = [ln.strip() for ln in lines if ln and ln.strip()]
        if not lines:
            return
        self.last_response = lines
        for ln in lines:
            await self._emit(ln)
        if offer_repeat:
            await self._emit(REPEAT_PROMPT if self._repeat_offered else REPEAT_PROMPT_FIRST)
            self._repeat_offered = True

    # --- lifecycle ------------------------------------------------------------------

    async def start(self) -> None:
        self.phase = Phase.DESCRIBE
        log("call_start", call_id=self.call_id, known_number=bool(self.caller_e164))
        # Speak first; the caller lookup and incident run while the greeting plays.
        self._setup = asyncio.create_task(self._open_incident())
        await self._respond([greeting(self.cfg.app_name), SAFETY_LINE], offer_repeat=False)

    async def _open_incident(self) -> None:
        t0 = time.monotonic()
        try:
            if self.caller_e164:
                self.person = await self.stdb.person_by_phone(self.caller_e164)
                report = await self.stdb.number_report(self.caller_e164)
                self.caller_reports = int(report.get("reporter_count", 0)) if report else 0
            await self.stdb.call("open_incident", {
                "request_key": self.request_key,
                "person_id": int(self.person["id"]) if self.person else 0,
                "entry_point": "hotline",
                "caller_e164": self.caller_e164,
            })
            inc = await self.stdb.incident_by_key(self.request_key)
            self.incident_id = int(inc["id"]) if inc else 0
            log("incident_opened", call_id=self.call_id, incident_id=self.incident_id,
                known_caller=self.person is not None, ms=int((time.monotonic() - t0) * 1000))
        except (StdbError, OSError, Exception) as e:  # noqa: BLE001 - the call must go on
            log("incident_open_failed", call_id=self.call_id, error=type(e).__name__)

    async def _ensure_setup(self) -> None:
        if self._setup is not None:
            try:
                await asyncio.wait_for(asyncio.shield(self._setup), timeout=10)
            except asyncio.TimeoutError:
                log("incident_open_slow", call_id=self.call_id)

    # --- input ----------------------------------------------------------------------

    async def on_dtmf(self, digit: str) -> None:
        # Keypad digits are never stored or logged; only "1" (repeat) means anything.
        if digit == "1":
            log("repeat", call_id=self.call_id, via="dtmf")
            await self._repeat()

    async def on_utterance(self, raw: str) -> None:
        text = redact(raw or "").strip()
        if not text or self.phase in (Phase.ENDED, Phase.NEW):
            return
        if is_repeat(text):
            log("repeat", call_id=self.call_id, via="speech")
            await self._repeat()
            return
        async with self._lock:
            self._turn_t0 = time.monotonic()
            self._first_audio_ms = None
            phase = self.phase
            outcome = "ok"
            try:
                if phase in (Phase.DESCRIBE, Phase.INTERVIEW):
                    outcome = await self._interview_turn(text)
                elif phase == Phase.STAY_OFFER:
                    await self._stay_offer_turn(text)
                elif phase == Phase.HOLDING:
                    outcome = await self._holding_turn(text)
                elif phase == Phase.FAMILY_OFFER:
                    await self._family_offer_turn(text)
            finally:
                ms = self._first_audio_ms
                log("turn", call_id=self.call_id, incident_id=self.incident_id, phase=phase.value,
                    outcome=outcome, first_audio_ms=ms,
                    over_target=(ms is not None and ms > LATENCY_TARGET_MS))
                self._turn_t0 = None

    async def _repeat(self) -> None:
        if self.last_response:
            await self._respond(list(self.last_response))

    async def on_hangup(self) -> None:
        await self._finalize("caller_hangup")

    # --- interview ------------------------------------------------------------------

    async def _agent_call(self, coro: Awaitable[dict[str, Any]], workflow: str) -> dict[str, Any] | None:
        """Runs one agent call under the 20 s budget, speaking a filler if it is slow."""
        t0 = time.monotonic()
        task = asyncio.ensure_future(coro)
        try:
            done, _ = await asyncio.wait({task}, timeout=self.cfg.filler_after_s)
            if not done:
                await self._emit(FILLER)
            remaining = max(0.0, self.cfg.agent_timeout_s - (time.monotonic() - t0))
            res = await asyncio.wait_for(asyncio.shield(task), timeout=remaining)
            log("agent", call_id=self.call_id, workflow=workflow, outcome="ok",
                ms=int((time.monotonic() - t0) * 1000))
            return res
        except asyncio.TimeoutError:
            task.cancel()
            log("agent", call_id=self.call_id, workflow=workflow, outcome="timeout",
                ms=int((time.monotonic() - t0) * 1000))
        except (AgentError, Exception) as e:  # noqa: BLE001
            log("agent", call_id=self.call_id, workflow=workflow, outcome="error", error=str(e)[:60],
                ms=int((time.monotonic() - t0) * 1000))
        return None

    async def _save_summary(self) -> None:
        if not self.incident_id or not self.description:
            return
        summary = ("Hotline call. Caller said: " + " ".join(self.description))[:480]
        try:
            await self.stdb.call("save_answer", {
                "incident_id": self.incident_id, "question_id": "q_summary", "answer": redact(summary),
            })
            self.summary_saved = True
        except StdbError as e:
            log("summary_failed", call_id=self.call_id, incident_id=self.incident_id, error=str(e))

    async def _interview_turn(self, text: str) -> str:
        await self._ensure_setup()
        first = self.phase == Phase.DESCRIBE
        if first:
            self.description.append(text)
            # Save the redacted description before the interview can raise severity, so the
            # module's community evidence row (written when severity rises) carries the script.
            await self._save_summary()
        if not self.incident_id:
            await self._respond(FALLBACK)
            return "no_incident"

        if first:
            router_task = asyncio.ensure_future(self.agent.router(
                text=text, from_e164=self.caller_e164,
                person_id=int(self.person["id"]) if self.person else 0))
            res = await self._agent_call(
                self.agent.interview(incident_id=self.incident_id, utterance=text), "interview")
            try:
                route = await asyncio.wait_for(router_task, timeout=0.5 if res is not None else 0.01)
                self.router_intent = str(route.get("intent", ""))
                log("agent", call_id=self.call_id, workflow="router", outcome="ok", intent=self.router_intent)
            except Exception as e:  # noqa: BLE001 - routing is advisory on the hotline
                router_task.cancel()
                log("agent", call_id=self.call_id, workflow="router", outcome="skipped", error=type(e).__name__)
            if self.router_intent == "out_of_scope" and not (res or {}).get("severity"):
                await self._respond(OUT_OF_SCOPE)
                return "out_of_scope"
        else:
            res = await self._agent_call(
                self.agent.interview(incident_id=self.incident_id, utterance=text), "interview")

        if res is None:
            await self._respond(FALLBACK)
            return "fallback"

        self.phase = Phase.INTERVIEW
        lines = [str(res["say"])] if res.get("say") else []
        if res.get("done"):
            # Voice owns the spoken verdict (stay-on-the-line offer, closing); the agent's wrap-up
            # text would repeat it. Trust the agent's alert_sent for "I've told your family".
            self.family_told = self.family_told or bool(res.get("alert_sent"))
            await self._conclude([], str(res.get("severity") or ""))
            return "done"
        # In voice mode `say` already holds the spoken form of the next question; only fall back
        # to next_question (the text form) when the agent gave no `say`.
        if not lines:
            nq = res.get("next_question")
            lines.append(str(nq) if nq else "Tell me a bit more about what happened.")
        await self._respond(lines)
        return "question"

    # --- verdict and ending ---------------------------------------------------------

    async def _conclude(self, prefix: list[str], agent_severity: str) -> None:
        inc = await self._incident()
        sev = (inc or {}).get("severity") or agent_severity or ""
        self.severity = sev
        shared = list((inc or {}).get("shared_items") or [])
        steps: list[dict[str, Any]] = []
        if self.incident_id:
            try:
                steps = await self.stdb.recovery_steps(self.incident_id)
            except StdbError:
                steps = []
        if sev in ("critical", "high") and self.person:
            self._family_poll = asyncio.create_task(self._wait_for_family_alert())

        lines = list(prefix)
        if sev == "critical":
            lines += ["This is a scam, and it's urgent.",
                      f"You shared {shared_words(shared)}. That's okay. We'll fix this together."]
        elif sev == "high":
            lines += ["This looks like a scam.", f"You shared {shared_words(shared)}, so let's be careful."]
        elif sev == "medium":
            lines += ["This is very likely a scam.", "You did the right thing by not sharing anything."]
        elif sev == "low":
            lines += ["Good news. You didn't share anything, so you're safe."]
        else:
            lines += ["I can't tell for sure from what you've told me.",
                      "Treat any request for money, gift cards or codes as a scam."]
        if sev:
            lines.append(f"I've marked the risk as {LEVEL_WORDS[sev]}.")
        if self.caller_reports >= LABEL_THRESHOLD:
            lines.append("Many people have reported this number as a scam.")

        first_steps = [STEP_TEXT[s["step_key"]] for s in steps
                       if not s.get("done") and s.get("priority") in ("now", "today") and s.get("step_key") in STEP_TEXT][:2]
        if first_steps:
            lines.append("Here's what to do first.")
            lines += first_steps
        elif sev in ("medium", "low", ""):
            lines.append("Don't call them back. If they call again, just hang up.")

        if sev == "critical":
            lines.append("Would you like me to stay on the line while you call your bank or carrier? Say yes or no.")
            self.phase = Phase.STAY_OFFER
            await self._respond(lines)
            return
        await self._respond(lines, offer_repeat=True)
        await self._closing()

    async def _incident(self) -> dict[str, Any] | None:
        if not self.incident_id:
            return None
        try:
            return await self.stdb.incident(self.incident_id)
        except StdbError:
            return None

    async def _wait_for_family_alert(self) -> bool:
        deadline = time.monotonic() + self.cfg.family_alert_wait_s
        while True:
            try:
                if await self.stdb.family_alerts(self.incident_id):
                    return True
            except StdbError:
                pass
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(0.25)

    async def _closing(self) -> None:
        sev = self.severity
        lines: list[str] = []
        if sev in ("critical", "high"):
            if self.person and self._family_poll is not None:
                self.family_told = self.family_told or await self._family_poll
            if self.family_told:
                lines.append("I've told your family.")
            else:
                lines.append("Please tell someone you trust what happened today.")
        elif sev == "medium":
            if self.person:
                self.phase = Phase.FAMILY_OFFER
                await self._respond(["Would you like me to tell your family? Say yes or no."])
                return
            lines.append(f"If you set up {self.cfg.app_name} on your phone, we can warn your family next time.")
        await self._goodbye(lines)

    async def _stay_offer_turn(self, text: str) -> None:
        ans = yes_no(text)
        if ans is None and self._unclear == 0:
            self._unclear += 1
            await self._respond(["Sorry. Should I stay on the line while you call your bank? Say yes or no."])
            return
        self._unclear = 0
        if ans:
            self.phase = Phase.HOLDING
            await self._respond([
                "Okay. I'll stay right here.",
                "Call them from another phone if you can.",
                "Say I'm back when you're done.",
            ], offer_repeat=False)
            return
        await self._closing()

    async def _holding_turn(self, text: str) -> str:
        if not _BACK.search(text):
            return "holding"  # likely the bank call on speaker: stay quiet
        await self._respond(["Welcome back. You did the right thing by acting fast."], offer_repeat=False)
        await self._closing()
        return "back"

    async def _family_offer_turn(self, text: str) -> None:
        ans = yes_no(text)
        if ans is None and self._unclear == 0:
            self._unclear += 1
            await self._respond(["Sorry. Should I tell your family? Say yes or no."])
            return
        self._unclear = 0
        if ans:
            try:
                await self.stdb.call("tell_my_family", {"incident_id": self.incident_id})
                self.family_told = True
                log("tell_my_family", call_id=self.call_id, incident_id=self.incident_id, outcome="ok")
                await self._goodbye(["Okay. I've told your family."])
            except StdbError as e:
                log("tell_my_family", call_id=self.call_id, incident_id=self.incident_id, outcome="error", error=str(e))
                await self._goodbye(["Sorry, I couldn't reach your family just now. You can use Tell my family in the app."])
            return
        await self._goodbye(["Okay. I won't tell them."])

    async def _goodbye(self, lines: list[str]) -> None:
        self.phase = Phase.ENDED
        await self._respond(lines + GOODBYE, offer_repeat=False)
        await self._finalize("completed")
        if self._hangup_cb:
            await self._hangup_cb()

    # --- finalisation: summary + community corpus (spec 7a feedback loop) ----------------

    async def _finalize(self, reason: str) -> None:
        if self._finalized:
            return
        self._finalized = True
        self.phase = Phase.ENDED
        if self._setup is not None and not self._setup.done():
            try:
                await asyncio.wait_for(self._setup, timeout=5)
            except Exception:  # noqa: BLE001
                pass
        evidence = "skipped"
        try:
            if self.incident_id and self.description and not self.summary_saved:
                await self._save_summary()
            evidence = await self._ensure_evidence()
        except Exception as e:  # noqa: BLE001
            evidence = f"error:{type(e).__name__}"
        if self._family_poll is not None and not self._family_poll.done():
            self._family_poll.cancel()
        log("call_end", call_id=self.call_id, incident_id=self.incident_id, reason=reason,
            severity=self.severity or "none", family_told=self.family_told, evidence=evidence,
            secs=round((now_micros() - self._started_micros) / 1e6, 1))

    async def _ensure_evidence(self) -> str:
        """Adds the redacted call script to the corpus unless the module/agent already did.

        The module writes a hotline evidence row itself when severity rises to Medium or above
        (spacetime/src/severity.ts addIncidentEvidence). We add one when that did not happen but
        the call still looked like a scam: severity rose but no row exists, or the caller hung up
        before the interview finished after describing an ask for money/codes.
        """
        if not self.incident_id or not self.description:
            return "none"
        inc = await self._incident() or {}
        sev = inc.get("severity") or ""
        self.severity = self.severity or sev
        answers: dict[str, Any] = {}
        try:
            import json
            answers = json.loads(inc.get("answers_json") or "{}")
        except ValueError:
            pass
        looked_like_scam = sev in ("medium", "high", "critical") or (
            sev == "" and (answers.get("q_ask") in ("yes", "agreed") or self.router_intent == "scam_check"
                           or self.caller_reports >= LABEL_THRESHOLD))
        if not looked_like_scam:
            return "not_needed"
        summary = redact(inc.get("summary_redacted") or ("Hotline call. Caller said: " + " ".join(self.description)))
        rows = await self.stdb.hotline_evidence()
        for r in rows:
            if ts_micros(r.get("created_at")) < self._started_micros - 5_000_000:
                continue
            if (self.caller_e164 and r.get("sender_e164") == self.caller_e164) or r.get("text_redacted") == summary[:1000]:
                return "already_present"
        await self.stdb.call("add_report_evidence", {
            "source": "hotline", "channel": "call", "sender_e164": self.caller_e164, "links": [],
            "claimed_identity": inc.get("claimed_identity") or "", "tactics": list(inc.get("tactics") or []),
            "text": summary[:1000],
            "verdict": "likely_scam" if sev in ("high", "critical") else "suspicious",
            "campaign_id": int(inc.get("campaign_id") or 0),
        })
        return "added"
