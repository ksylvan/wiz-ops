#!/bin/bash

# setup_pr.sh — Set up a PR review worktree with Maestro autorun playbooks.
#
# Usage: setup_pr.sh <repo> <pr_number> [agent_type]

VALID_REPOS=(wizard wizard-ai wizard-core wizard-release)
VALID_AGENT_TYPES=(claude-code codex opencode)
PLAYBOOKS_SOURCE="${HOME}/src/maestro-playbooks-custom/playbooks/Code_Review"
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
Usage: $(basename "$0") [--no-run] <repo> <pr_number> [agent_type]

Set up a PR review worktree with Maestro autorun playbooks.

Arguments:
    repo        Repository name. Valid options: $(format_options "${VALID_REPOS[@]}")
    pr_number   Pull request number (numeric)
    agent_type  Optional Maestro agent type.
                Valid options: $(format_options "${VALID_AGENT_TYPES[@]}"). Default: claude-code

Options:
  -h, --help    Show this help message and exit
  --no-run      Set up the agent but skip the final auto-run launch

Examples:
  $(basename "$0") wizard-core 209
  $(basename "$0") wizard 42
  $(basename "$0") wizard-ai 101 codex
  $(basename "$0") --no-run wizard-core 209
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

# Parse optional flags before positional arguments
no_run=false
args=()
for arg in "$@"; do
    case "$arg" in
        --no-run) no_run=true ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Error: Expected 2 or 3 arguments, got $#." >&2
    usage >&2
    exit 1
fi

repo="$1"
pr_number="$2"
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

# Validate PR number is numeric
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR number must be numeric, got '${pr_number}'"

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

# ---------- validate PR ----------

echo "Validating PR #${pr_number} in story-wizard/${repo}..."

pr_json=$(gh pr view "$pr_number" \
    --repo "story-wizard/${repo}" \
    --json state,isDraft 2>&1) \
    || die "PR #${pr_number} not found in story-wizard/${repo}:\n${pr_json}"

pr_state=$(echo "$pr_json" | jq -r '.state')
pr_is_draft=$(echo "$pr_json" | jq -r '.isDraft')

[[ "$pr_state" == "OPEN" ]] \
    || die "PR #${pr_number} is not open (state: ${pr_state})"
[[ "$pr_is_draft" == "false" ]] \
    || die "PR #${pr_number} is a draft"

echo "PR #${pr_number} validated: open, not a draft."

# ---------- source helper functions ----------

# shellcheck disable=SC1090
source "${ZSHRC_FUNCTIONS}" || die "Cannot source ${ZSHRC_FUNCTIONS}"

# ---------- create worktree ----------

worktree_name="${repo}-pr-${pr_number}-${agent_type}"

printf "\n%s" "Changing to ~/wizard/${repo}..."
cd "${HOME}/wizard/${repo}" || die "Cannot cd to ${HOME}/wizard/${repo}"

echo "Creating worktree '${worktree_name}'..."
make_worktree_here "${worktree_name}" || die "make_worktree_here failed"

printf "\n%s" "Creating autorun directories..."
make_autorun_dirs || die "make_autorun_dirs failed"

# ---------- set up playbooks ----------

autorun_dir="${HOME}/wizard/worktrees/autorun/${repo}/${worktree_name}"
playbook_dest="${autorun_dir}/development/code-review"

printf "\n%s" "Setting up Code Review playbooks in ${playbook_dest}..."
mkdir -p "${playbook_dest}" || die "Cannot create ${playbook_dest}"
cp "${PLAYBOOKS_SOURCE}/"*.md "${playbook_dest}/" || die "Failed to copy playbooks"
rm -f "${playbook_dest}/README.md"

# Substitute the placeholder PR URL in the analyze-changes document
perl -pi -e \
    's@https://github\.com/USER/PROJECT/pull/XXXX@https://github.com/story-wizard/'"${repo}"'/pull/'"${pr_number}"'@g' \
    "${playbook_dest}/1_ANALYZE_CHANGES.md" \
    || die "Failed to update PR URL in 1_ANALYZE_CHANGES.md"

echo "Playbooks configured."

# ---------- checkout PR in worktree ----------

worktree_dir="${HOME}/wizard/worktrees/${repo}/${worktree_name}"
printf "\n%s" "Checking out PR #${pr_number} in worktree at ${worktree_dir}..."
pushd "${worktree_dir}" || die "Cannot cd to ${worktree_dir}"
gh pr checkout "$pr_number" || { popd || exit ; die "gh pr checkout failed"; }
popd || exit

printf "\n%s" "Worktree and auto-run setup done!"
echo "  Worktree : ${worktree_dir}"
echo "  Playbooks: ${playbook_dest}"

# --------- create Claude Code agent and start auto-run ----

export MAESTRO_USER_DATA="$HOME/Library/Application Support/maestro-dev"
maestro_cli="$HOME/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
nudge_message="Do not make any changes this is only a review task."
agent_name="${repo}-pr-${pr_number}-${agent_type}"

tmp_json=/tmp/maestro_agent$$.json
trap 'rm -f ${tmp_json}' EXIT INT TERM

node "${maestro_cli}" create-agent -d "${worktree_dir}" -t "${agent_type}" \
    --nudge "${nudge_message}" --auto-run-folder "${autorun_dir}" \
    "${agent_name}" --json > "${tmp_json}"

cat "${tmp_json}"

printf "\n%s" "Agent Created!"
jq . "${tmp_json}"
agent_id=$(jq -r .agentId "${tmp_json}")

# --------- Trigger the auto-run
if [[ "$no_run" == "true" ]]; then
    printf "\n%s\n" "--no-run specified: skipping auto-run launch."
    echo "  Agent ID : ${agent_id}"
    echo "  To launch manually: node ${maestro_cli} auto-run -a ${agent_id} ${playbook_dest}/* --launch"
else
    sleep 5
    node "${maestro_cli}" auto-run -a "${agent_id}" "${playbook_dest}"/* --launch
fi
