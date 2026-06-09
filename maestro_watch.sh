#!/bin/bash

# maestro_watch.sh — Watch a Maestro Auto Run agent until it is FULLY done.
#
# Why this exists: Maestro's `session list` / `show agent` report the agent as
# idle during an Auto Run, because each iteration runs as a *detached headless*
# `claude --print` process rather than a tracked desktop session. This watcher
# follows that process by agent ID. Since Auto Run exits after every task and
# relaunches for the next one, we only declare "fully done" once the process has
# stayed gone for grace_seconds with no new iteration spawning.
#
# Usage: maestro_watch.sh <agent_id> [grace_seconds] [poll_seconds]

set -uo pipefail   # intentionally NO -e: pgrep returning non-zero is normal

usage() {
    cat <<EOF
Usage: $(basename "$0") <agent_id> [grace_seconds] [poll_seconds]

Watch a Maestro Auto Run agent until it is fully done.

Arguments:
    agent_id        The UUID of the Maestro agent to watch
    grace_seconds   How long the process must stay gone before "done" (default 60)
    poll_seconds    Polling interval (default 5)

Options:
  -h, --help        Show this help message and exit

Env overrides (see _maestro_env.sh and .env.example):
    MAESTRO_USER_DATA   Maestro data dir
    MAESTRO_CLI_JS      Path to maestro-cli.js (MAESTRO_JS still honored)

Examples:
  $(basename "$0") 14fcd1d2-19ee-482b-8e4a-b521aca9a7e6
  $(basename "$0") 14fcd1d2-19ee-482b-8e4a-b521aca9a7e6 120 10
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------- argument parsing ----------

if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi

agent="${1:-}"
grace="${2:-60}"
poll="${3:-5}"

if [[ -z "$agent" ]]; then
    echo "Error: agent_id is required." >&2
    usage >&2
    exit 1
fi

[[ "$grace" =~ ^[0-9]+$ ]] || die "grace_seconds must be numeric, got '${grace}'"
[[ "$poll" =~ ^[0-9]+$ ]] || die "poll_seconds must be numeric, got '${poll}'"

# ---------- resolve Maestro CLI ----------

# maestro_dev_cli is a shell alias, which is NOT available inside scripts, so we
# invoke the real binary directly. The shared helper resolves the CLI path and
# sources any sibling .env. Honor the legacy MAESTRO_JS as an alias for
# MAESTRO_CLI_JS so existing environments keep working.
: "${MAESTRO_CLI_JS:=${MAESTRO_JS:-}}"
[[ -n "$MAESTRO_CLI_JS" ]] && export MAESTRO_CLI_JS

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_maestro_env.sh
source "${_script_dir}/_maestro_env.sh" || die "Cannot source _maestro_env.sh"

# This watcher reads the history file straight off disk, so it always needs a
# user-data dir. When the installed app is used the helper leaves
# MAESTRO_USER_DATA unset, so fall back to the app's default location.
export MAESTRO_USER_DATA="${MAESTRO_USER_DATA:-$HOME/Library/Application Support/maestro}"
cli=(node "$maestro_cli")

hist="$MAESTRO_USER_DATA/history/${agent}.json"

# ---------- helpers ----------

ts()   { date '+%H:%M:%S'; }
pids() { pgrep -f "claude --print.*$agent" 2>/dev/null; }

# Count completed-task entries in the agent history file (best-effort).
hist_count() {
    [[ -f "$hist" ]] || { echo 0; return; }
    python3 -c 'import sys,json
try:
    d=json.load(open(sys.argv[1]))
    print(len(d.get("entries",[])) if isinstance(d,dict) else 0)
except Exception:
    print(0)' "$hist" 2>/dev/null || echo 0
}

# ---------- watch loop ----------

# Best-effort friendly name for nicer logging / notification.
name="$("${cli[@]}" show agent --json "$agent" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("name",""))' 2>/dev/null)"
[[ -z "$name" ]] && name="$agent"

start_tasks="$(hist_count)"
iterations=0
seen_running=0
last_pid=""

echo "[$(ts)] Watching '$name'"
echo "          agent : $agent"
echo "          grace : ${grace}s   poll: ${poll}s   completed tasks so far: $start_tasks"

while true; do
    cur="$(pids | tr '\n' ' ' | sed 's/ *$//')"

    if [[ -n "$cur" ]]; then
        if [[ "$seen_running" -eq 0 || "$cur" != "$last_pid" ]]; then
            iterations=$((iterations + 1))
            echo "[$(ts)] > iteration #$iterations running (pid: $cur)"
        fi
        seen_running=1
        last_pid="$cur"
        sleep "$poll"
        continue
    fi

    # No process right now.
    if [[ "$seen_running" -eq 0 ]]; then
        echo "[$(ts)] ... not started yet — waiting for first iteration"
        sleep "$poll"
        continue
    fi

    # Seen it run, now gone -> grace countdown, watching for the next iteration.
    echo "[$(ts)] || no process — grace window ${grace}s (watching for next iteration)..."
    waited=0
    respawned=0
    while (( waited < grace )); do
        sleep "$poll"
        waited=$((waited + poll))
        if [[ -n "$(pids)" ]]; then
            echo "[$(ts)] ~ next iteration spawned after ${waited}s — still going"
            respawned=1
            break
        fi
        echo "[$(ts)]    still gone ${waited}/${grace}s"
    done
    [[ "$respawned" -eq 1 ]] && continue

    # Grace fully elapsed with no respawn -> fully done.
    end_tasks="$(hist_count)"
    delta=$((end_tasks - start_tasks))
    echo "[$(ts)] DONE — no new iteration for ${grace}s"
    echo "          iterations observed : $iterations"
    echo "          tasks completed     : $delta (total now $end_tasks)"
    "${cli[@]}" notify toast "Auto Run complete: $name" \
        "$iterations iteration(s), $delta task(s) done — idle ${grace}s" 2>/dev/null || true
    break
done
