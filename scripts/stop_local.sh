#!/bin/sh
# Stops the services started by scripts/start_local.sh (leaves SpacetimeDB running).
cd "$(dirname "$0")/.."
lsof -ti tcp:8088,8090 | xargs kill 2>/dev/null
[ -f .run/fifo_holder.pid ] && kill "$(cat .run/fifo_holder.pid)" 2>/dev/null
rm -f .run/fifo_holder.pid .run/photon.in
echo "Stopped agents and photon-worker."
