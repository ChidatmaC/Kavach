"""APNs delivery for `push` outbox rows: HTTP/2 + ES256 provider JWT (token-based auth)."""
from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import httpx
import jwt

from .config import settings
from .log import log
from .stdb import Stdb, q

_jwt_cache: tuple[float, str] | None = None


def _key_pem() -> str:
    raw = settings().apns_key_p8.strip()
    if not raw:
        return ""
    if "BEGIN PRIVATE KEY" not in raw and Path(raw).expanduser().exists():
        return Path(raw).expanduser().read_text()
    return raw.replace("\\n", "\n")


def provider_token() -> str:
    """JWT valid for up to an hour; Apple asks providers to refresh at most every 20 minutes."""
    global _jwt_cache
    now = time.time()
    if _jwt_cache and now - _jwt_cache[0] < 40 * 60:
        return _jwt_cache[1]
    s = settings()
    tok = jwt.encode({"iss": s.apns_team_id, "iat": int(now)}, _key_pem(), algorithm="ES256",
                     headers={"kid": s.apns_key_id})
    _jwt_cache = (now, tok)
    return tok


def configured() -> bool:
    s = settings()
    return bool(s.apns_key_id and s.apns_team_id and s.apns_topic and _key_pem())


async def resolve_verification_id(db: Stdb, to_e164: str) -> int:
    """Outbox rows carry no verification id: find the newest pending trusted_sender check for this relative."""
    contacts = await db.sql(f"SELECT * FROM svc_contact WHERE phone_e164 = {q(to_e164)}")
    ids = {int(c["id"]) for c in contacts}
    if not ids:
        return 0
    rows = await db.sql("SELECT * FROM svc_verification WHERE status = 'pending'")
    mine = [v for v in rows if int(v["contact_id"]) in ids and v.get("kind") == "trusted_sender"]
    return max((int(v["id"]) for v in mine), default=0)


async def send_push(db: Stdb, body: dict[str, Any]) -> dict[str, Any]:
    to = body.get("to_e164") or ""
    person = await db.person_by_phone(to) if to else None
    device = (person or {}).get("apns_token") or ""
    vid = int(body.get("verification_id") or 0)
    category = body.get("category") or ""
    if not vid and category in ("", "TRUSTED_SENDER"):
        vid = await resolve_verification_id(db, to)
        if vid and not category:
            category = "TRUSTED_SENDER"
    if not configured() or not device:
        log("push_skipped", path="/push", outcome="no_apns_keys" if not configured() else "no_device_token")
        return {"sent": False}
    s = settings()
    payload: dict[str, Any] = {"aps": {"alert": {"title": body.get("title") or s.app_name, "body": body.get("body") or ""},
                                       "sound": "default"}}
    if category:
        payload["aps"]["category"] = category
    if vid:
        payload["verification_id"] = vid
    host = "api.sandbox.push.apple.com" if s.apns_sandbox else "api.push.apple.com"
    try:
        async with httpx.AsyncClient(http2=True, timeout=8.0) as client:
            res = await client.post(
                f"https://{host}/3/device/{device}", json=payload,
                headers={"authorization": f"bearer {provider_token()}", "apns-topic": s.apns_topic,
                         "apns-push-type": "alert", "apns-priority": "10"},
            )
        ok = res.status_code == 200
        log("push", path="/push", status=res.status_code, outcome="sent" if ok else "rejected")
        return {"sent": ok}
    except Exception as e:  # noqa: BLE001
        log("push", path="/push", outcome="error", error=type(e).__name__)
        return {"sent": False}
