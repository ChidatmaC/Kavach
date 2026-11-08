"""Redaction: mask codes, card numbers and account numbers before anything is stored (spec 7, 12).

Mirrors `redact()` in spacetime/src/lib.ts so the agent never sends unredacted text to a reducer.
"""
from __future__ import annotations

import re

_CARD = re.compile(r"(?<!\+)\b(?:\d[ -]?){13,19}\b")
_ACCOUNT = re.compile(r"(?<!\+)\b\d{9,12}\b")  # E.164 phone numbers stay readable
_CODE = re.compile(r"(?<![+\d$.,])\b\d{4,8}\b(?![.,]\d)")
_SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
# "code is 4 8 2 9 1 3" / "PIN: 1-2-3-4"
_SPACED_CODE = re.compile(r"(?i)\b(code|pin|otp|passcode|password)\b(\s*(?:is|:|=)?\s*)((?:\d[\s-]?){4,8})")
_PASSWORD_VALUE = re.compile(r"(?i)\b(password|passcode)\b(\s*(?:is|:|=)\s*)(\S+)")


def redact(text: str) -> str:
    if not text:
        return ""
    t = _SSN.sub("[ssn]", text)
    t = _CARD.sub("[card number]", t)
    t = _ACCOUNT.sub("[account number]", t)
    t = _SPACED_CODE.sub(lambda m: f"{m.group(1)}{m.group(2)}[code]", t)
    t = _PASSWORD_VALUE.sub(lambda m: f"{m.group(1)}{m.group(2)}[password]", t)
    t = _CODE.sub("[code]", t)
    return t[:2000]
