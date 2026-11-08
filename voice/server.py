"""Hotline HTTP server: /health, the Twilio voice webhook (TwiML) and the media-stream websocket.

Inbound only: this service answers calls and never places one (spec 10, 12).

    uv run python server.py        # listens on VOICE_PORT (default 8765)
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
from xml.sax.saxutils import escape, quoteattr

import uvicorn
from fastapi import FastAPI, Request, Response, WebSocket
from fastapi.responses import JSONResponse

from agent_client import AgentClient
from config import Config, env
from hotline import HotlineSession
from logs import log
from stdb import Stdb

app = FastAPI(title="kavach-voice")

# Signs the parameters our TwiML hands to the media stream, so a random websocket client
# cannot claim to be a registered caller's number.
_STREAM_SECRET = (env("VOICE_STREAM_SECRET") or secrets.token_hex(32)).encode()


def stream_sig(call_sid: str, from_number: str) -> str:
    return hmac.new(_STREAM_SECRET, f"{call_sid}|{from_number}".encode(), hashlib.sha256).hexdigest()


def twilio_signature_ok(url: str, params: dict[str, str], signature: str, auth_token: str) -> bool:
    """Twilio request validation: base64(HMAC-SHA1(auth_token, url + sorted key+value pairs))."""
    payload = url + "".join(k + params[k] for k in sorted(params))
    digest = hmac.new(auth_token.encode(), payload.encode(), hashlib.sha1).digest()
    return hmac.compare_digest(base64.b64encode(digest).decode(), signature or "")


def twiml_connect(ws_url: str, call_sid: str, from_number: str, to_number: str) -> str:
    params = {
        "from_number": from_number, "to_number": to_number, "call_sid": call_sid,
        "sig": stream_sig(call_sid, from_number),
    }
    param_xml = "".join(f"<Parameter name={quoteattr(k)} value={quoteattr(v)} />" for k, v in params.items())
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f"<Response><Connect><Stream url={quoteattr(ws_url)}>{param_xml}</Stream></Connect></Response>"
    )


@app.get("/health")
async def health() -> JSONResponse:
    cfg = Config.load()
    return JSONResponse({
        "ok": True, "service": "voice", "app": cfg.app_name,
        "telephony_provider": env("TELEPHONY_PROVIDER", "twilio"),
        "stt": env("STT_PROVIDER", "deepgram"), "tts": env("TTS_PROVIDER", "cartesia"),
        "keys": {
            "telephony": bool(env("TELEPHONY_AUTH_TOKEN")),
            "stt": bool(env("DEEPGRAM_API_KEY") if env("STT_PROVIDER", "deepgram") == "deepgram" else env("CARTESIA_API_KEY")),
            "tts": bool(env("CARTESIA_API_KEY") if env("TTS_PROVIDER", "cartesia") == "cartesia" else env("DEEPGRAM_API_KEY")),
            "spacetime_token": bool(cfg.voice_token),
        },
    })


@app.post("/twilio/voice")
async def twilio_voice(request: Request) -> Response:
    """Twilio "A call comes in" webhook. Returns TwiML that connects a bidirectional media stream."""
    form = {k: str(v) for k, v in (await request.form()).items()}
    public = env("VOICE_PUBLIC_URL").rstrip("/")  # e.g. https://abc.ngrok.app
    auth_token = env("TELEPHONY_AUTH_TOKEN")
    if auth_token and env("TWILIO_VALIDATE_SIGNATURE", "true").lower() != "false":
        url = (public + request.url.path) if public else str(request.url)
        if not twilio_signature_ok(url, form, request.headers.get("X-Twilio-Signature", ""), auth_token):
            log("webhook_rejected", reason="bad_signature")
            return Response(status_code=403)
    if form.get("Direction", "inbound") != "inbound":
        log("webhook_rejected", reason="not_inbound")
        return Response("<Response><Reject/></Response>", media_type="application/xml")
    host = public.split("://", 1)[-1] if public else request.headers.get("host", "")
    ws_url = f"wss://{host}/ws"
    log("webhook_call", call_sid=escape(form.get("CallSid", ""))[:40])
    return Response(
        twiml_connect(ws_url, form.get("CallSid", ""), form.get("From", ""), form.get("To", "")),
        media_type="application/xml",
    )


@app.websocket("/ws")
async def media_stream(websocket: WebSocket) -> None:
    from pipecat.runner.utils import parse_telephony_websocket
    from pipecat.workers.runner import WorkerRunner

    from pipeline import build_pipeline, make_serializer, make_transport

    await websocket.accept()
    provider = env("TELEPHONY_PROVIDER", "twilio").lower()
    detected, call_data = await parse_telephony_websocket(websocket)
    if detected != provider:
        log("ws_rejected", reason="provider_mismatch", detected=detected)
        await websocket.close()
        return

    caller = call_data.from_number or ""
    if provider == "twilio":
        body = call_data.body or {}
        sig_ok = hmac.compare_digest(body.get("sig", ""), stream_sig(body.get("call_sid", ""), caller))
        if not sig_ok or body.get("call_sid") != call_data.call_id:
            # Unsigned stream: still help the caller, but never trust the number for a lookup.
            log("ws_unsigned", call_id=call_data.call_id)
            caller = ""

    cfg = Config.load()
    stdb, agent = Stdb(cfg), AgentClient(cfg)
    transport = make_transport(websocket, make_serializer(provider, call_data))

    def session_factory(proc):
        return HotlineSession(
            caller_e164=caller, stdb=stdb, agent=agent, cfg=cfg,
            speak=proc.speak, hangup=proc.hangup, call_id=(call_data.call_id or "")[-12:] or None,
        )

    worker, hotline = build_pipeline(transport, session_factory)

    @transport.event_handler("on_client_disconnected")
    async def _on_disconnect(_transport, _ws):
        if hotline.session:
            await hotline.session.on_hangup()
        await worker.cancel()

    runner = WorkerRunner(handle_sigint=False)
    await runner.add_workers(worker)
    try:
        await runner.run()
    finally:
        if hotline.session:
            await hotline.session.on_hangup()
        await stdb.aclose()
        await agent.aclose()


if __name__ == "__main__":
    uvicorn.run(app, host=env("VOICE_HOST", "0.0.0.0"), port=int(env("VOICE_PORT", "8765") or 8765))
