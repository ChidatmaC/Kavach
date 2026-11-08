"""Text similarity for community search (spec 7a step 3).

Primary: NIM embeddings (`MODEL_EMBED`), cached in memory. Fallback when there is no key or the
call fails: a pure-Python lexical scorer, the mean of a word TF-IDF cosine (after mapping common
scam vocabulary onto shared concepts, so paraphrases meet) and a character 3-5-gram cosine.
The two methods live on different scales, so each has its own thresholds (see THRESHOLDS).
"""
from __future__ import annotations

import math
import re
from collections import Counter

from .config import settings
from .log import log

# Per method: min score to count as evidence, and score at which the floor becomes "suspicious".
# Embedding floor follows spec 7a (0.85). Lexical floor was tuned on the seeded corpus so that
# paraphrases of a campaign clear it and unrelated texts don't (tests/test_search.py).
THRESHOLDS = {
    "embedding": {"evidence": 0.55, "floor": 0.85},
    "lexical": {"evidence": 0.20, "floor": 0.35},
}

_STOP = set(
    "a an the and or but if then so to of in on at for from by with is are was were be been being it its this that "
    "these those i me my we our you your he him his she her they them their there here what which who whom when where "
    "why how can could would should will just do does did done have has had not no yes please hi hey hello up out "
    "get got as about into over than too very now".split()
)

# Concept normalization: different words scammers use for the same thing map to one token.
_CONCEPTS: list[tuple[str, str]] = [
    (r"grand(son|daughter|child|kid|kids|children|ma|pa|mother|father|dad|mom)s?|nana|papa", "CKIN"),
    (r"jail|arrest(ed)?|bail|police|custody|lockup|cops?|lawyer|attorney|court", "CARREST"),
    (r"gift ?cards?|itunes|google ?play|steam|apple ?cards?", "CGIFTCARD"),
    (r"tolls?|tollway|txtag|ntta|ezpass|e-zpass|sunpass|fastrak|turnpike", "CTOLL"),
    (r"fees?|charges?|penalt(y|ies)|fines?|surcharge", "CFEE"),
    (r"codes?|otp|passcodes?|pins?|one[- ]time", "CCODE"),
    (r"refunds?|recover(y|ed|ing)?|reclaim(ed)?|retriev(e|ed|al)|restitution|compensation", "CRECOVER"),
    (r"jobs?|recruit(er|ing|ment)?|hiring|positions?|roles?|vacanc(y|ies)|employment|gig", "CJOB"),
    (r"remote|part[- ]?time|from home|online work", "CREMOTE"),
    (r"unpaid|outstanding|overdue|owe[sd]?|balance|debt|due", "CUNPAID"),
    (r"pay(ment|ing)?|settle|remit", "CPAY"),
    (r"carrier|t-?mobile|verizon|at&?t|sim|port(ing)?[- ]?out", "CCARRIER"),
    (r"fraud|suspicious|unauthori[sz]ed|security (team|department)", "CFRAUD"),
    (r"secret|don'?t tell|do not tell|between us", "CSECRET"),
    (r"money|cash|funds|dollars|\$\d[\d,.]*", "CMONEY"),
    (r"new (phone )?number|changed (my )?number|phone (broke|broken|died)|lost (my )?phone", "CNEWNUM"),
    (r"urgent(ly)?|immediately|tonight|today|asap|right (now|away)|hurry|24 hours", "CURGENT"),
    (r"links?|https?://\S+|click|tap", "CLINK"),
]
_CONCEPT_RES = [(re.compile(rf"(?i)\b(?:{p})\b"), tok) for p, tok in _CONCEPTS]


def _concepts(text: str) -> str:
    t = text
    for rx, tok in _CONCEPT_RES:
        t = rx.sub(f" {tok} ", t)
    return t


def _stem(w: str) -> str:
    for suf in ("ing", "ed", "es", "s"):
        if len(w) > 4 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def word_tokens(text: str) -> list[str]:
    t = _concepts(text or "")
    toks = re.findall(r"[A-Za-z][A-Za-z']+|C[A-Z]+", t)
    out = []
    for w in toks:
        if w.isupper() and w.startswith("C") and len(w) > 2:
            out.append(w)
            continue
        lw = w.lower()
        if lw in _STOP or len(lw) < 3:
            continue
        out.append(_stem(lw))
    return out


def char_ngrams(text: str, lo: int = 3, hi: int = 5) -> Counter:
    t = re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", (text or "").lower())).strip()
    c: Counter = Counter()
    for n in range(lo, hi + 1):
        for i in range(max(0, len(t) - n + 1)):
            c[t[i : i + n]] += 1
    return c


def _cos(a: Counter | dict, b: Counter | dict) -> float:
    if not a or not b:
        return 0.0
    dot = sum(v * b.get(k, 0.0) for k, v in a.items())
    na = math.sqrt(sum(v * v for v in a.values()))
    nb = math.sqrt(sum(v * v for v in b.values()))
    return dot / (na * nb) if na and nb else 0.0


def lexical_scores(query: str, docs: list[str]) -> list[float]:
    """Mean of concept-normalized word TF-IDF cosine and char n-gram cosine."""
    if not docs:
        return []
    doc_toks = [word_tokens(d) for d in docs]
    q_toks = word_tokens(query)
    n = len(docs) + 1
    df: Counter = Counter()
    for toks in doc_toks + [q_toks]:
        df.update(set(toks))
    idf = {t: math.log((n + 1) / (c + 1)) + 1.0 for t, c in df.items()}

    def tfidf(toks: list[str]) -> dict[str, float]:
        tf = Counter(toks)
        return {t: (1 + math.log(c)) * idf[t] for t, c in tf.items()}

    qv = tfidf(q_toks)
    qc = char_ngrams(query)
    return [0.5 * _cos(qv, tfidf(dt)) + 0.5 * _cos(qc, char_ngrams(d)) for d, dt in zip(docs, doc_toks)]


# --- embeddings ---------------------------------------------------------------------------

_embed_cache: dict[tuple[str, str], list[float]] = {}


async def _embed(texts: list[str], input_type: str) -> list[list[float]]:
    from openai import AsyncOpenAI

    s = settings()
    missing = [t for t in texts if (input_type, t) not in _embed_cache]
    if missing:
        client = AsyncOpenAI(api_key=s.nim_api_key, base_url=s.nim_base_url, timeout=6.0, max_retries=0)
        res = await client.embeddings.create(
            model=s.model_embed, input=missing, encoding_format="float",
            extra_body={"input_type": input_type, "truncate": "END"},
        )
        for t, d in zip(missing, res.data):
            _embed_cache[(input_type, t)] = d.embedding
    return [_embed_cache[(input_type, t)] for t in texts]


def _dense_cos(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


async def score(query: str, docs: list[str]) -> tuple[str, list[float]]:
    """Returns (method, scores). Embeddings when a NIM key is set, else (or on error) lexical."""
    if not docs:
        return "lexical", []
    if settings().llm_enabled:
        try:
            qv = (await _embed([query], "query"))[0]
            dv = await _embed(docs, "passage")
            return "embedding", [_dense_cos(qv, d) for d in dv]
        except Exception as e:  # noqa: BLE001 - any provider failure falls back
            log("embed_fallback", error=type(e).__name__)
    return "lexical", lexical_scores(query, docs)
