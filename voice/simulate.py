"""Text rehearsal of the hotline: drives HotlineSession exactly as the Pipecat pipeline does.

Typed lines are caller utterances (what STT would produce), `#1` is a keypad press,
`/hangup` (or Ctrl-D) hangs up. Uses the real SpacetimeDB and agent service from env.

    uv run python simulate.py                       # caller +15555550101 (seeded Joe)
    uv run python simulate.py --caller +15555550999 # unknown caller
    uv run python simulate.py --stub                # also start the stub agent on :8097
    printf 'I bought gift cards\\nno\\n' | uv run python simulate.py --stub   # scripted
"""
from __future__ import annotations

import argparse
import asyncio
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

VOICE_DIR = Path(__file__).resolve().parent


def _start_stub(port: int) -> subprocess.Popen:
    env = {**os.environ, "STUB_AGENT_PORT": str(port)}
    proc = subprocess.Popen([sys.executable, str(VOICE_DIR / "tests" / "stub_agent.py")], env=env)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    return proc


async def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--caller", default="+15555550101", help="caller ID in E.164 ('' for withheld)")
    ap.add_argument("--db", help="SpacetimeDB database name (default: SPACETIME_DB_NAME)")
    ap.add_argument("--stub", action="store_true", help="start tests/stub_agent.py and use it")
    ap.add_argument("--stub-port", type=int, default=8097)
    ap.add_argument("--quiet-logs", action="store_true", help="hide the JSON log lines")
    args = ap.parse_args()

    if args.db:
        os.environ["SPACETIME_DB_NAME"] = args.db
    stub = None
    if args.stub:
        os.environ["AGENT_SERVICE_URL"] = f"http://127.0.0.1:{args.stub_port}"
        stub = _start_stub(args.stub_port)
    if args.quiet_logs:
        import logging

        logging.getLogger("kavach.voice").setLevel(logging.WARNING)

    from agent_client import AgentClient
    from config import Config
    from hotline import HotlineSession, Phase
    from stdb import Stdb

    cfg = Config.load()
    stdb, agent = Stdb(cfg), AgentClient(cfg)
    ended = asyncio.Event()
    t_turn = [0.0]

    async def speak(text: str) -> None:
        lat = f" ({(time.monotonic() - t_turn[0]) * 1000:.0f} ms)" if t_turn[0] else ""
        t_turn[0] = 0.0
        print(f"  {cfg.app_name}: {text}{lat}", flush=True)

    async def hangup() -> None:
        print("  [call ended by hotline]", flush=True)
        ended.set()

    session = HotlineSession(caller_e164=args.caller, stdb=stdb, agent=agent, cfg=cfg, speak=speak, hangup=hangup)
    print(f"[db={cfg.db_name} agent={cfg.agent_url} caller={args.caller or 'withheld'}]  "
          "type what the caller says; #1 = keypad 1; /hangup to end", flush=True)
    await session.start()
    loop = asyncio.get_running_loop()
    interactive = sys.stdin.isatty()
    try:
        while not ended.is_set():
            line = await loop.run_in_executor(None, lambda: input("caller> ") if interactive else sys.stdin.readline())
            if line == "" and not interactive:
                break
            line = line.strip()
            if not interactive and line:
                print(f"caller> {line}", flush=True)
            if not line:
                continue
            if line == "/hangup":
                break
            t_turn[0] = time.monotonic()
            if line.startswith("#"):
                await session.on_dtmf(line[1:2])
            else:
                await session.on_utterance(line)
            if session.phase == Phase.ENDED:
                break
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        await session.on_hangup()
        print(f"[incident {session.incident_id} severity={session.severity or 'none'} family_told={session.family_told}]")
        await stdb.aclose()
        await agent.aclose()
        if stub:
            stub.terminate()


if __name__ == "__main__":
    asyncio.run(main())
