#!/bin/bash

# maestro_wt.sh — Set up a named worktree for use with a Maestro agent.
#
# Usage: maestro_wt.sh <repo> <worktree_name> [agent_type]

VALID_REPOS=(wizard wizard-ai wizard-core wizard-release)
VALID_AGENT_TYPES=(claude-code codex opencode)
ZSHRC_FUNCTIONS="${HOME}/.zshrc.d/80-git-worktrees.zsh"

format_options() {
    local formatted=""
    local option

    for option in "$@"; do
        if [[ -n "$formatted" ]]; then
            formatted+=", "
        fi
        formatted+="$option"
    done

    printf '%s' "$formatted"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <repo> <worktree_name> [agent_type]

Set up a named worktree for use with a Maestro agent.

Arguments:
    repo            Repository name. Valid options: $(format_options "${VALID_REPOS[@]}")
    worktree_name   The name of the worktree (will be part of the final name)
    agent_type      Optional Maestro agent type.
                    Valid options: $(format_options "${VALID_AGENT_TYPES[@]}"). Default: claude-code

Options:
  -h, --help    Show this help message and exit

Examples:
  $(basename "$0") wizard-core my-feature
  $(basename "$0") wizard refactor-auth
  $(basename "$0") wizard-ai experiment codex
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

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Error: Expected 2 or 3 arguments, got $#." >&2
    usage >&2
    exit 1
fi

repo="$1"
wt_name="$2"
agent_type="${3:-claude-code}"

# Validate repo name
repo_valid=false
for valid_repo in "${VALID_REPOS[@]}"; do
    if [[ "$repo" == "$valid_repo" ]]; then
        repo_valid=true
        break
    fi
done

if [[ "$repo_valid" != "true" ]]; then
    valid_options=$(format_options "${VALID_REPOS[@]}")
    die "Invalid repo '${repo}'. Valid options: ${valid_options}"
fi

# Validate worktree name
[[ -n "$wt_name" ]] || die "worktree_name cannot be empty"
[[ "$wt_name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "worktree_name must contain only letters, digits, '.', '_', or '-' (got '${wt_name}')"

# Validate agent type
agent_type_valid=false
for valid_agent_type in "${VALID_AGENT_TYPES[@]}"; do
    if [[ "$agent_type" == "$valid_agent_type" ]]; then
        agent_type_valid=true
        break
    fi
done

if [[ "$agent_type_valid" != "true" ]]; then
    valid_options=$(format_options "${VALID_AGENT_TYPES[@]}")
    die "Invalid agent type '${agent_type}'. Valid options: ${valid_options}"
fi

# ---------- source helper functions ----------

# shellcheck disable=SC1090
source "${ZSHRC_FUNCTIONS}" || die "Cannot source ${ZSHRC_FUNCTIONS}"

# ---------- create worktree ----------

worktree_name="${repo}-${wt_name}-${agent_type}"

printf "\n%s" "Changing to ~/wizard/${repo}..."
cd "${HOME}/wizard/${repo}" || die "Cannot cd to ${HOME}/wizard/${repo}"

echo "Creating worktree '${worktree_name}'..."
make_worktree_here "${worktree_name}" || die "make_worktree_here failed"

printf "\n%s" "Creating autorun directories..."
make_autorun_dirs || die "make_autorun_dirs failed"

autorun_dir="${HOME}/wizard/worktrees/autorun/${repo}/${worktree_name}"
worktree_dir="${HOME}/wizard/worktrees/${repo}/${worktree_name}"

printf "\n%s" "Worktree and auto-run setup done!"
echo "  Worktree : ${worktree_dir}"
echo "  Autorun  : ${autorun_dir}"

# --------- create Maestro agent ----------

export MAESTRO_USER_DATA="$HOME/Library/Application Support/maestro-dev"
maestro_cli="$HOME/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
agent_name="${repo}-${wt_name}-${agent_type}"

tmp_json=/tmp/maestro_agent$$.json
trap 'rm -f ${tmp_json}' EXIT INT TERM

node "${maestro_cli}" create-agent -d "${worktree_dir}" -t "${agent_type}" \
    --auto-run-folder "${autorun_dir}" \
    "${agent_name}" --json > "${tmp_json}"

cat "${tmp_json}"

printf "\n%s" "Agent Created!"
jq . "${tmp_json}"
