"""Guardrails (D11, spec 7). NeMo Guardrails runs the rails defined in agents/guardrails/;
the checks themselves are deterministic Python actions registered with the rails app, so they
work without a model. If nemoguardrails can't load, the same actions run directly (same results).

Rails:
- input: off-topic requests get a short scope message
- output: never ask for codes, PINs, passwords or payment
- output: no medical, legal or financial advice beyond the vetted steps
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .config import GUARDRAILS_DIR, settings
from .log import log
from .signals import TACTIC_PATTERNS, extract_phones, extract_urls

# --- input rail: scope ------------------------------------------------------------------

_ON_TOPIC = re.compile(
    r"(?i)\b(scam|fraud|spam|phish|suspicious|safe|legit|real|fake|hack|stolen|steal|verify|code|pin|password|"
    r"gift ?card|bank|card|account|money|pay|paid|payment|refund|toll|irs|police|arrest|bail|grand(son|daughter|ma|pa|child)|"
    r"call(ed|er|ing)?|text(ed)?|message|email|link|website|number|sms|imessage|voicemail|block|report|help|family|"
    r"pause|resume|stop|alert|share[ds]?|sent|send|click(ed)?|tap(ped)?|install(ed)?|remote|anydesk|teamviewer|"
    r"social security|ssn|medicare|carrier|sim|identity|prize|won|lottery|job offer|recruiter|bitcoin|crypto|wire|zelle|venmo)\b"
)
_OFF_TOPIC = re.compile(
    r"(?i)\b(weather|forecast|recipe|cook|poem|joke|song|lyrics|story|movie|tv show|sports?|score|game tonight|"
    r"homework|essay|math|translate|capital of|who won|stock price|horoscope|trivia|write (me )?(a|an)|"
    r"what time is it|tell me about yourself|meaning of life|best restaurant|directions to)\b"
)

SCOPE_MESSAGE = "{app}: I can only help with scams and staying safe. Forward me a message you're unsure about, or text \"help\"."


def is_on_topic(text: str) -> bool:
    """Heuristic scope check. Anything that looks like a forwarded message (links, numbers, scam
    vocabulary) is on topic; general-chat requests without scam signals are not."""
    t = (text or "").strip()
    if not t:
        return False
    if extract_urls(t) or extract_phones(t):
        return True
    if any(p.search(t) for p in TACTIC_PATTERNS.values()):
        return True
    if _OFF_TOPIC.search(t):
        return False
    return bool(_ON_TOPIC.search(t)) or len(t) > 80  # long pasted text: treat as a message to check


def is_explicit_off_topic(text: str) -> bool:
    """True only for clear general-chat requests (weather, recipes, homework...) with no scam signals.
    Anything merely lacking scam vocabulary (e.g. a forwarded friendly text) is not explicit."""
    t = (text or "").strip()
    return bool(t) and not is_on_topic(t) and bool(_OFF_TOPIC.search(t))


# --- output rails -------------------------------------------------------------------------

_NEG = r"(?:never|don'?t|do not|not|no one|nobody|won'?t|will never|shouldn'?t|should never|stop|avoid|without)"
_SECRET = r"(?:(?:security |verification |one[- ]time |6[- ]digit |the |your |that |this )*(?:code|pin|passcode|password|otp)s?|card (?:number|details)|account number|social security number|ssn|bank details|login)"
_ASK_VERB = r"(?:send|share|tell|give|read|text|reply with|provide|enter|confirm|type|say|verify)"
_REQUEST_SECRET = re.compile(
    rf"(?i)(?:\b{_ASK_VERB}\b[^.!?\n]{{0,30}}\b{_SECRET}\b|\bwhat(?:'s| is) (?:your|the) {_SECRET}\b|\b{_SECRET}\b[^.!?\n]{{0,12}}\bplease\b)"
)
_PAYMENT_VERB = r"(?:pay|send|wire|transfer|buy|purchase|deposit|venmo|zelle)"
_REQUEST_PAYMENT = re.compile(
    rf"(?i)\b{_PAYMENT_VERB}\b[^.!?\n]{{0,30}}\b(?:fee|money|payment|\$\s?\d[\d,.]*|gift ?cards?|bitcoin|crypto|funds|deposit)\b"
)
_ADVICE = re.compile(
    r"(?i)\b(you should (invest|buy|sell|sue|take)|invest (in|your)|buy (stocks?|crypto|bitcoin|gold)|"
    r"(hire|get) a (lawyer|attorney) (to|and) sue|file a lawsuit|legal advice|take (out )?a loan|withdraw your (savings|retirement)|"
    r"medication|dosage|diagnos(is|e)|prescri(be|ption)|see a doctor about|mg\b)"
)


def _negated(text: str, start: int) -> bool:
    window = text[max(0, start - 40) : start]
    sentence = re.split(r"[.!?\n]", window)[-1]
    return bool(re.search(rf"(?i)\b{_NEG}\b", sentence))


def asks_for_secret_or_payment(text: str) -> bool:
    for rx in (_REQUEST_SECRET, _REQUEST_PAYMENT):
        for m in rx.finditer(text or ""):
            if not _negated(text, m.start()):
                return True
    return False


def gives_restricted_advice(text: str) -> bool:
    return bool(_ADVICE.search(text or ""))


@dataclass
class RailResult:
    ok: bool
    rail: str = ""
    message: str = ""


class Guard:
    """Seam: NeMo Guardrails `LLMRails.check_async` when available, else the same actions directly."""

    def __init__(self) -> None:
        self.engine = "python"
        self._rails = None
        if not settings().use_guardrails:
            return
        try:
            from nemoguardrails import LLMRails, RailsConfig

            cfg = RailsConfig.from_path(str(GUARDRAILS_DIR))
            rails = LLMRails(cfg)
            rails.register_action(self._act_scope, name="check_scope")
            rails.register_action(self._act_output, name="check_output_safety")
            self._rails = rails
            self.engine = "nemoguardrails"
        except Exception as e:  # noqa: BLE001 - never block the service on the framework
            log("guardrails_fallback", error=f"{type(e).__name__}: {str(e)[:120]}")

    # Actions (sync; registered with the rails app). Return True when the text passes.
    @staticmethod
    def _act_scope(text: str | None = None) -> bool:
        return is_on_topic(text or "")

    @staticmethod
    def _act_output(text: str | None = None) -> bool:
        t = text or ""
        return not asks_for_secret_or_payment(t) and not gives_restricted_advice(t)

    async def _check(self, messages: list[dict], rail_type: str) -> tuple[bool, str]:
        from nemoguardrails.rails.llm.options import RailType

        rt = RailType.INPUT if rail_type == "input" else RailType.OUTPUT
        res = await self._rails.check_async(messages, rail_types=[rt])
        return getattr(res.status, "value", str(res.status)) == "passed", res.rail or ""

    async def check_input(self, text: str) -> RailResult:
        msg = SCOPE_MESSAGE.format(app=settings().app_name)
        if self._rails is not None:
            try:
                ok, rail = await self._check([{"role": "user", "content": text}], "input")
                return RailResult(ok, rail, "" if ok else msg)
            except Exception as e:  # noqa: BLE001
                log("guardrails_error", error=type(e).__name__)
        ok = self._act_scope(text)
        return RailResult(ok, "" if ok else "kavach scope check", "" if ok else msg)

    async def check_output(self, text: str) -> RailResult:
        if self._rails is not None:
            try:
                ok, rail = await self._check(
                    [{"role": "user", "content": "[reply]"}, {"role": "assistant", "content": text}], "output")
                return RailResult(ok, rail)
            except Exception as e:  # noqa: BLE001
                log("guardrails_error", error=type(e).__name__)
        ok = self._act_output(text)
        return RailResult(ok, "" if ok else "kavach output safety")


_guard: Guard | None = None


def guard() -> Guard:
    global _guard
    if _guard is None:
        _guard = Guard()
    return _guard
