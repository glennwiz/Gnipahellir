#!/usr/bin/env bash
# Starts a seat in a herdr tab: its own worktree, board name, board tools and brief.
# Stands in for `thingvellir seat start`, which cannot pick a board or take a Linux dev root.
# The board lists these seats as uncounted.  Usage, from anywhere:
#   ops/seat/start-seat.sh [--dry-run] <name> implementer|reviewer <cards, comma separated> [base branch]
set -euo pipefail

SERVER=http://127.0.0.1:41070
BOARD=gnipahellir
COORD=claude-gnipa-coord-7b1e

dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
[[ $# -ge 3 ]] || { sed -n 2,5p "$0"; exit 1; }
name=$1 role=$2 cards=$3 base=${4:-master}

[[ $name =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "bad name: $name" >&2; exit 1; }
[[ $role == implementer || $role == reviewer ]] || { echo "role must be implementer or reviewer" >&2; exit 1; }
[[ $cards =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "cards must be numbers, comma separated" >&2; exit 1; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
ops=$repo/ops/seat
worktree=$repo/.seats/$name     # under the repo, which is already a trusted folder
home=$HOME/.local/state/thingvellir/seats/$name
brief=$home/brief.txt
mcp=$home/mcp.json
thingvellir=$(command -v thingvellir)
real=$(readlink -f "$thingvellir")

[[ ! -e $worktree ]] || { echo "worktree exists, this seat is alive or was not closed: $worktree" >&2; exit 1; }
git -C "$repo" rev-parse --verify -q "$base" >/dev/null || { echo "no branch $base" >&2; exit 1; }
curl -sf "$SERVER/api/boards/$BOARD/agents" >/dev/null || { echo "board not reachable at $SERVER" >&2; exit 1; }
IFS=, read -ra list <<<"$cards"
for c in "${list[@]}"; do
    curl -sf "$SERVER/api/boards/$BOARD/tasks/$c" >/dev/null || { echo "no card $c" >&2; exit 1; }
done

tools=(mcp__thingvellir__board_inbox mcp__thingvellir__board_post mcp__thingvellir__board_task
       mcp__thingvellir__board_agents mcp__thingvellir__board_note mcp__thingvellir__board_evidence
       mcp__thingvellir__board_message Read Edit Write Monitor
       "Bash(odin *)" "Bash(git *)" "Bash(python3 *)" "Bash(thingvellir *)" "Bash(ls *)" "Bash(grep *)" "Bash(sha256sum *)")

if [[ $dry == 1 ]]; then
    echo "worktree: $worktree on seat/$name from $base"
    echo "brief: $brief"
    echo "tab in herdr: $name, starts claude --model opus with the brief, $role, cards $cards"
    exit 0
fi

mkdir -p "$home"
exclude=$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)
grep -qxF '.seats/' "$exclude" || echo '.seats/' >>"$exclude"
git -C "$repo" worktree add -q -b "seat/$name" "$worktree" "$base"

curl -sf -X POST -H 'Content-Type: application/json' "$SERVER/api/boards/$BOARD/agents" -d "{\"name\":\"$name\"}" >/dev/null || true

cat >"$mcp" <<J
{"mcpServers":{"thingvellir":{"command":"$real","args":["mcp","--server","$SERVER","--agent","$name","--board","$BOARD"]}}}
J

{
    echo "You are $name (opus), a $role seat on the Thingvellir board $BOARD at $SERVER, for Gnipahellir. Your coordinator is $COORD."
    echo "Your cards: $cards. Your worktree: $worktree, branch seat/$name, from $base. Work only there; commands run from its Gnipahellir3."
    echo "Your board tools run as your name. There is no doorbell: arm this under your Monitor tool (timeout 1800000), re-arm it at each expiry, and call board_inbox for every line:"
    echo "  thingvellir watch --server $SERVER --board $BOARD --agent $name --receipts off 2>&1"
    echo "Show a card with board_task before acting on it, to get its rev. When your cards are Done, post closing to the coordinator and stop."
    echo
    cat "$ops/role-$role.txt"
    echo
    # The coordinator's rules are the house's, but its first line is about the coordinator's own brief.
    sed '/^THIS BRIEF.S FIRST LINE IS WRONG/d;/^COORDINATOR$/,$d' "$ops/house-rules.txt"
    echo
    cat "$ops/glossary.txt"
    echo
    cat "$ops/house-state.txt"
} >"$brief"

workspace=$(herdr workspace list | jq -r '.result.workspaces[0].workspace_id')
tab=$(herdr tab create --workspace "$workspace" --cwd "$worktree/Gnipahellir3" --label "$name" --no-focus)
pane=$(jq -r '.result.root_pane.pane_id // .result.pane.pane_id // .result.tab.root_pane_id // empty' <<<"$tab")
[[ -n $pane ]] || { echo "herdr gave no pane: $tab" >&2; exit 1; }

printf -v start '%q ' claude "Read $brief and follow it" --model opus --mcp-config "$mcp" --add-dir "$home" --allowedTools "${tools[@]}"
herdr pane run "$pane" "$start" >/dev/null
echo "started $name in herdr pane $pane"
