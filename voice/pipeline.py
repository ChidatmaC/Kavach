"""Pipecat pipeline for the hotline (spec 10, D8), written against pipecat-ai 1.15.

    transport.input() -> Silero VAD -> STT -> HotlineProcessor -> TTS -> transport.output()

HotlineProcessor turns final transcripts and keypad presses into HotlineSession calls and the
session's replies into TTSSpeakFrames. There is no LLM in the pipeline: the agent service's
router and interview workflows are the brain, reached over HTTP by HotlineSession.

Providers are chosen by env:
  TELEPHONY_PROVIDER = twilio (default) | telnyx | plivo   (media streams over a FastAPI websocket)
  STT_PROVIDER       = deepgram (default) | cartesia
  TTS_PROVIDER       = cartesia (default) | deepgram
"""
from __future__ import annotations

import asyncio
from typing import Any, Callable

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    CancelFrame,
    EndFrame,
    EndWorkerFrame,
    Frame,
    InputDTMFFrame,
    InterimTranscriptionFrame,
    StartFrame,
    TranscriptionFrame,
    TTSSpeakFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.audio.vad_processor import VADProcessor
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from config import env, env_float
from logs import log

# Caller turn ends this long after VAD says they stopped (Silero stop_secs adds 0.5 s before
# that). Keeps the reply inside the 1.5 s target while merging split STT segments.
ENDPOINT_GRACE_S = 0.15
TELEPHONY_SAMPLE_RATE = 8000
# Cartesia speed 0.9 ~ 140 words per minute for the default voice; Deepgram Aura similar.
DEFAULT_TTS_SPEED = 0.9


# --- services ------------------------------------------------------------------------


def make_stt():
    provider = env("STT_PROVIDER", "deepgram").lower()
    if provider == "cartesia":
        from pipecat.services.cartesia.stt import CartesiaSTTService

        return CartesiaSTTService(api_key=env("CARTESIA_API_KEY"))
    from pipecat.services.deepgram.stt import DeepgramSTTService

    return DeepgramSTTService(
        api_key=env("DEEPGRAM_API_KEY"),
        mip_opt_out=True,
        settings=DeepgramSTTService.Settings(
            model=env("DEEPGRAM_STT_MODEL", "nova-3-general"),
            # Defence in depth: Deepgram masks card numbers, SSNs and numeral runs at the source;
            # redact.py masks again before anything leaves this process.
            redact=["pci", "ssn", "numbers"],
            punctuate=True,
            interim_results=True,
        ),
    )


def make_tts():
    provider = env("TTS_PROVIDER", "cartesia").lower()
    speed = env_float("TTS_SPEED", DEFAULT_TTS_SPEED)
    if provider == "deepgram":
        from pipecat.services.deepgram.tts import DeepgramTTSService

        return DeepgramTTSService(
            api_key=env("DEEPGRAM_API_KEY"),
            settings=DeepgramTTSService.Settings(
                voice=env("DEEPGRAM_TTS_VOICE", "aura-2-thalia-en"), speed=speed),
        )
    from pipecat.services.cartesia.tts import CartesiaTTSService, GenerationConfig

    return CartesiaTTSService(
        api_key=env("CARTESIA_API_KEY"),
        settings=CartesiaTTSService.Settings(
            voice=env("CARTESIA_VOICE_ID", "86e30c1d-714b-4074-a1f2-1cb6b552fb49"),
            generation_config=GenerationConfig(speed=speed),
        ),
    )


def make_vad() -> VADProcessor:
    # Interruptions are allowed: HotlineProcessor stops bot speech when the caller talks.
    return VADProcessor(vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=0.5)))


def make_serializer(provider: str, call_data: Any):
    """Frame serializer for the telephony provider's media-stream protocol."""
    account = env("TELEPHONY_ACCOUNT_SID")
    token = env("TELEPHONY_AUTH_TOKEN")
    if provider == "twilio":
        from pipecat.serializers.twilio import TwilioFrameSerializer

        can_hang_up = bool(account and token and call_data.get("call_id"))
        return TwilioFrameSerializer(
            stream_sid=call_data.get("stream_id") or "",
            call_sid=call_data.get("call_id"),
            account_sid=account or None,
            auth_token=token or None,
            params=TwilioFrameSerializer.InputParams(auto_hang_up=can_hang_up),
        )
    if provider == "telnyx":
        from pipecat.serializers.telnyx import TelnyxFrameSerializer

        return TelnyxFrameSerializer(
            stream_id=call_data.get("stream_id") or "",
            call_control_id=call_data.get("call_id"),
            outbound_encoding=call_data.get("outbound_encoding") or "PCMU",
            inbound_encoding="PCMU",
            api_key=token,
        )
    if provider == "plivo":
        from pipecat.serializers.plivo import PlivoFrameSerializer

        return PlivoFrameSerializer(
            stream_id=call_data.get("stream_id") or "",
            call_id=call_data.get("call_id"),
            auth_id=account,
            auth_token=token,
        )
    raise ValueError(f"unsupported TELEPHONY_PROVIDER: {provider}")


