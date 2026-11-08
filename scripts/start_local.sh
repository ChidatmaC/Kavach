#!/bin/sh
# Starts the local Kavach backend: agent service (:8088) and photon-worker (:8090), whose gateway
# (console or photon) comes from MESSAGING_GATEWAY in .env.
# SpacetimeDB must already be running (`spacetime start` in another terminal).
# Logs: .run/agents.log, .run/photon.log. Text the agent with scripts/text.sh. Stop with scripts/stop_local.sh.
set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Missing .env (copy .env.example; see SETUP.md)"; exit 1; }
curl -s -m 2 http://127.0.0.1:3000/v1/ping >/dev/null || { echo "SpacetimeDB is not running. Run: spacetime start"; exit 1; }
mkdir -p .run
scripts/stop_local.sh >/dev/null 2>&1 || true

(cd agents && nohup uv run uvicorn server:app --host 0.0.0.0 --port 8088 > ../.run/agents.log 2>&1 &)

# photon-worker's console gateway reads typed messages from stdin; feed it from a named pipe
rm -f .run/photon.in && mkfifo .run/photon.in
nohup sh -c 'exec 3<>.run/photon.in; sleep 2147483647' >/dev/null 2>&1 &
echo $! > .run/fifo_holder.pid
(cd photon-worker && nohup npx tsx src/main.ts < ../.run/photon.in > ../.run/photon.log 2>&1 &)

printf 'Waiting for services'
for i in $(seq 1 30); do
  if curl -s -m 1 http://127.0.0.1:8088/health >/dev/null && curl -s -m 1 http://127.0.0.1:8090/health >/dev/null; then
    echo " - up."; echo "agents: http://127.0.0.1:8088  photon-worker: http://127.0.0.1:8090"; exit 0
  fi
  printf '.'; sleep 1
done
echo " - timed out. Check .run/agents.log and .run/photon.log"; exit 1
