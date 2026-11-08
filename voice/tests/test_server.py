"""/health and the Twilio webhook (TwiML, signature check, inbound only)."""
import base64
import hashlib
import hmac
import xml.etree.ElementTree as ET

from fastapi.testclient import TestClient

import server

client = TestClient(server.app)


def sign(url, params, token):
    payload = url + "".join(k + params[k] for k in sorted(params))
    return base64.b64encode(hmac.new(token.encode(), payload.encode(), hashlib.sha1).digest()).decode()


def test_health():
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["ok"] is True and r.json()["service"] == "voice"


def test_twiml_connects_media_stream(monkeypatch):
    monkeypatch.delenv("TELEPHONY_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("VOICE_PUBLIC_URL", "https://hotline.example.com")
    form = {"CallSid": "CA123", "From": "+15555550101", "To": "+15555550000", "Direction": "inbound"}
    r = client.post("/twilio/voice", data=form)
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/xml")
    root = ET.fromstring(r.text)
    stream = root.find("./Connect/Stream")
    assert stream.get("url") == "wss://hotline.example.com/ws"
    params = {p.get("name"): p.get("value") for p in stream.findall("Parameter")}
    assert params["from_number"] == "+15555550101" and params["call_sid"] == "CA123"
    assert params["sig"] == server.stream_sig("CA123", "+15555550101")


def test_webhook_rejects_bad_signature(monkeypatch):
    monkeypatch.setenv("TELEPHONY_AUTH_TOKEN", "secret")
    monkeypatch.setenv("VOICE_PUBLIC_URL", "https://hotline.example.com")
    form = {"CallSid": "CA1", "From": "+15555550101", "To": "+1555", "Direction": "inbound"}
    assert client.post("/twilio/voice", data=form, headers={"X-Twilio-Signature": "bad"}).status_code == 403
    good = sign("https://hotline.example.com/twilio/voice", form, "secret")
    assert client.post("/twilio/voice", data=form, headers={"X-Twilio-Signature": good}).status_code == 200


def test_outbound_calls_are_refused(monkeypatch):
    monkeypatch.delenv("TELEPHONY_AUTH_TOKEN", raising=False)
    r = client.post("/twilio/voice", data={"CallSid": "CA1", "From": "+1", "To": "+1", "Direction": "outbound-api"})
    assert "<Reject/>" in r.text
