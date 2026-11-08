import json
import os
import sys
from pathlib import Path

import pytest

AGENTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(AGENTS))
SEED = json.loads((AGENTS.parent / "shared" / "seed" / "demo.json").read_text())


class FakeStdb:
    """In-memory stand-in for the corpus reads search_community makes (seeded from shared/seed/demo.json)."""

    def __init__(self, name="fake"):
        self.db = name
        slug_id = {c["slug"]: i + 1 for i, c in enumerate(SEED["campaigns"])}
        self.campaign_rows = [{"id": i + 1, **c} for i, c in enumerate(SEED["campaigns"])]
        self.reports = [{"id": i + 1, "kind": r["kind"], "value": r["value"], "campaign_id": slug_id.get(r["campaign_slug"] or "", 0),
                         "reporter_count": r["reporter_count"], "label_visible": r["reporter_count"] >= 3}
                        for i, r in enumerate(SEED["community_reports"])]
        self.evidence = [{"id": i + 1, **{k: v for k, v in e.items() if k != "campaign_slug"},
                          "campaign_id": slug_id.get(e["campaign_slug"] or "", 0)} for i, e in enumerate(SEED["report_evidence"])]

    async def sql(self, query, token=None):
        if "svc_community_report" in query:
            return self.reports
        if "svc_report_evidence" in query:
            return self.evidence
        return []

    async def campaigns(self):
        return self.campaign_rows


@pytest.fixture(autouse=True)
def _no_llm(monkeypatch):
    """Unit tests always exercise the no-model path unless a test opts in."""
    from kavach import config, stdb

    monkeypatch.setenv("NIM_API_KEY", "")
    config.settings.cache_clear()
    stdb.clear_cache()
    yield
    config.settings.cache_clear()


@pytest.fixture
def fake_db():
    return FakeStdb()
