#!/bin/bash

# maestro_id.sh — Look up a Maestro agent's UUID by name.
#
# Usage: maestro_id.sh <agent_name>
#
# Prints the UUID of the named agent to stdout.
# Exits non-zero if the agent is not found or if multiple agents share the name.

usage() {
    cat <<EOF
Usage: $(basename "$0") <agent_name>

Look up a Maestro agent's UUID by name.

Arguments:
    agent_name   The exact name of the Maestro agent

Options:
  -h, --help    Show this help message and exit

Examples:
  $(basename "$0") Wiz-Devel
  $(basename "$0") wizard-pr-345-claude-code
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------- argument parsing ----------

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    echo "Error: Expected 1 argument, got $#." >&2
    usage >&2
    exit 1
fi

agent_name="$1"

# ---------- look up agent ----------

export MAESTRO_USER_DATA="$HOME/Library/Application Support/maestro-dev"
maestro_cli="$HOME/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"

# 'list agents' output format (3 lines per agent):
#   <name> <type> [Auto Run]
#       /path/to/working/dir
#       <uuid>
uuids=$(node "${maestro_cli}" list agents | awk -v name="$agent_name" '
    /^  / && $1 == name { found=1; count=0; next }
    found { count++; if (count == 2) { gsub(/^[[:space:]]+/, ""); print; found=0 } }
')

if [[ -z "$uuids" ]]; then
    die "No agent found with name '${agent_name}'"
fi

match_count=$(echo "$uuids" | wc -l | tr -d ' ')
if [[ "$match_count" -gt 1 ]]; then
    echo "Warning: ${match_count} agents found with name '${agent_name}':" >&2
    echo "$uuids" >&2
    exit 1
fi

echo "$uuids"
