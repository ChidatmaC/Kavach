"""Signal extraction and link heuristics (spec 7 `check_link`, 7a step 1)."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from urllib.parse import urlsplit

from .redact import redact

# --- URLs ----------------------------------------------------------------------------

_TLD = r"(?:[a-z]{2,24}|xn--[a-z0-9-]{2,30})"
_URL_RE = re.compile(
    rf"(?i)\b((?:https?://)?(?:[a-z0-9](?:[a-z0-9-]{{0,61}}[a-z0-9])?\.)+{_TLD}(?::\d{{2,5}})?(?:[/?#][^\s<>\"']*)?)",
)
_IP_URL_RE = re.compile(r"(?i)\bhttps?://\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?(?:/[^\s]*)?")
_EMAIL_RE = re.compile(r"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b")
# Words that look like domains but aren't (e.g. "e.g", "a.m").
_NOT_TLDS = {"g", "e", "m", "i", "am", "pm", "st", "dr", "mr", "mrs", "jr", "vs", "etc", "ie", "eg", "ok", "no", "it", "me", "us"}
_KNOWN_TLDS = {
    "com", "org", "net", "gov", "edu", "mil", "us", "uk", "ca", "au", "in", "de", "fr", "io", "co", "info", "biz",
    "top", "xyz", "click", "live", "shop", "icu", "buzz", "rest", "cfd", "sbs", "monster", "zip", "mov", "lol",
    "vip", "cc", "ly", "me", "app", "site", "online", "store", "link", "tk", "ml", "ga", "cf", "gq", "pw", "work",
    "support", "help", "services", "center", "club", "win", "bid", "loan", "today", "life", "world", "pro",
    "gl", "gd", "to", "ws", "tv", "ai", "dev", "page", "cn", "ru", "su", "su",
}
_MULTI_SUFFIX = {"co.uk", "org.uk", "gov.uk", "ac.uk", "com.au", "net.au", "org.au", "co.in", "co.nz", "com.br", "co.jp", "com.mx"}

RISKY_TLDS = {
    "top", "xyz", "click", "live", "shop", "icu", "buzz", "rest", "cfd", "sbs", "monster", "zip", "mov", "lol",
    "vip", "cc", "tk", "ml", "ga", "cf", "gq", "pw", "work", "support", "win", "bid", "loan", "info", "online",
    "site", "store", "link", "help", "services", "today", "life",
}
SHORTENERS = {
    "bit.ly", "tinyurl.com", "t.co", "goo.gl", "is.gd", "ow.ly", "buff.ly", "rebrand.ly", "cutt.ly", "shorturl.at",
    "rb.gy", "tiny.cc", "t.ly", "s.id", "lnkd.in", "bl.ink", "short.io", "v.gd", "qr.co", "trib.al",
}
BRANDS = [
    "usps", "fedex", "ups", "dhl", "amazon", "paypal", "apple", "icloud", "netflix", "chase", "wellsfargo", "bofa",
    "bankofamerica", "citi", "capitalone", "irs", "ssa", "medicare", "txtag", "ntta", "ezpass", "sunpass", "tolls",
    "tmobile", "t-mobile", "verizon", "att", "venmo", "zelle", "cashapp", "coinbase", "microsoft", "google", "walmart",
    "costco", "geeksquad", "norton", "mcafee",
]
OFFICIAL_DOMAINS = {
    "usps.com", "fedex.com", "ups.com", "dhl.com", "amazon.com", "paypal.com", "apple.com", "icloud.com", "netflix.com",
    "chase.com", "wellsfargo.com", "bankofamerica.com", "citi.com", "capitalone.com", "irs.gov", "ssa.gov",
    "medicare.gov", "txtag.org", "ntta.org", "e-zpassny.com", "sunpass.com", "t-mobile.com", "verizon.com", "att.com",
    "venmo.com", "zellepay.com", "cash.app", "coinbase.com", "microsoft.com", "google.com", "walmart.com",
    "costco.com", "ftc.gov", "reportfraud.ftc.gov", "ic3.gov", "consumer.ftc.gov",
}


def _host(url: str) -> str:
    u = url if re.match(r"(?i)^[a-z]+://", url) else f"http://{url}"
    try:
        host = (urlsplit(u).hostname or "").lower()
    except ValueError:
        return ""
    return host[4:] if host.startswith("www.") else host


def registrable_domain(url_or_host: str) -> str:
    host = _host(url_or_host)
    if not host or re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", host):
        return host
    parts = host.split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in _MULTI_SUFFIX:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def normalize_url(url: str) -> str:
    """Lowercase scheme/host, drop www., keep path. Mirrors the module's link normalization for the host."""
    u = url.strip().rstrip(".,;:!?)\"'")
    if not re.match(r"(?i)^[a-z]+://", u):
        u = "http://" + u
    p = urlsplit(u)
    host = (p.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = p.path or ""
    return f"{host}{path}{('?' + p.query) if p.query else ''}"


def extract_urls(text: str) -> list[str]:
    if not text:
        return []
    scrubbed = _EMAIL_RE.sub(" ", text)
    found: list[str] = []
    for m in list(_IP_URL_RE.finditer(scrubbed)) + list(_URL_RE.finditer(scrubbed)):
        raw = m.group(0).rstrip(".,;:!?)\"'")
        host = _host(raw)
        if not host:
            continue
        tld = host.rsplit(".", 1)[-1]
        has_scheme = bool(re.match(r"(?i)^https?://", raw))
        if not has_scheme and (tld in _NOT_TLDS or tld not in _KNOWN_TLDS):
            continue
        if any(raw in f or f in raw for f in found):
            continue
        found.append(raw)
    return found[:10]


# --- phone numbers -------------------------------------------------------------------

_PHONE_RE = re.compile(r"(?<![\w$])(\+?1?[\s.-]?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4})(?!\d)")
_E164_RE = re.compile(r"^\+[1-9]\d{6,14}$")


def to_e164(raw: str) -> str:
    digits = re.sub(r"\D", "", raw or "")
    if raw.strip().startswith("+") and 7 <= len(digits) <= 15:
        return "+" + digits
    if len(digits) == 10:
        return "+1" + digits
    if len(digits) == 11 and digits.startswith("1"):
        return "+" + digits
    return ""


def is_e164(v: str) -> bool:
    return bool(_E164_RE.match(v or ""))


def extract_phones(text: str) -> list[str]:
    out: list[str] = []
    for m in _PHONE_RE.finditer(text or ""):
        e = to_e164(m.group(1))
        if e and e not in out:
            out.append(e)
    return out[:5]


# --- claimed identity and tactics ------------------------------------------------------

_IDENTITY_PATTERNS = [
    re.compile(r"(?i)\b(?:this is|we are|i am|i'm|it's|its|calling from|from the|from your)\s+(?:the\s+|your\s+)?([A-Z][\w&.-]*(?:\s+[A-Z][\w&.-]*){0,3}(?:\s+(?:department|team|unit|bank|support|services?))?)"),
    re.compile(r"^\s*([A-Z][A-Za-z&.-]{1,20}(?:\s+[A-Z][A-Za-z&.-]{1,20}){0,2})\s*:"),
]
_IDENTITY_WORDS = {
    "grandson": "grandson", "granddaughter": "granddaughter", "grandchild": "grandchild", "grandkid": "grandchild",
    "fraud department": "fraud department", "fraud team": "fraud department", "irs": "IRS", "social security": "Social Security",
    "medicare": "Medicare", "bank": "your bank", "police": "police", "sheriff": "police", "recruiter": "recruiter",
    "tech support": "tech support", "microsoft": "Microsoft", "apple support": "Apple support", "amazon": "Amazon",
    "usps": "USPS", "fedex": "FedEx", "ups": "UPS", "txtag": "TxTag", "ntta": "NTTA", "toll": "toll agency",
    "carrier": "phone carrier", "t-mobile": "T-Mobile", "verizon": "Verizon", "at&t": "AT&T",
    "fund recovery": "Fund Recovery Unit", "new number": "family member",
}


def claimed_identity(text: str) -> str:
    if not text:
        return ""
    for pat in _IDENTITY_PATTERNS:
        m = pat.search(text)
        if m:
            cand = m.group(1).strip(" .,:")
            if 2 <= len(cand) <= 60 and cand.lower() not in {"me", "i", "it", "you", "hi", "hey", "hello"}:
                return redact(cand)[:60]
    low = text.lower()
    for word, label in _IDENTITY_WORDS.items():
        if re.search(rf"\b{re.escape(word)}\b", low):
            return label
    return ""


TACTIC_PATTERNS: dict[str, re.Pattern[str]] = {
    "urgency": re.compile(r"(?i)\b(urgent|immediately|right away|right now|today|tonight|within \d+ ?(hours?|minutes?)|asap|act now|final notice|last chance|expires?|hurry)\b"),
    "fee_threat": re.compile(r"(?i)\b(late fee|penalt(y|ies)|fine|suspend(ed)?|lock(ed)?|clos(e|ed|ure)|avoid (a|extra|additional)|outstanding|unpaid|overdue|balance due)\b"),
    "payment_link": re.compile(r"(?i)\b(pay (now|here|today|online|at)|click (here|the link|below)|tap (here|the link)|visit|follow the link|update (your )?(payment|billing))\b"),
    "code_request": re.compile(r"(?i)\b(code|otp|passcode|verification number|pin)\b.{0,40}\b(read|send|tell|give|share|confirm|verify|text)\b|\b(read|send|tell|give|share|confirm)\b.{0,30}\b(code|otp|passcode|pin)\b"),
    "gift_card_request": re.compile(r"(?i)\b(gift ?cards?|itunes|google play|steam card|apple card balance|ebay card)\b"),
    "secrecy": re.compile(r"(?i)\b(don'?t tell|do not tell|keep (this|it) (a )?secret|between us|don'?t let .{1,20} know|not tell (mom|dad|anyone))\b"),
    "impersonation": re.compile(r"(?i)\b(this is (your|the)|it'?s me|i'?m (your|from)|we are (the|from)|calling from|on behalf of|fraud (department|team)|support team)\b"),
    "new_number": re.compile(r"(?i)\b(new (phone )?number|changed my number|lost my phone|phone (broke|is broken)|save this (one|number))\b"),
    "recovery_offer": re.compile(r"(?i)\b(recover(ed|y)?|refund|reclaim|located the (money|funds)|lost (money|funds)|release (fee|your))\b"),
    "upfront_fee": re.compile(r"(?i)\b(processing fee|release fee|small fee|upfront|deposit|activation fee|transfer fee)\b"),
    "job_offer": re.compile(r"(?i)\b(recruit(er|ing)|remote (job|role|position|work)|part[- ]time|per day|\$\d+ ?(/|a|per) ?(day|hour)|hiring)\b"),
    "prize": re.compile(r"(?i)\b(you('ve| have)? won|winner|prize|lottery|sweepstakes|claim your (reward|prize))\b"),
    "remote_access": re.compile(r"(?i)\b(anydesk|teamviewer|remote access|install (this|the) app|screen ?share)\b"),
    "money_request": re.compile(r"(?i)\b(send (me |us |him |her |them )?(all |some )?(of )?(your |the |my )?(money|cash|funds|savings)|(transfer|move|wire) (the |your |all )?(money|funds|savings)|wire|bail|zelle|venmo|cash ?app|paypal me|bitcoin|crypto|western union|moneygram|need \$?\d+|lend me|loan me|pay (a|the|my) bill|pay (us|me|him|her)|you owe|pay (today|now|immediately|right away|the fine|the fee|back taxes|what you owe))\b"),
    "legal_threat": re.compile(r"(?i)\b(arrest(ed)?|warrant|lawsuit|sue you|deport(ed|ation)?|jail time|suspend(ed)? your (social|ssn|license)|legal action)\b"),
    # Named banks, agencies and companies scammers impersonate, when the message claims to be them.
    "org_impersonation": re.compile(r"(?i)\b(this is|we are|we're|i am|i'?m|calling from|from|on behalf of|representing)\s+(the\s+|your\s+)?(bank of america|chase|wells fargo|citi(bank)?|capital one|us bank|pnc|td bank|navy federal|your bank|the bank|irs|internal revenue|social security|ssa|medicare|amazon|apple( support)?|microsoft|paypal|venmo|zelle|usps|fedex|ups|dmv|police|sheriff|fbi|the government|customs|t-mobile|verizon|at&t|geek squad|norton|mcafee)\b"),
    # A relative or friend in trouble who needs help now (the grandparent / family-emergency scam).
    "family_emergency": re.compile(r"(?i)\b(grand(son|daughter|child|ma|pa|mother|father)|nephew|niece|son|daughter|cousin|mom|dad|brother|sister|friend)\b.{0,80}\b(emergency|jail|arrested|bail|hospital|accident|stuck|stranded|in trouble|lawyer|stolen wallet)\b|\b(emergency|jail|arrested|bail|hospital|accident|stranded|in trouble)\b.{0,80}\b(grand(son|daughter|child)|nephew|niece|son|daughter)\b"),
}

# Asking someone to buy/send/read gift cards, as opposed to merely mentioning one.
_GIFT_CARD_ASK = re.compile(r"(?i)\b(buy|get|send|purchase|pick up|grab|scratch|read|text|photo|picture|pay (with|in|using))\b.{0,40}\b(gift ?cards?|itunes|google play|apple cards?|steam cards?|ebay cards?)\b|\b(gift ?cards?|itunes|google play|steam cards?)\b.{0,40}\b(numbers?|codes?|pins?|back of)\b")
_MONEY_PRESSURE = {"org_impersonation", "impersonation", "urgency", "secrecy", "new_number", "family_emergency",
                   "upfront_fee", "fee_threat", "legal_threat"}


def risk_floor(tactics: list[str], text: str) -> tuple[str, str]:
    """Rule-based minimum verdict from red-flag tactics, returned as (floor, why). Like the community
    floor (D14), a model may raise a verdict above it but never lower it: requests for gift cards,
    codes or remote access, and money requests under pressure or impersonation, are never "safe"."""
    t = set(tactics)
    if "gift_card_request" in t and _GIFT_CARD_ASK.search(text or ""):
        return "likely_scam", "gift_cards"
    if "code_request" in t:
        return "likely_scam", "code"
    if "remote_access" in t:
        return "likely_scam", "remote_access"
    if "money_request" in t and t & _MONEY_PRESSURE:
        return "likely_scam", "money_pressure"
    if "recovery_offer" in t and "upfront_fee" in t:
        return "likely_scam", "recovery_fee"
    if t & {"money_request", "org_impersonation", "family_emergency", "new_number",
             "upfront_fee", "prize"}:
        return "suspicious", "money_or_impersonation"
    return "safe", ""


def tactics_of(text: str) -> list[str]:
    if not text:
        return []
    return [name for name, pat in TACTIC_PATTERNS.items() if pat.search(text)]


# --- check_link ------------------------------------------------------------------------

_LOOKALIKE_MAP = str.maketrans({"0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"})


def _edit_distance(a: str, b: str, cap: int = 3) -> int:
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass
class LinkCheck:
    url: str
    domain: str
    risk: str  # low | medium | high
    flags: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {"url": self.url, "domain": self.domain, "risk": self.risk, "flags": self.flags}


def check_link(url: str) -> LinkCheck:
    """Heuristics: risky endings, brand word plus hyphen, lookalike spelling, shorteners (spec 7 tools table)."""
    host = _host(url)
    domain = registrable_domain(url)
    flags: list[str] = []
    if not host:
        return LinkCheck(url, "", "medium", ["unparseable"])
    if domain in OFFICIAL_DOMAINS or host in OFFICIAL_DOMAINS:
        return LinkCheck(url, domain, "low", ["official_domain"])
    tld = host.rsplit(".", 1)[-1]
    label = domain.split(".")[0]
    if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", host):
        flags.append("ip_address")
    if tld in RISKY_TLDS:
        flags.append("risky_ending")
    if domain in SHORTENERS or host in SHORTENERS:
        flags.append("url_shortener")
    if "xn--" in host:
        flags.append("punycode")
    if "@" in url.split("//", 1)[-1].split("/", 1)[0]:
        flags.append("userinfo_trick")
    if host.count(".") >= 4:
        flags.append("many_subdomains")
    host_words = re.split(r"[.-]", host)
    for brand in BRANDS:
        b = brand.replace("-", "")
        if "-" in host and any(w == b for w in host_words) or (("-" in label) and b in label.replace("-", "")):
            flags.append("brand_hyphen")
            break
    if "brand_hyphen" not in flags:
        normalized = label.translate(_LOOKALIKE_MAP).replace("rn", "m").replace("vv", "w")
        for brand in BRANDS:
            b = brand.replace("-", "")
            if len(b) < 4 or label == b:
                continue
            if normalized == b or (b in normalized and normalized != b and len(normalized) - len(b) <= 8):
                flags.append("lookalike_spelling" if normalized == b else "brand_in_domain")
                break
            if _edit_distance(label, b) == 1 and len(b) >= 5:
                flags.append("lookalike_spelling")
                break
    strong = {"brand_hyphen", "lookalike_spelling", "punycode", "ip_address", "userinfo_trick"}
    if any(f in strong for f in flags) or (("risky_ending" in flags) and len(flags) >= 2):
        risk = "high"
    elif flags:
        risk = "medium"
    else:
        risk = "low"
    return LinkCheck(url, domain, risk, flags)


@dataclass
class Signals:
    sender_e164: str
    urls: list[str]
    normalized_urls: list[str]
    domains: list[str]
    phones_in_text: list[str]
    claimed_identity: str
    tactics: list[str]
    text_redacted: str


def extract_signals(text: str, sender_e164: str = "") -> Signals:
    urls = extract_urls(text)
    domains: list[str] = []
    for u in urls:
        d = registrable_domain(u)
        if d and d not in domains:
            domains.append(d)
    return Signals(
        sender_e164=sender_e164 if is_e164(sender_e164) else to_e164(sender_e164) if sender_e164 else "",
        urls=urls,
        normalized_urls=[normalize_url(u) for u in urls],
        domains=domains[:5],
        phones_in_text=extract_phones(text),
        claimed_identity=claimed_identity(text),
        tactics=tactics_of(text),
        text_redacted=redact(text),
    )
