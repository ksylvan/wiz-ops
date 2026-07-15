#!/bin/bash

# wiz_pr_watch_finalize.sh — Wait for a Maestro PR review to finish, then post
# the review artifacts to Slack and send the finalize prompt to the agent.
#
# Launched DETACHED by wiz_pr_review.sh (it blocks for minutes).
#
# Usage:
#   wiz_pr_watch_finalize.sh <repo> <pr_number> <agent_id> <autorun_dir> \
#                            <pr_title> <pr_url> <thread_ts> [agent_type] [round]
#
# Posts everything to WIZ_ACTIVE_CHANNEL (the channel the pipeline monitors),
# threaded under <thread_ts>. Monitored channel == output channel, so output
# can never leak elsewhere.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
failure_reason="watcher exited before verified finalization"
finalized=false
die() { failure_reason="$*"; echo "Error: $*" >&2; exit 1; }

[[ $# -ge 7 && $# -le 10 ]] || die "Usage: $(basename "$0") <repo> <pr_number> <agent_id> <autorun_dir> <pr_title> <pr_url> <thread_ts> [agent_type] [round] [attempt_id]"
repo="$1"; pr_number="$2"; agent_id="$3"; autorun_dir="$4"
pr_title="$5"; pr_url="$6"; thread_ts="$7"
agent_type="${8:-}"
review_round="${9:-0}"
review_attempt="${10:-}"
round_label=""
[[ "$review_round" =~ ^[0-9]+$ && "$review_round" -gt 0 ]] && round_label=" #${review_round}"
agent_label=""
[[ -n "$agent_type" ]] && agent_label=" with ${agent_type}"

# ---- canonical state first (failure trap must work without env/Slack) ----
# shellcheck source=wiz_pr_review_state.sh
source "${script_dir}/wiz_pr_review_state.sh" || die "Cannot source wiz_pr_review_state.sh"

watcher_exit() {
    local rc=$?
    [[ "$finalized" == "true" ]] && return 0
    # A stale watcher for an older round must neither alter current state nor
    # post a misleading failure into the live Slack thread.
    current_state_file="$(wiz_review_state_file "$repo" "$pr_number")"
    if [[ "$review_round" =~ ^[0-9]+$ && "$review_round" -gt 0 && -s "$current_state_file" ]] \
        && { [[ "$(jq -r '.round // 0' "$current_state_file" 2>/dev/null)" != "$review_round" ]] \
          || { [[ -n "$review_attempt" ]] && [[ "$(jq -r '.attempt_id // empty' "$current_state_file" 2>/dev/null)" != "$review_attempt" ]]; }; }; then
        return "$rc"
    fi
    if [[ "$review_round" =~ ^[0-9]+$ && "$review_round" -gt 0 ]]; then
        wiz_review_state_mark_status "$repo" "$pr_number" "$review_round" "failed" "$review_attempt" \
            || echo "WARNING: could not mark canonical review state failed" >&2
    fi
    if command -v wiz_slack_ready >/dev/null 2>&1 && wiz_slack_ready; then
        fail_msg="❌ AI review${round_label}${agent_type:+ by *${agent_type}*} for *${pr_title}* (<${pr_url}>) failed before a verified GitHub review was submitted."
        fail_msg+=$'\n'"Reason: ${failure_reason}"
        wiz_slack_post "${WIZ_ACTIVE_CHANNEL}" "$thread_ts" "$fail_msg" >/dev/null 2>&1 || true
        if [[ -n "$thread_ts" ]]; then
            wiz_slack_unreact "${WIZ_ACTIVE_CHANNEL}" "$thread_ts" "${WIZ_REACT_INPROGRESS}" >/dev/null 2>&1 || true
            wiz_slack_react "${WIZ_ACTIVE_CHANNEL}" "$thread_ts" "${WIZ_REACT_FAILED}" >/dev/null 2>&1 || true
        fi
    fi
    return "$rc"
}
trap watcher_exit EXIT
trap 'failure_reason="watcher interrupted"; exit 130' INT
trap 'failure_reason="watcher terminated"; exit 143' TERM

# shellcheck source=wiz_pr_pipeline.env
source "${script_dir}/wiz_pr_pipeline.env" || die "Cannot source wiz_pr_pipeline.env"
# shellcheck source=_wiz_slack.sh
source "${script_dir}/_wiz_slack.sh" || die "Cannot source _wiz_slack.sh"
wiz_slack_ready || die "SLACK_BOT_TOKEN not available to the watcher"

ensure_current_attempt() {
    local sf
    sf="$(wiz_review_state_file "$repo" "$pr_number")"
    [[ -s "$sf" ]] || return 1
    [[ "$(jq -r '.round // 0' "$sf" 2>/dev/null)" == "$review_round" ]] || return 1
    [[ -z "$review_attempt" || "$(jq -r '.attempt_id // empty' "$sf" 2>/dev/null)" == "$review_attempt" ]]
}
stop_if_stale() {
    if ! ensure_current_attempt; then
        finalized=true
        log "Stale watcher attempt; exiting without side effects."
        exit 0
    fi
}
stop_if_stale

dest_channel="${WIZ_ACTIVE_CHANNEL}"
dest_thread="${thread_ts}"
log "Will post review artifacts to ${dest_channel}${dest_thread:+ (thread ${dest_thread})}"

# ---- 1. wait for the review to finish ----
known_worktree_dir="$(jq -r --arg a "$agent_type" '.agents[$a].worktree_dir // empty' \
    "$(wiz_review_state_file "$repo" "$pr_number")" 2>/dev/null)"
log "Watching Maestro agent ${agent_id}${agent_type:+ (${agent_type})} until Auto Run is fully idle..."
"${script_dir}/maestro_watch.sh" "$agent_id" "${WIZ_WATCH_GRACE}" "${WIZ_WATCH_POLL}" "$agent_type" \
    "${WIZ_WATCH_START_TIMEOUT}" "${WIZ_WATCH_MAX_SECONDS}" "$autorun_dir" "$known_worktree_dir" \
    || die "maestro_watch.sh did not reach verified Auto Run completion"
stop_if_stale

# ---- 2. collect + upload review files ----
present=()
missing=()
for f in "${WIZ_REVIEW_FILES[@]}"; do
    path="${autorun_dir}/${f}"
    if [[ -f "$path" ]]; then present+=("$path"); else missing+=("$f"); fi
done
[[ ${#missing[@]} -eq 0 ]] || die "required review artifacts missing: ${missing[*]}"

artifact_intro="*AI review${round_label} artifacts ready${agent_label}:* <${pr_url}|${pr_title}>"$'\n'"Final GitHub review verification is still in progress."
if wiz_slack_upload "$dest_channel" "$dest_thread" "$artifact_intro" "${present[@]}"; then
    log "Uploaded ${#present[@]} review file(s) to ${dest_channel}"
else
    upload_rc=$?
    die "Slack review-artifact upload failed (rc=${upload_rc}); completion was not announced"
fi

# ---- 2b. attach the review artifacts to the PR as a GitHub comment ----
# Single comment with each artifact in a collapsible <details> block so the PR
# conversation stays readable. GitHub caps a comment at 65536 chars, so each
# artifact is truncated to a safe budget with a pointer to the Slack thread for
# the full text. Best-effort: never fail the pipeline on a gh hiccup.
if [[ ${#present[@]} -gt 0 ]] && command -v gh >/dev/null 2>&1; then
    gh_body_file="$(mktemp -t wiz_pr_ghcomment.XXXXXX)"
    # Per-artifact char budget keeps the whole comment well under GitHub's 65536
    # limit even with 5 artifacts + the <details> wrappers.
    per_artifact_max=11000
    {
        printf '## 🤖 AI Code Review Artifacts\n\n'
        printf 'Automated review for this PR. Each section is collapsible. Full untruncated artifacts are in the Slack review thread.\n'
        for path in "${present[@]}"; do
            name="$(basename "$path")"
            label="${name%.md}"
            printf '\n<details>\n<summary><b>%s</b></summary>\n\n' "$label"
            bytes="$(wc -c < "$path" | tr -d ' ')"
            if [[ "$bytes" -gt "$per_artifact_max" ]]; then
                head -c "$per_artifact_max" "$path"
                printf '\n\n_… truncated (%s of %s bytes shown) — see the full %s in the Slack review thread._\n' \
                    "$per_artifact_max" "$bytes" "$name"
            else
                cat "$path"
            fi
            printf '\n\n</details>\n'
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            printf '\n_Note: these artifacts were not produced: %s_\n' "${missing[*]}"
        fi
    } > "$gh_body_file"
    if gh pr comment "$pr_number" --repo "story-wizard/${repo}" --body-file "$gh_body_file" >/dev/null 2>&1; then
        log "Posted review artifacts as a GitHub PR comment on story-wizard/${repo}#${pr_number}"
    else
        log "WARNING: gh pr comment failed for story-wizard/${repo}#${pr_number}"
    fi
    rm -f "$gh_body_file"
elif [[ ${#present[@]} -gt 0 ]]; then
    log "WARNING: gh CLI not found; skipped GitHub PR comment"
fi

# ---- 3. send finalize prompt and verify a NEW GitHub review ----
stop_if_stale
# shellcheck source=_maestro_env.sh
source "${script_dir}/_maestro_env.sh" || die "Cannot source _maestro_env.sh"
command -v gh >/dev/null 2>&1 || die "gh CLI not found for final review verification"
me="$(gh api user --jq '.login' 2>/dev/null)"
[[ -n "$me" ]] || die "cannot determine authenticated GitHub identity"
[[ "$me" == "${WIZ_GH_ACCOUNT}" ]] || die "GitHub identity is ${me}, expected ${WIZ_GH_ACCOUNT}"
before_ids="$(gh api "repos/story-wizard/${repo}/pulls/${pr_number}/reviews" --paginate --slurp 2>/dev/null \
    | jq -c --arg me "$me" '[add[] | select(.user.login==$me) | .id]')" \
    || die "cannot snapshot existing GitHub reviews"
[[ -f "$WIZ_FINALIZE_PROMPT" ]] || die "finalize prompt not found at ${WIZ_FINALIZE_PROMPT}"

log "Sending finalize prompt to agent ${agent_id}"
finalize_out="$(node "$maestro_cli" send "$agent_id" "$(cat "$WIZ_FINALIZE_PROMPT")" 2>&1)"
finalize_rc=$?
log "Finalize agent response received (${#finalize_out} chars, rc=${finalize_rc})"

# GitHub may take a moment to expose the submitted review. Completion requires
# a new bot review on the exact head that was analyzed; APPROVED is forbidden.
new_review=""
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    reviews_json="$(gh api "repos/story-wizard/${repo}/pulls/${pr_number}/reviews" --paginate --slurp 2>/dev/null \
        | jq -c 'add' 2>/dev/null || true)"
    new_review="$(printf '%s' "$reviews_json" | jq -c --arg me "$me" --argjson before "$before_ids" '
      [.[] | select(.user.login==$me) | select(.id as $id | ($before | index($id) | not))] | last // empty
    ' 2>/dev/null)"
    [[ -n "$new_review" ]] && break
    sleep 2
done
if [[ -z "$new_review" ]]; then
    if [[ $finalize_rc -eq 0 ]]; then
        die "finalize returned successfully but no new ${me} GitHub review appeared"
    else
        die "maestro-cli finalize failed (rc=${finalize_rc}) and no new ${me} GitHub review appeared"
    fi
fi
review_id="$(printf '%s' "$new_review" | jq -r '.id // empty')"
review_state="$(printf '%s' "$new_review" | jq -r '.state // empty')"
review_commit="$(printf '%s' "$new_review" | jq -r '.commit_id // empty')"
review_url="$(printf '%s' "$new_review" | jq -r '.html_url // empty')"
expected_head="$(jq -r '.head_sha // empty' "$(wiz_review_state_file "$repo" "$pr_number")" 2>/dev/null)"
if [[ "$review_state" == "APPROVED" ]]; then
    if [[ -n "$review_id" ]] && gh api --method PUT \
        "repos/story-wizard/${repo}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
        -f message="Unauthorized AI approval; AI reviews must remain COMMENT/CHANGES_REQUESTED only." \
        -f event="DISMISS" >/dev/null 2>&1; then
        die "safety violation: AI submitted APPROVED; review ${review_id} was immediately dismissed"
    fi
    die "CRITICAL safety violation: AI submitted APPROVED review ${review_id:-unknown} and automatic dismissal failed"
fi
[[ "$review_state" == "COMMENTED" || "$review_state" == "CHANGES_REQUESTED" ]] \
    || die "unexpected GitHub review state: ${review_state:-missing}"
[[ -n "$expected_head" && "$review_commit" == "$expected_head" ]] \
    || die "GitHub review commit ${review_commit:-missing} does not match reviewed head ${expected_head:-missing}"
log "Verified GitHub review ${review_url:-id $(printf '%s' "$new_review" | jq -r .id)} (${review_state})"
stop_if_stale

# Commit canonical completion before any human-facing completion announcement.
# If this locked attempt update fails, the EXIT trap marks failure instead of
# publishing contradictory success.
if [[ "$review_round" =~ ^[0-9]+$ && "$review_round" -gt 0 ]]; then
    wiz_review_state_mark_status "$repo" "$pr_number" "$review_round" "completed" "$review_attempt" \
        || die "could not mark canonical review state completed"
fi
finalized=true

# ---- 4. final confirmation, @-mentioning the original poster ----
mention=""
author_id="$(wiz_slack_thread_author "$dest_channel" "$dest_thread" 2>/dev/null)"
# Skip the mention if the parent was deleted (author resolves to Slackbot) or unknown.
if [[ -n "$author_id" && "$author_id" != "USLACKBOT" ]]; then
    mention="<@${author_id}> "
fi
confirm="✅ ${mention}AI review${round_label}${agent_type:+ by *${agent_type}*} for *${pr_title}* (<${pr_url}>) has been posted."
[[ -n "$review_url" ]] && confirm+=$'\n'"Review: <${review_url}>"
wiz_slack_post "$dest_channel" "$dest_thread" "$confirm" >/dev/null \
    && log "Posted final confirmation${author_id:+ (mentioned ${author_id})}" \
    || log "WARNING: failed to post final confirmation"

# ---- 5. swap the in-progress reaction to done on the trigger message ----
if [[ -n "$dest_thread" ]] && wiz_slack_ready; then
    wiz_slack_unreact "$dest_channel" "$dest_thread" "${WIZ_REACT_INPROGRESS}" >/dev/null 2>&1 || true
    wiz_slack_react   "$dest_channel" "$dest_thread" "${WIZ_REACT_DONE}"       >/dev/null 2>&1 || true
fi

log "Pipeline finalize verified for ${repo} PR #${pr_number}."
