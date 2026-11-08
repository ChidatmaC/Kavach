"""End-to-end through the real FastAPI websocket, Pipecat transport and Twilio serializer, with
fake STT/TTS and in-memory SpacetimeDB/agent fakes. Proves the server wiring without keys."""
import json
import time

from fastapi.testclient import TestClient
from pipecat.frames.frames import Frame, TTSSpeakFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

import pipeline
import server
from fakes import FakeAgent, FakeStdb

SPOKEN: list[str] = []


class PassThrough(FrameProcessor):
    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        await self.push_frame(frame, direction)


class FakeTTS(FrameProcessor):
    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, TTSSpeakFrame):
            SPOKEN.append(frame.text)
            return
        await self.push_frame(frame, direction)


def run_call(monkeypatch, sig: str | None):
    SPOKEN.clear()
    for k in ("TELEPHONY_ACCOUNT_SID", "TELEPHONY_AUTH_TOKEN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("TELEPHONY_PROVIDER", "twilio")
    monkeypatch.setattr(pipeline, "make_stt", lambda: PassThrough())
    monkeypatch.setattr(pipeline, "make_tts", lambda: FakeTTS())
    stdb = FakeStdb({"+15555550101": {"id": 1, "phone_e164": "+15555550101"}})
    monkeypatch.setattr(server, "Stdb", lambda cfg: stdb)
    monkeypatch.setattr(server, "AgentClient", lambda cfg: FakeAgent())

    params = {"from_number": "+15555550101", "to_number": "+15555550000", "call_sid": "CA9"}
    params["sig"] = sig if sig is not None else server.stream_sig("CA9", "+15555550101")
    client = TestClient(server.app)
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"event": "connected", "protocol": "Call", "version": "1.0.0"}))
        ws.send_text(json.dumps({"event": "start", "sequenceNumber": "1", "streamSid": "MZ9",
                                 "start": {"streamSid": "MZ9", "callSid": "CA9", "accountSid": "AC1",
                                           "tracks": ["inbound"], "customParameters": params,
                                           "mediaFormat": {"encoding": "audio/x-mulaw", "sampleRate": 8000, "channels": 1}}}))
        deadline = time.time() + 5
        while len(SPOKEN) < 2 and time.time() < deadline:
            time.sleep(0.05)
        ws.send_text(json.dumps({"event": "dtmf", "streamSid": "MZ9", "dtmf": {"track": "inbound_track", "digit": "1"}}))
        deadline = time.time() + 3
        while len(SPOKEN) < 4 and time.time() < deadline:
            time.sleep(0.05)
        ws.send_text(json.dumps({"event": "stop", "streamSid": "MZ9"}))
    return stdb


def test_signed_twilio_stream_runs_hotline(monkeypatch):
    stdb = run_call(monkeypatch, sig=None)
    assert SPOKEN[0].startswith("Hi, this is ")
    assert SPOKEN[2:4] == SPOKEN[0:2]  # keypad 1 over the media stream repeated the greeting
    [args] = stdb.reducer_calls("open_incident")
    assert args["caller_e164"] == "+15555550101" and args["person_id"] == 1


def test_unsigned_stream_is_treated_as_unknown_caller(monkeypatch):
    stdb = run_call(monkeypatch, sig="forged")
    [args] = stdb.reducer_calls("open_incident")
    assert args["caller_e164"] == "" and args["person_id"] == 0
