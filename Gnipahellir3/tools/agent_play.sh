#!/usr/bin/env bash
# Runs the game for an agent to drive, in its own folder under build/agent_runs,
# so every run keeps its log and acts, and none touch the real save or action.log.
# Usage: tools/agent_play.sh [port] [seed]
# Then connect to 127.0.0.1:<port> and speak the protocol in src/agent_api.odin.
set -euo pipefail
port="${1:-7777}"
seed="${2:-$RANDOM$RANDOM}"
root="$(cd "$(dirname "$0")/.." && pwd)"
run="$root/build/agent_runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run"
touch "$run/agent_sandbox"
echo "$seed" > "$run/seed"
ln -sfn "$root/sprites" "$run/sprites"
ln -sfn "$root/sounds" "$run/sounds"
(cd "$root" && odin build src -out:"$run/gnipa")
echo "run folder: $run"
cd "$run"
GNIPA_SEED="$seed" GNIPA_AGENT_PORT="$port" exec ./gnipa
