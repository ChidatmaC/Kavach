"""SpacetimeDB over HTTP (docs/CONTRACTS.md sections 1-3).

Reads go through `svc_*` views (or `my_*` with an app token); writes go only through reducers.
Reducers return nothing, so rows created by a reducer are read back by `request_key`.
"""
from __future__ import annotations

import asyncio
import time
import uuid
from typing import Any

import httpx

from .config import settings


class ReducerError(Exception):
    def __init__(self, reducer: str, status: int, text: str):
        super().__init__(f"{reducer}: {status} {text[:200]}")
        self.reducer = reducer
        self.status = status
        self.text = text


class SqlError(Exception):
    pass


def q(value: str) -> str:
    """Quote a string literal for SpacetimeDB SQL."""
    return "'" + str(value).replace("'", "''") + "'"


def new_key() -> str:
    return str(uuid.uuid4())


def _decode(v: Any) -> Any:
    # Timestamps arrive as [micros]; options never appear (module uses sentinels).
    if isinstance(v, list) and len(v) == 1 and isinstance(v[0], int) and v[0] > 10**14:
        return v[0]
    if v == [0]:
        return 0
    return v


class Stdb:
    def __init__(self, uri: str | None = None, db: str | None = None, token: str | None = None,
                 client: httpx.AsyncClient | None = None):
        s = settings()
        self.uri = (uri or s.spacetime_uri).rstrip("/")
        self.db = db or s.spacetime_db
        self.token = token if token is not None else s.agents_token
        self._client = client or httpx.AsyncClient(timeout=httpx.Timeout(8.0, connect=3.0))

    async def aclose(self) -> None:
        await self._client.aclose()

    def _url(self, path: str) -> str:
        return f"{self.uri}/v1/database/{self.db}/{path}"

    async def call(self, reducer: str, args: dict[str, Any], token: str | None = None) -> None:
        res = await self._client.post(
            self._url(f"call/{reducer}"),
            json=args,
            headers={"authorization": f"Bearer {token or self.token}"},
        )
        if res.status_code // 100 != 2:
            raise ReducerError(reducer, res.status_code, res.text)

    async def sql(self, query: str, token: str | None = None) -> list[dict[str, Any]]:
        res = await self._client.post(
            self._url("sql"), content=query.encode(), headers={"authorization": f"Bearer {token or self.token}"}
        )
        if res.status_code // 100 != 2:
            raise SqlError(f"sql {res.status_code}: {res.text[:200]}")
        out: list[dict[str, Any]] = []
        for result in res.json():
            names = [e["name"]["some"] for e in result["schema"]["elements"]]
            for row in result["rows"]:
                out.append({n: _decode(v) for n, v in zip(names, row)})
        return out

    async def one(self, query: str, token: str | None = None) -> dict[str, Any] | None:
        rows = await self.sql(query, token)
        return rows[0] if rows else None

    async def read_back(self, view: str, request_key: str, attempts: int = 5) -> dict[str, Any] | None:
        """Read a row created by a reducer through its request_key (commit is synchronous; retry is a guard)."""
        for i in range(attempts):
            row = await self.one(f"SELECT * FROM {view} WHERE request_key = {q(request_key)}")
            if row:
                return row
            await asyncio.sleep(0.05 * (i + 1))
        return None

    # --- typed reads used by tools -------------------------------------------------

    async def person(self, person_id: int) -> dict[str, Any] | None:
        return await self.one(f"SELECT * FROM svc_person WHERE id = {int(person_id)}")

    async def person_by_phone(self, phone: str) -> dict[str, Any] | None:
        return await self.one(f"SELECT * FROM svc_person WHERE phone_e164 = {q(phone)}")

    async def contacts(self, person_id: int) -> list[dict[str, Any]]:
        return await self.sql(f"SELECT * FROM svc_contact WHERE person_id = {int(person_id)}")

    async def contact(self, contact_id: int) -> dict[str, Any] | None:
        return await self.one(f"SELECT * FROM svc_contact WHERE id = {int(contact_id)}")

    async def incident(self, incident_id: int) -> dict[str, Any] | None:
        return await self.one(f"SELECT * FROM svc_incident WHERE id = {int(incident_id)}")

    async def campaigns(self) -> list[dict[str, Any]]:
        return await self.sql("SELECT * FROM campaign")


_cache: dict[str, tuple[float, Any]] = {}


async def cached(key: str, ttl: float, loader) -> Any:
    """Tiny TTL cache for corpus reads (community reports, evidence, campaigns)."""
    hit = _cache.get(key)
    now = time.monotonic()
    if hit and now - hit[0] < ttl:
        return hit[1]
    val = await loader()
    _cache[key] = (now, val)
    return val


def clear_cache() -> None:
    _cache.clear()
