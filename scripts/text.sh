#!/bin/sh
# Send a text to the local Kavach agent line as <phone>, then show the outbound messages it caused.
# Usage: scripts/text.sh +15555550101 "verify Tommy"     (needs the stack started as in README "Run locally")
cd "$(dirname "$0")/.." || exit 1
[ -p .run/photon.in ] || { echo "photon-worker is not running with .run/photon.in"; exit 1; }
before=$(wc -l < .run/photon.log)
printf '%s> %s\n' "$1" "$2" > .run/photon.in
sleep "${WAIT:-8}"
tail -n +"$((before + 1))" .run/photon.log | grep '^\[' || echo "(no outbound messages yet; check .run/photon.log)"
