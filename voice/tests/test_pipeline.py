"""The Pipecat pipeline module imports and builds with dummy keys, and HotlineProcessor turns
frames into session calls (no network: STT/TTS services are built but never started)."""
import asyncio

import pytest
from pipecat.audio.dtmf.types import KeypadEntry
from pipecat.frames.frames import (
    BotStartedSpeakingFrame, InterruptionFrame, InputDTMFFrame, InterimTranscriptionFrame, TranscriptionFrame, TTSSpeakFrame,
    VADUserStartedSpeakingFrame, VADUserStoppedSpeakingFrame,
)
from pipecat.tests.utils import SleepFrame, run_test

import pipeline


class DummyWS:
    headers: dict = {}
    client_state = None
    application_state = None


@pytest.fixture
def dummy_keys(monkeypatch):
    for k in ("DEEPGRAM_API_KEY", "CARTESIA_API_KEY", "TELEPHONY_ACCOUNT_SID", "TELEPHONY_AUTH_TOKEN"):
        monkeypatch.setenv(k, "dummy")


@pytest.mark.parametrize("stt,tts", [("deepgram", "cartesia"), ("cartesia", "deepgram")])
def test_pipeline_builds_with_dummy_keys(dummy_keys, monkeypatch, stt, tts):
    monkeypatch.setenv("STT_PROVIDER", stt)
    monkeypatch.setenv("TTS_PROVIDER", tts)
    ser = pipeline.make_serializer("twilio", {"stream_id": "MZ1", "call_id": "CA1"})
    transport = pipeline.make_transport(DummyWS(), ser)
    worker, proc = pipeline.build_pipeline(transport, lambda p: None)
    assert isinstance(proc, pipeline.HotlineProcessor)
    assert type(pipeline.make_stt()).__name__.lower().startswith(stt)
    assert type(pipeline.make_tts()).__name__.lower().startswith(tts)


def test_tts_speed_is_slowed(dummy_keys):
    tts = pipeline.make_tts()  # cartesia default
    assert tts._settings.generation_config.speed == pytest.approx(0.9)


def test_serializers_for_each_provider(dummy_keys):
    for p in ("twilio", "telnyx", "plivo"):
        assert pipeline.make_serializer(p, {"stream_id": "s", "call_id": "c", "outbound_encoding": "PCMU"})
    with pytest.raises(ValueError):
        pipeline.make_serializer("nope", {})


class FakeSession:
    def __init__(self, proc):
        self.proc = proc
        self.events = []

    async def start(self):
        self.events.append(("start",))
        await self.proc.speak("hello")

    async def on_utterance(self, text):
        self.events.append(("utt", text))
        await self.proc.speak("reply")

    async def on_dtmf(self, d):
        self.events.append(("dtmf", d))


async def test_processor_turns_transcripts_into_session_calls():
    sessions = []

    def factory(proc):
        sessions.append(FakeSession(proc))
        return sessions[-1]

    proc = pipeline.HotlineProcessor(factory)
    down, _ = await run_test(proc, frames_to_send=[
        SleepFrame(sleep=0.05),
        VADUserStartedSpeakingFrame(),
        InterimTranscriptionFrame(text="my code is", user_id="u", timestamp="t"),
        TranscriptionFrame(text="They asked for", user_id="u", timestamp="t"),
        TranscriptionFrame(text="gift cards", user_id="u", timestamp="t"),
        VADUserStoppedSpeakingFrame(),
        SleepFrame(sleep=0.4),
        InputDTMFFrame(button=KeypadEntry.ONE),
        SleepFrame(sleep=0.1),
    ])
    s = sessions[0]
    assert s.events == [("start",), ("utt", "They asked for gift cards"), ("dtmf", "1")]
    spoken = [f.text for f in down if isinstance(f, TTSSpeakFrame)]
    assert spoken == ["hello", "reply"]
    assert not any(isinstance(f, (TranscriptionFrame, InterimTranscriptionFrame)) for f in down)


async def test_caller_barge_in_interrupts_bot_speech():
    proc = pipeline.HotlineProcessor(lambda p: FakeSession(p))
    down, _ = await run_test(proc, frames_to_send=[
        SleepFrame(sleep=0.05), BotStartedSpeakingFrame(), VADUserStartedSpeakingFrame(), SleepFrame(sleep=0.05),
    ])
    assert any(isinstance(f, InterruptionFrame) for f in down)


async def test_hotline_goodbye_ends_the_pipeline_worker():
    from pipecat.pipeline.pipeline import Pipeline
    from pipecat.pipeline.worker import PipelineWorker
    from pipecat.workers.runner import WorkerRunner

    class ByeSession(FakeSession):
        async def start(self):
            await self.proc.speak("Goodbye.")
            await self.proc.hangup()

    proc = pipeline.HotlineProcessor(lambda p: ByeSession(p))
    worker = PipelineWorker(Pipeline([proc]), idle_timeout_secs=None)
    runner = WorkerRunner(handle_sigint=False)
    await runner.add_workers(worker)
    await asyncio.wait_for(runner.run(), timeout=5)  # returns only if the worker ended
