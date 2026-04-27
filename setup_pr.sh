#!/bin/zsh

# setup_pr.sh — Set up a PR review worktree with Maestro autorun playbooks.
#
# Usage: setup_pr.sh <repo> <pr_number>

VALID_REPOS=(wizard wizard-ai wizard-core)
PLAYBOOKS_SOURCE="${HOME}/src/maestro-playbooks-custom/playbooks/Code_Review"
ZSHRC_FUNCTIONS="${HOME}/.zshrc.d/80-git-worktrees.zsh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <repo> <pr_number>

Set up a PR review worktree with Maestro autorun playbooks.

Arguments:
  repo        Repository name. Valid options: ${(j:, :)VALID_REPOS}
  pr_number   Pull request number (numeric)

Options:
  -h, --help  Show this help message and exit

Examples:
  $(basename "$0") wizard-core 209
  $(basename "$0") wizard 42
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

if [[ $# -ne 2 ]]; then
    echo "Error: Expected 2 arguments, got $#." >&2
    usage >&2
    exit 1
fi

repo="$1"
pr_number="$2"

# Validate repo name
(( ${VALID_REPOS[(Ie)$repo]} )) || die "Invalid repo '${repo}'. Valid options: ${(j:, :)VALID_REPOS}"

# Validate PR number is numeric
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR number must be numeric, got '${pr_number}'"

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

source "${ZSHRC_FUNCTIONS}" || die "Cannot source ${ZSHRC_FUNCTIONS}"

# ---------- create worktree ----------

worktree_name="${repo}-${pr_number}"

echo "\nChanging to ~/wizard/${repo}..."
cd "${HOME}/wizard/${repo}" || die "Cannot cd to ${HOME}/wizard/${repo}"

echo "Creating worktree '${worktree_name}'..."
make_worktree_here "${worktree_name}" || die "make_worktree_here failed"

echo "\nCreating autorun directories..."
make_autorun_dirs || die "make_autorun_dirs failed"

# ---------- set up playbooks ----------

autorun_dir="${HOME}/wizard/worktrees/autorun/${repo}/${worktree_name}"
playbook_dest="${autorun_dir}/development/code-review"

echo "\nSetting up Code Review playbooks in ${playbook_dest}..."
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
echo "\nChecking out PR #${pr_number} in worktree at ${worktree_dir}..."
pushd "${worktree_dir}" || die "Cannot cd to ${worktree_dir}"
gh pr checkout "$pr_number" || { popd; die "gh pr checkout failed"; }
popd

echo "\nWorktree and auto-run setup done!"
echo "  Worktree : ${worktree_dir}"
echo "  Playbooks: ${playbook_dest}"

# --------- create Claude Code agent and start auto-run ----

export MAESTRO_USER_DATA="$HOME/Library/Application Support/maestro-dev"
maestro_cli="$HOME/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
nudge_message="Do not make any changes this is only a review task."
agent_name="${repo}-pr-${pr_number}"

tmp_json=/tmp/maestro_agent$$.json
trap "rm -f ${tmp_json}" EXIT INT TERM

node ${maestro_cli} create-agent -d "${worktree_dir}" -t claude-code \
    --nudge \"${nudge_message}\" --auto-run-folder "${autorun_dir}" \
    ${agent_name} --json > "${tmp_json}"

cat ${tmp_json}

echo "\nAgent Created!"
jq . "${tmp_json}"
agent_id=$(jq -r .agentId ${tmp_json})

# --------- Trigger the auto-run
sleep 5
node ${maestro_cli} auto-run -a ${agent_id} "${playbook_dest}"/* --launch
