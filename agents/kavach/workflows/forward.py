"""Telling a forwarded message apart from the person's own words (CONTRACTS section 7, "Forwarded messages").

Native iMessage forwarding adds no metadata, so a forward is marked by a wrapper the person (or the Kavach
app) adds:

    Forwarded message:
    From: +1 555 555 0144        (optional, the app adds it when it knows the sender)
    "<the message they received>"

`parse_wrapper` strips the marker, the optional `From:` line and the quotes. `classify_unwrapped` scores a
text with no wrapper: deterministic signals decide, `None` means "let the model break the tie".
`PendingStore` remembers, per person, a bare marker ("Fwd:" = the next text is the forward), recent
forwards (extra bubbles a few seconds later), a text we asked about ("1 received / 2 my question"), and
when we last taught the wrapper.
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from typing import Any

from ..signals import extract_urls, to_e164
from .command import looks_like_command

CLARIFY_QUESTION = ("Is this a message you received, or a question for me? "
                    "Reply 1 if you received it, 2 if it's your question.")
WRAPPER_TIP = 'Tip: start a forwarded text with "Forwarded message:" so I know it\'s something you received.'

BARE_MARKER_TTL_S = 120  # "Fwd:" alone: the next text within 2 minutes is the forwarded one
PENDING_TTL_S = 600  # an ambiguous text waits 10 minutes for "1" or "2"
BUBBLE_WINDOW_S = 10  # extra bubbles of a forward arrive within a few seconds
TIP_EVERY_S = 24 * 3600

# Leading markers, longest first. A marker must be followed by a separator (":", "?", "-", a newline, an
# opening quote) or the end of the text, so "Check this out" or "Is this a scam if..." are not wrappers.
_MARKERS = [
    r"forwarded\s+message", r"forwarded", r"fwd", r"fw", r"check\s+this\s+message", r"check\s+this",
    r"is\s+this\s+a\s+scam", r"scam",
]
_QUOTES_OPEN = "\"'“‘«„"
_QUOTES_CLOSE = "\"'”’»“"
_MARKER_RE = re.compile(
    r"^\s*[\[(<-]*\s*(?:" + "|".join(_MARKERS) + r")\s*[\])>]*"
    r"(?P<sep>\s*[:?\-–—]+|\s*(?=\n)|\s*(?=[" + _QUOTES_OPEN + r"])|\s*$)",
    re.IGNORECASE,
)
_FROM_RE = re.compile(r"^\s*from\s*:\s*(?P<who>.{1,80}?)\s*$", re.IGNORECASE)


@dataclass
class Wrapped:
    inner: str  # the forwarded message only ("" for a bare marker)
    sender_e164: str = ""
    sender_name: str = ""

    @property
    def bare(self) -> bool:
        return not self.inner


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] in _QUOTES_OPEN and s[-1] in _QUOTES_CLOSE:
        return s[1:-1].strip()
    if s and s[0] in _QUOTES_OPEN and not any(c in s[1:] for c in _QUOTES_CLOSE):
        return s[1:].strip()  # opening quote only (cut off)
    return s


def parse_wrapper(text: str) -> Wrapped | None:
    """The forwarded message inside a wrapper, or None when the text has no leading marker."""
    m = _MARKER_RE.match(text or "")
    if not m:
        return None
    rest = (text or "")[m.end():]
    sender_e164, sender_name = "", ""
    lines = rest.split("\n")
    # Skip blank lines, then an optional "From: <name or number>" line.
    while lines and not lines[0].strip():
        lines.pop(0)
    if lines:
        fm = _FROM_RE.match(lines[0])
        if fm:
            who = fm.group("who").strip().strip(_QUOTES_OPEN + _QUOTES_CLOSE)
            phone = to_e164(who) if re.fullmatch(r"[+\d\s().\-]{7,24}", who) else ""
            if phone:
                sender_e164 = phone
            else:
                sender_name = who[:60]
            lines.pop(0)
    inner = _strip_quotes("\n".join(lines))
    return Wrapped(inner=inner, sender_e164=sender_e164, sender_name=sender_name)


# --- unwrapped texts: whose words are these? ---------------------------------------------------

# Someone else's message: a company or agency alert, a link, a greeting addressed to them plus a request,
# a sign-off with another person's name, a verification code.
_COMPANY_PREFIX = re.compile(r"^\s*\[?(?P<name>[A-Z][A-Za-z0-9&.'\- ]{1,24})\]?\s*:\s+\S")
_NOT_A_SENDER = {"question", "q", "help", "hi", "hey", "hello", "note", "update", "fyi", "ps", "re", "also",
                 "ok", "okay", "yes", "no", "so", "well", "quick question", "hmm", "um", "wait", "btw", "important"}
_ALERT = re.compile(
    r"(?i)\byour\s+(?:\w+\s+){0,2}(?:account|card|package|parcel|order|subscription|payment|apple id|icloud|password|"
    r"benefits?|refund|toll|delivery|shipment|device|computer|loan|tax(?:es)?|social security)\b.{0,50}?\b(?:has been|"
    r"have been|was|were|is|are|will be|could not|couldn'?t|needs?|requires?)\b"
    r"|\breply\s+(?:stop|yes|y|no|1|2)\b|\bto\s+opt[\s-]?out\b|\bmsg\s*(?:&|and)\s*data\b"
    r"|\bdear\s+(?:customer|user|member|client|sir|madam|valued)\b|\b(?:click|tap)\s+(?:here|the link|below|to)\b"
    r"|\b(?:call|contact)\s+us\b|\bfinal\s+(?:notice|warning|reminder)\b|\byou(?:'ve| have)\s+(?:won|been selected|"
    r"been chosen|been approved)\b|\bcongratulations\b|\bact\s+now\b|\bwithin\s+\d+\s+(?:hours?|hrs?|days?|minutes?)\b"
    r"|\b(?:verify|confirm|update|validate|unlock)\s+your\s+(?:account|identity|information|info|details|address|"
    r"payment|card|billing)\b|\b(?:unpaid|outstanding)\s+(?:toll|balance|invoice|bill|fee)\b"
    r"|\bpackage\s+(?:is\s+)?(?:on hold|could not|cannot|was not|undeliverable)\b|\bsuspicious\s+(?:activity|login|sign)"
    r"|^\s*this is (?:the )?(?:irs|ssa|social security|medicare|fbi|police|sheriff|\w+ (?:bank|support|security|fraud))\b"
    r"|\byou owe\b|\bdon'?t tell (?:mom|dad|mum|anyone|anybody|the family|my parents)\b"
)
_FAMILY = r"(?:grandpa|grandma|grandmother|grandfather|granny|nana|nan|papa|pops|mom|mum|mama|mommy|dad|daddy|" \
          r"auntie|aunt|uncle|sis|bro|son|sweetie|honey|dear|friend|sir|madam|ma'?am)"
_GREETING = re.compile(rf"(?i)^\s*(?:hi|hello|hey|hiya|dear|good (?:morning|afternoon|evening))\b[\s,!]*(?:{_FAMILY}|[A-Z][a-z]+)?\b")
_KIN_GREETING = re.compile(rf"(?i)^\s*(?:hi|hello|hey|dear)\s*,?\s*{_FAMILY}\b")
_VOCATIVE = re.compile(rf"(?i)^\s*{_FAMILY}\b[\s,!]")
_ITS_ME = re.compile(r"(?i)\b(?:it'?s|its|this is)\s+(?:me|your\s+\w+)\b")
_REQUEST = re.compile(r"(?i)\b(?:need|send|wire|transfer|help|money|cash|gift\s*cards?|bail|lawyer|pay|loan|"
                      r"don'?t tell|call me|text me|reply)\b")
_SIGN_OFF = re.compile(
    r"(?:^|\n|[.!?]\s*)(?:[-–—~]\s*|(?:(?i:love|thanks|thank you|regards|sincerely|cheers|xoxo|best|warmly|"
    r"yours))[,!.]?\s+)[A-Z][a-z]{1,15}(?:\s+[A-Z][a-z]{1,15})?\s*[.!]?\s*$")
_CODE = re.compile(r"(?i)\b(?:code|otp|passcode|pin|verification)\b[^\n]{0,40}?\b\d{4,8}\b|\b\d{4,8}\b[^\n]{0,30}?"
                   r"\b(?:is your|verification|code)\b|\b(?:do not|don'?t|never) share (?:this|the|your) code\b")
_SECOND_PERSON_DEMAND = re.compile(r"(?i)\b(?:send|wire|transfer|venmo|zelle|cash\s*app) me\b|\bi need you to\b")

# Their own voice: a question or request for Kavach, something they did, a situation they describe.
_STRONG_ASK = re.compile(
    r"(?i)\b(?:should i|shall i|can i|could i|do i|did i|have i|am i|is it (?:safe|ok|okay|normal|legit|smart|wise)|"
    r"is (?:this|that|he|she|it|they) (?:a scam|legit|real|safe|a real)|are (?:they|these|those) (?:legit|real|safe)|"
    r"what (?:should|do|can) i|how (?:do|can|should) i|do you think|would you|can you|could you|will you|"
    r"tell me|help me (?:understand|figure|decide|check)|i (?:want|need) (?:to know|advice|help)|"
    r"(?:asked|wants|want|told|asking) me to|i met (?:someone|a|this)|"
    r"(?:he|she|they|someone|somebody|a man|a woman|a guy|a lady|my \w+) (?:wants|asked|is asking|keeps asking|called|"
    r"texted|emailed|messaged|says|said|told me))\b"
)
_FIRST_PERSON = re.compile(r"(?i)\b(?:i|i'm|im|i've|i'd|i'll|my|me|mine|we|our)\b")
_PLEASANTRY = re.compile(r"(?i)^\s*(?:thanks?|thank you|thx|ty|ok|okay|k|cool|great|good|got it|hi|hello|hey|"
                         r"good (?:morning|afternoon|evening|night)|bye|goodbye|yes|no|yep|nope|sure)\b[\s.!,]*$")


def forward_signals(text: str) -> list[str]:
    """Deterministic signs the text was written by someone else to the person."""
    t = text or ""
    out = []
    m = _COMPANY_PREFIX.match(t)
    if m and m.group("name").strip().lower() not in _NOT_A_SENDER:
        out.append("company_prefix")
    if _ALERT.search(t):
        out.append("alert")
    if extract_urls(t):
        out.append("link")
    if _KIN_GREETING.search(t) or (_GREETING.search(t) and _ITS_ME.search(t)) or \
            (_VOCATIVE.search(t) and _REQUEST.search(t)):
        out.append("greeting")
    if _ITS_ME.search(t) and _REQUEST.search(t):
        out.append("its_me")
    if _SIGN_OFF.search(t.strip()):
        out.append("sign_off")
    if _CODE.search(t):
        out.append("code")
    if _SECOND_PERSON_DEMAND.search(t):
        out.append("demand")
    return list(dict.fromkeys(out))


def own_voice(text: str) -> tuple[str, dict[str, Any]] | None:
    """The person talking to Kavach: (intent, extra), or None when nothing marks it as their own words."""
    from .router import _ALREADY_SHARED, _NARRATIVE, _VERIFY_FREE  # avoid an import cycle

    t = text or ""
    if looks_like_command(t):
        return "command", {}
    m = _VERIFY_FREE.search(t)
    if m and len(t) < 120:
        return "verify_relative", {"relative_name": m.group(1).title()}
    if _ALREADY_SHARED.search(t):
        return "interview", {}
    if _STRONG_ASK.search(t):
        return "advise", {}
    if _NARRATIVE.search(t):
        return "interview", {}
    if re.search(r"\?\s*$", t) and _FIRST_PERSON.search(t):
        return "advise", {}
    return None


@dataclass
class Classified:
    intent: str | None  # None: ask the model
    extra: dict[str, Any] = field(default_factory=dict)
    forward: list[str] = field(default_factory=list)
    own: str = ""


def classify_unwrapped(text: str) -> Classified:
    """Deterministic routing of an unwrapped text. Someone else's words need a forward signal and no strong
    sign of their own voice. intent="clarify" means ask; None means both or neither: the model decides."""
    fwd = forward_signals(text)
    own = own_voice(text)
    if fwd and not own:
        return Classified("scam_check", {}, fwd)
    if own and not fwd:
        return Classified(own[0], own[1], fwd, own[0])
    if own and fwd:
        if own[0] == "command" and "link" not in fwd:
            return Classified("command", own[1], fwd, "command")
        return Classified(None, {}, fwd, own[0])  # e.g. "is this real? USPS: your package..." - the model decides
    if _PLEASANTRY.match(text or ""):
        return Classified("advise", {}, [], "pleasantry")
    return Classified(None)


def no_signal_fallback(text: str) -> str:
    """Neither signal and no usable model answer."""
    return "advise" if _FIRST_PERSON.search(text or "") and len((text or "").split()) > 3 else "clarify"


def tie_fallback(c: Classified) -> str:
    """Both signals and no usable model answer: a link gets checked, otherwise answer them."""
    return "scam_check" if "link" in c.forward else (c.own or "advise")


_RECEIVED = re.compile(r"(?i)^\s*(?:1|one|#1|option 1|received|i received it|i got it|got it|message|a message|"
                       r"it'?s a message|someone sent (?:it|this|that|me)(?: to me)?|they sent (?:it|this|that)(?: to me)?|"
                       r"someone else'?s|someone else)\s*[.!)]*\s*$")
_QUESTION = re.compile(r"(?i)^\s*(?:2|two|#2|option 2|question|a question|my question|mine|it'?s mine|"
                       r"it'?s my question|it'?s me|me|my own|i wrote it|i'?m asking)\s*[.!)]*\s*$")


def parse_clarify_answer(text: str) -> str | None:
    """'received', 'question' or None."""
    if _RECEIVED.match(text or ""):
        return "received"
    if _QUESTION.match(text or ""):
        return "question"
    return None


# --- per-person state (in this process; photon stays stateless) --------------------------------

@dataclass
class _Entry:
    expect_forward_until: float = 0.0  # bare marker
    last_forward_at: float = 0.0  # a wrapped forward, for extra bubbles
    pending_text: str = ""
    pending_until: float = 0.0
    tip_at: float = 0.0


class PendingStore:
    def __init__(self, clock=time.time):
        self._d: dict[str, _Entry] = {}
        self._clock = clock

    def _e(self, key: str) -> _Entry:
        if len(self._d) > 5000:  # bounded: drop the oldest half
            for k in list(self._d)[:2500]:
                del self._d[k]
        return self._d.setdefault(key, _Entry())

    def now(self) -> float:
        return self._clock()

    def expect_forward(self, key: str) -> None:
        self._e(key).expect_forward_until = self.now() + BARE_MARKER_TTL_S

    def take_expected_forward(self, key: str) -> bool:
        e = self._d.get(key)
        if e and e.expect_forward_until > self.now():
            e.expect_forward_until = 0.0
            return True
        return False

    def saw_forward(self, key: str) -> None:
        self._e(key).last_forward_at = self.now()

    def end_bubbles(self, key: str) -> None:
        """They sent something that isn't part of the forward: later texts are routed on their own."""
        e = self._d.get(key)
        if e:
            e.last_forward_at = 0.0

    def in_bubble_window(self, key: str) -> bool:
        e = self._d.get(key)
        return bool(e and e.last_forward_at and self.now() - e.last_forward_at <= BUBBLE_WINDOW_S)

    def set_pending(self, key: str, text: str) -> None:
        e = self._e(key)
        e.pending_text, e.pending_until = text, self.now() + PENDING_TTL_S

    def peek_pending(self, key: str) -> str:
        e = self._d.get(key)
        return e.pending_text if e and e.pending_until > self.now() else ""

    def clear_pending(self, key: str) -> None:
        e = self._d.get(key)
        if e:
            e.pending_text, e.pending_until = "", 0.0

    def tip_due(self, key: str) -> bool:
        """True at most once a day per person; marks the tip as sent."""
        e = self._e(key)
        if e.tip_at and self.now() - e.tip_at < TIP_EVERY_S:
            return False
        e.tip_at = self.now()
        return True

    def clear(self) -> None:
        self._d.clear()


STATE = PendingStore()
