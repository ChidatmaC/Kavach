"""Minimal async SpacetimeDB HTTP client (docs/CONTRACTS.md section 1), voice service identity."""
from __future__ import annotations

import re
from typing import Any

import httpx

from config import Config


class StdbError(Exception):
    pass


def sql_str(value: str) -> str:
    """Quote a string literal for SpacetimeDB SQL."""
    return "'" + str(value).replace("'", "''") + "'"


_ID = re.compile(r"^\d+$")


def sql_id(value: Any) -> str:
    s = str(int(value))
    if not _ID.match(s):
        raise ValueError("bad id")
    return s


class Stdb:
    def __init__(self, cfg: Config, client: httpx.AsyncClient | None = None):
        self._base = f"{cfg.spacetime_uri}/v1/database/{cfg.db_name}"
        self._token = cfg.voice_token
        self._client = client or httpx.AsyncClient(timeout=10.0)

    async def aclose(self) -> None:
        await self._client.aclose()

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token}"}

    async def call(self, reducer: str, args: dict[str, Any]) -> None:
        r = await self._client.post(f"{self._base}/call/{reducer}", json=args, headers=self._headers())
        if r.status_code >= 300:
            # The error text can echo arguments; keep only the status and reducer name upstream.
            raise StdbError(f"{reducer}: {r.status_code}")

    async def sql(self, query: str) -> list[dict[str, Any]]:
        r = await self._client.post(f"{self._base}/sql", content=query.encode(), headers=self._headers())
        if r.status_code >= 300:
            raise StdbError(f"sql: {r.status_code}")
        data = r.json()
        if not data:
            return []
        result = data[0]
        names = [e["name"]["some"] for e in result["schema"]["elements"]]
        return [dict(zip(names, row)) for row in result["rows"]]

    # --- typed helpers used by the hotline ---------------------------------------

    async def person_by_phone(self, phone: str) -> dict[str, Any] | None:
        rows = await self.sql(f"SELECT * FROM svc_person WHERE phone_e164 = {sql_str(phone)}")
        return rows[0] if rows else None

    async def incident_by_key(self, request_key: str) -> dict[str, Any] | None:
        rows = await self.sql(f"SELECT * FROM svc_incident WHERE request_key = {sql_str(request_key)}")
        return rows[0] if rows else None

    async def incident(self, incident_id: int) -> dict[str, Any] | None:
        rows = await self.sql(f"SELECT * FROM svc_incident WHERE id = {sql_id(incident_id)}")
        return rows[0] if rows else None

    async def recovery_steps(self, incident_id: int) -> list[dict[str, Any]]:
        rows = await self.sql(f"SELECT * FROM svc_recovery_step WHERE incident_id = {sql_id(incident_id)}")
        return sorted(rows, key=lambda r: r.get("sort_order", 0))

    async def family_alerts(self, incident_id: int) -> list[dict[str, Any]]:
        rows = await self.sql(f"SELECT * FROM svc_outbox WHERE related_incident_id = {sql_id(incident_id)}")
        return [r for r in rows if r.get("kind") == "family_alert"]

    async def number_report(self, phone: str) -> dict[str, Any] | None:
        rows = await self.sql(f"SELECT * FROM svc_community_report WHERE value = {sql_str(phone)}")
        rows = [r for r in rows if r.get("kind") == "number"]
        return rows[0] if rows else None

    async def hotline_evidence(self) -> list[dict[str, Any]]:
        return await self.sql("SELECT * FROM svc_report_evidence WHERE source = 'hotline'")
