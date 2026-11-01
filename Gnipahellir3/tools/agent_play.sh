#!/usr/bin/env bash
# Runs the game for an agent to drive, in a throwaway folder, so its save and
# action.log never touch the real ones. Usage: tools/agent_play.sh [port]
# Then connect to 127.0.0.1:<port> and speak the protocol in src/agent_api.odin.
set -euo pipefail
port="${1:-7777}"
root="$(cd "$(dirname "$0")/.." && pwd)"
run="$root/build/agent_run"
mkdir -p "$run"
touch "$run/agent_sandbox"
ln -sfn "$root/sprites" "$run/sprites"
ln -sfn "$root/sounds" "$run/sounds"
(cd "$root" && odin build src -out:"$run/gnipa")
cd "$run"
GNIPA_AGENT_PORT="$port" exec ./gnipa
