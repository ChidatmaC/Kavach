"""Redaction of codes, PINs, card, account and phone numbers from caller speech.

Runs on every utterance before it leaves the process (agent service, SpacetimeDB, logs).
Stricter than the module's redact(): any run of 4+ digits, spaced/dashed digit groups,
and 4+ spoken digit words ("four eight two nine") are masked. Short numbers such as
"$50" or "300 dollars" are kept because they help describe the scam.
"""
from __future__ import annotations

import re

_DIGIT_WORDS = r"(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|niner|double|triple)"
# 4+ spoken digit words in a row, separated by spaces, commas or dashes.
_SPOKEN_RUN = re.compile(rf"\b{_DIGIT_WORDS}(?:[\s,.-]+{_DIGIT_WORDS}){{3,}}\b", re.IGNORECASE)
# Digit groups separated by spaces/dashes/dots whose digits total 4 or more (e.g. "4 8 2 9", "555-0101").
_DIGIT_GROUPS = re.compile(r"(?<![\w$])\+?\d(?:[\s.\-()]*\d){3,}")
# Single words mixing letters and 4+ digits (e.g. "A1234567").
_ALNUM = re.compile(r"\b(?=[A-Za-z0-9]*\d{4,})[A-Za-z0-9]{5,}\b")

MASK = "[number removed]"


def redact(text: str) -> str:
    if not text:
        return ""
    out = _SPOKEN_RUN.sub(MASK, text)
    out = _ALNUM.sub(MASK, out)
    out = _DIGIT_GROUPS.sub(MASK, out)
    # Collapse repeated masks produced by adjacent patterns.
    out = re.sub(rf"(?:{re.escape(MASK)}[\s,.-]*){{2,}}", MASK + " ", out).strip()
    return out


def contains_sensitive(text: str) -> bool:
    return redact(text) != (text or "").strip()