def make_transport(websocket: Any, serializer: Any):
    from pipecat.transports.websocket.fastapi import FastAPIWebsocketParams, FastAPIWebsocketTransport

    params = FastAPIWebsocketParams(
        audio_in_enabled=True,
        audio_out_enabled=True,
        add_wav_header=False,
        serializer=serializer,
        allowed_origins=[],  # telephony providers send no Origin header
        session_timeout=int(env_float("VOICE_MAX_CALL_SECS", 1200)),
    )
    return FastAPIWebsocketTransport(websocket=websocket, params=params)


# --- the bridge between Pipecat frames and HotlineSession ------------------------------------


class HotlineProcessor(FrameProcessor):
    """Collects final transcripts into caller turns and voices the session's replies.

    Transcription frames are consumed here and never pushed downstream (TTS would read them
    aloud, and they carry caller content).
    """

    def __init__(self, session_factory: Callable[["HotlineProcessor"], Any], **kwargs):
        super().__init__(**kwargs)
        self._session_factory = session_factory
        self.session: Any = None
        self._buffer: list[str] = []
        self._user_speaking = False
        self._bot_speaking = False
        self._flush_handle: asyncio.TimerHandle | None = None
        self._inbox: asyncio.Queue[tuple[str, str]] = asyncio.Queue()
        self._worker: asyncio.Task | None = None

    # Session callbacks ------------------------------------------------------------

    async def speak(self, text: str) -> None:
        await self.push_frame(TTSSpeakFrame(text=text, append_to_context=False))

    async def hangup(self) -> None:
        # Downstream, after the goodbye TTS frames, so they are spoken before the call ends.
        await self.push_frame(EndWorkerFrame(reason="hotline goodbye"))

    # Frame handling -------------------------------------------------------------------

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            await self.push_frame(frame, direction)
            self.session = self._session_factory(self)
            self._worker = self.create_task(self._run_turns())
            await self._inbox.put(("start", ""))
            return
        if isinstance(frame, (EndFrame, CancelFrame)):
            if self._worker:
                await self.cancel_task(self._worker)
                self._worker = None
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, BotStartedSpeakingFrame):
            self._bot_speaking = True
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self._bot_speaking = False
        elif isinstance(frame, VADUserStartedSpeakingFrame):
            self._user_speaking = True
            self._cancel_flush()
            if self._bot_speaking:
                await self.broadcast_interruption()  # barge-in stops the bot mid-sentence
        elif isinstance(frame, VADUserStoppedSpeakingFrame):
            self._user_speaking = False
            self._schedule_flush(ENDPOINT_GRACE_S)
        elif isinstance(frame, TranscriptionFrame):
            if frame.text and frame.text.strip():
                self._buffer.append(frame.text.strip())
                if not self._user_speaking:
                    self._schedule_flush(ENDPOINT_GRACE_S)
            return  # never forward caller text
        elif isinstance(frame, InterimTranscriptionFrame):
            return
        elif isinstance(frame, InputDTMFFrame):
            await self._inbox.put(("dtmf", str(frame.button.value)))
            return

        await self.push_frame(frame, direction)

    def _cancel_flush(self) -> None:
        if self._flush_handle:
            self._flush_handle.cancel()
            self._flush_handle = None

    def _schedule_flush(self, delay: float) -> None:
        self._cancel_flush()
        loop = asyncio.get_running_loop()
        self._flush_handle = loop.call_later(delay, self._flush)

    def _flush(self) -> None:
        self._flush_handle = None
        if self._user_speaking or not self._buffer:
            return
        text = " ".join(self._buffer)
        self._buffer.clear()
        self._inbox.put_nowait(("utt", text))

    async def _run_turns(self) -> None:
        while True:
            kind, value = await self._inbox.get()
            try:
                if kind == "start":
                    await self.session.start()
                elif kind == "utt":
                    await self.session.on_utterance(value)
                elif kind == "dtmf":
                    await self.session.on_dtmf(value)
            except Exception as e:  # noqa: BLE001 - one bad turn must not drop the call
                log("turn_error", error=type(e).__name__)


def build_pipeline(transport: Any, session_factory: Callable[[HotlineProcessor], Any],
                   stt: Any = None, tts: Any = None) -> tuple[PipelineWorker, HotlineProcessor]:
    hotline = HotlineProcessor(session_factory)
    pipeline = Pipeline([
        transport.input(),
        make_vad(),
        stt or make_stt(),
        hotline,
        tts or make_tts(),
        transport.output(),
    ])
    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(
            audio_in_sample_rate=TELEPHONY_SAMPLE_RATE,
            audio_out_sample_rate=TELEPHONY_SAMPLE_RATE,
            enable_metrics=True,
        ),
        idle_timeout_secs=env_float("VOICE_IDLE_TIMEOUT_SECS", 120),
    )
    return worker, hotline
