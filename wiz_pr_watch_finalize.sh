#!/bin/bash

# wiz_pr_watch_finalize.sh — Wait for a Maestro PR review to finish, then post
# the review artifacts to Slack and send the finalize prompt to the agent.
#
# Launched DETACHED by wiz_pr_review.sh (it blocks for minutes).
#
# Usage:
#   wiz_pr_watch_finalize.sh <repo> <pr_number> <agent_id> <autorun_dir> \
#                            <pr_title> <pr_url> <thread_ts>
#
# Posts everything to WIZ_ACTIVE_CHANNEL (the channel the pipeline monitors),
# threaded under <thread_ts>. Monitored channel == output channel, so output
# can never leak elsewhere.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "Error: $*" >&2; exit 1; }

[[ $# -eq 7 ]] || die "Usage: $(basename "$0") <repo> <pr_number> <agent_id> <autorun_dir> <pr_title> <pr_url> <thread_ts>"
repo="$1"; pr_number="$2"; agent_id="$3"; autorun_dir="$4"
pr_title="$5"; pr_url="$6"; thread_ts="$7"

# ---- config + shared Slack helpers ----
# shellcheck source=wiz_pr_pipeline.env
source "${script_dir}/wiz_pr_pipeline.env" || die "Cannot source wiz_pr_pipeline.env"
# shellcheck source=_wiz_slack.sh
source "${script_dir}/_wiz_slack.sh"        || die "Cannot source _wiz_slack.sh"
wiz_slack_ready || die "SLACK_BOT_TOKEN not available to the watcher"

dest_channel="${WIZ_ACTIVE_CHANNEL}"
dest_thread="${thread_ts}"
log "Will post review artifacts to ${dest_channel}${dest_thread:+ (thread ${dest_thread})}"

# ---- 1. wait for the review to finish ----
log "Watching Maestro agent ${agent_id} until Auto Run is fully idle..."
"${script_dir}/maestro_watch.sh" "$agent_id" "${WIZ_WATCH_GRACE}" "${WIZ_WATCH_POLL}" \
    || log "WARNING: maestro_watch.sh exited non-zero; collecting artifacts anyway"

# ---- 2. collect + upload review files ----
present=()
missing=()
for f in "${WIZ_REVIEW_FILES[@]}"; do
    path="${autorun_dir}/${f}"
    if [[ -f "$path" ]]; then present+=("$path"); else missing+=("$f"); fi
done

intro="*PR Review complete:* <${pr_url}|${pr_title}>"
[[ ${#missing[@]} -gt 0 ]] && intro+=$'\n'"_Note: missing artifacts: ${missing[*]}_"

if [[ ${#present[@]} -gt 0 ]]; then
    if wiz_slack_upload "$dest_channel" "$dest_thread" "$intro" "${present[@]}"; then
        log "Uploaded ${#present[@]} review file(s) to ${dest_channel}"
    else
        log "Upload failed (rc=$?); posting text-only notice"
        wiz_slack_post "$dest_channel" "$dest_thread" "${intro}"$'\n'"(file upload failed — see watcher log)" >/dev/null
    fi
else
    log "No artifacts found; posting text-only notice"
    wiz_slack_post "$dest_channel" "$dest_thread" "${intro}"$'\n'"(no review artifacts found to attach)" >/dev/null
fi

# ---- 3. send finalize prompt to the Maestro agent ----
# shellcheck source=_maestro_env.sh
source "${script_dir}/_maestro_env.sh" || die "Cannot source _maestro_env.sh"
review_url=""
if [[ -f "$WIZ_FINALIZE_PROMPT" ]]; then
    log "Sending finalize prompt to agent ${agent_id}"
    finalize_out="$(node "$maestro_cli" send "$agent_id" "$(cat "$WIZ_FINALIZE_PROMPT")" 2>&1)" \
        || log "WARNING: maestro-cli send (finalize) failed"
    # Best-effort: pull the GitHub review URL out of the agent's response.
    review_url="$(printf '%s' "$finalize_out" \
        | grep -oE 'https://github\.com/[^ "]*#pullrequestreview-[0-9]+' | head -1)"
    [[ -z "$review_url" ]] && review_url="$(printf '%s' "$finalize_out" \
        | grep -oE 'https://github\.com/story-wizard/[^ "]*/pull/[0-9]+[^ "]*' | head -1)"
else
    log "WARNING: finalize prompt not found at ${WIZ_FINALIZE_PROMPT}; skipping send"
fi

# ---- 4. final confirmation, @-mentioning the original poster ----
mention=""
author_id="$(wiz_slack_thread_author "$dest_channel" "$dest_thread" 2>/dev/null)"
[[ -n "$author_id" ]] && mention="<@${author_id}> "
confirm="✅ ${mention}The code review for *${pr_title}* (<${pr_url}>) has been posted."
[[ -n "$review_url" ]] && confirm+=$'\n'"Review: <${review_url}>"
wiz_slack_post "$dest_channel" "$dest_thread" "$confirm" >/dev/null \
    && log "Posted final confirmation${author_id:+ (mentioned ${author_id})}" \
    || log "WARNING: failed to post final confirmation"

log "Pipeline finalize done for ${repo} PR #${pr_number}."
