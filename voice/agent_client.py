"""Client for the agent service (docs/CONTRACTS.md section 4): /run/router and /run/interview."""
from __future__ import annotations

from typing import Any

import httpx

from config import Config


class AgentError(Exception):
    pass


class AgentClient:
    def __init__(self, cfg: Config, client: httpx.AsyncClient | None = None):
        self._base = cfg.agent_url
        self._token = cfg.agent_token
        # The caller enforces the 20 s budget with asyncio.wait_for; this is a backstop.
        self._client = client or httpx.AsyncClient(timeout=cfg.agent_timeout_s + 5)

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _post(self, workflow: str, body: dict[str, Any]) -> dict[str, Any]:
        try:
            r = await self._client.post(
                f"{self._base}/run/{workflow}", json=body,
                headers={"Authorization": f"Bearer {self._token}"},
            )
        except httpx.HTTPError as e:
            raise AgentError(f"{workflow}: {type(e).__name__}") from None
        if r.status_code >= 300:
            raise AgentError(f"{workflow}: {r.status_code}")
        data = r.json()
        if not isinstance(data, dict):
            raise AgentError(f"{workflow}: bad response")
        return data

    async def router(self, *, text: str, from_e164: str, person_id: int) -> dict[str, Any]:
        return await self._post("router", {
            "text": text, "from_e164": from_e164, "channel": "voice",
            "person_id": person_id, "mode": "voice",
        })

    async def interview(self, *, incident_id: int, utterance: str | None) -> dict[str, Any]:
        body: dict[str, Any] = {"incident_id": incident_id, "mode": "voice"}
        if utterance is not None:
            body["utterance"] = utterance
        return await self._post("interview", body)
