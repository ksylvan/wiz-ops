#!/bin/bash

# wiz_nightly_watchdog.sh — guarantee a daily rolling build of `develop`, even
# when GitHub silently drops the scheduled nightly.
#
# WHY: build-release.yml's nightly is a GitHub `schedule` cron ('0 6 * * *').
# GitHub scheduled workflows are best-effort — under Actions load they drift
# later and can be SKIPPED entirely (observed: fire time drifted 07:05 -> 10:08
# over a week, then a day was dropped with no run and no error). This watchdog
# runs on the Mac Studio's own cron and dispatches the nightly if GitHub hasn't
# produced a successful rolling build in the freshness window.
#
# HOW (idempotent, self-deduping):
#   1. Ask GitHub for build-release.yml runs in the last WIZ_NIGHTLY_MAX_AGE_H
#      hours whose event is `schedule` OR whose event is `workflow_dispatch` AND
#      dispatched by THIS watchdog (tagged via a marker — see below). A tagged
#      release (workflow_dispatch with release_tag) does NOT count: it builds a
#      specific PR branch, not the develop rolling build.
#   2. If a fresh rolling build exists (success or in_progress/queued), do
#      NOTHING (stay silent — no duplicate build, no noise).
#   3. Otherwise dispatch build-release.yml with default (develop) refs, record a
#      claim so we don't re-dispatch every tick while it runs, and print a short
#      report (delivered to the operator by the cron job).
#
# The claim file guards against re-dispatch within a single missed window: once
# we dispatch, we won't dispatch again until either the build finishes and ages
# past the window, or WIZ_NIGHTLY_MAX_AGE_H elapses (whichever the freshness
# check sees first). Because step 1 also counts in_progress/queued runs, a normal
# GitHub-fired nightly is always respected — the watchdog only fills real gaps.
#
# Usage:
#   wiz_nightly_watchdog.sh [--dry-run] [--force]
#     --dry-run : report what it WOULD do; never dispatches. Safe.
#     --force   : dispatch regardless of freshness (manual catch-up).
#
# Output: one human-readable report line + a trailing JSON summary. When there
# is nothing to do it prints a single "fresh" line so the cron log shows a
# heartbeat; set the cron job to deliver only on dispatch if you want silence.

set -uo pipefail

RELEASE_REPO="story-wizard/wizard-release"
BUILD_WORKFLOW="build-release.yml"
MAX_AGE_H="${WIZ_NIGHTLY_MAX_AGE_H:-26}"          # a nightly older than this = a gap
CLAIM_FILE="${WIZ_NIGHTLY_CLAIM:-${HOME}/wizard/tmp/wiz-nightly-watchdog.json}"

# Pin gh to the bot account (same rationale as the rest of the pipeline: the
# active gh account can silently flip to one lacking scopes). Only sets GH_TOKEN
# if not already set and the token is retrievable.
WIZ_GH_ACCOUNT="${WIZ_GH_ACCOUNT:-wiz-maestro}"
if [[ -z "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    _tok="$(gh auth token --user "$WIZ_GH_ACCOUNT" 2>/dev/null)"
    [[ -n "$_tok" ]] && export GH_TOKEN="$_tok"
    unset _tok
fi

# Operational logging goes to STDERR so that, under a `no_agent` cron, STDOUT is
# EMPTY on normal ("fresh") nights => the job stays silent. Only an actionable
# gap-fill writes to STDOUT (delivered verbatim by the cron). Non-zero exits also
# alert regardless (the cron treats non-zero as an error).
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

dry_run=false
force=false
for a in "$@"; do
    case "$a" in
        --dry-run) dry_run=true ;;
        --force)   force=true ;;
        *) echo "{\"ok\":false,\"stage\":\"args\",\"message\":\"unknown arg: ${a}\"}"; exit 1 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo '{"ok":false,"stage":"deps","message":"gh not found"}'; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"stage":"deps","message":"jq not found"}'; exit 1; }

# ---- freshness check: is there a recent ROLLING build? ----
# A rolling build of develop comes from either a `schedule` run or a
# `workflow_dispatch` WITHOUT a release_tag. We can't read dispatch inputs from
# `gh run list`, so we treat ANY schedule run OR any workflow_dispatch run whose
# display title is the default "Build and Release" (tagged builds keep that title
# too, so this is a deliberately CONSERVATIVE over-count: if anything built in
# the window we assume develop is covered and skip — a missed nightly is far more
# likely to show ZERO runs in the window than to be masked by a coincidental
# tagged build every single night). The operator-facing signal that matters is
# "did SOMETHING build recently"; the watchdog exists for the total-gap case.
#
# We specifically COUNT schedule runs (success/in_progress/queued) as the
# authoritative nightly. If a schedule run exists in the window, we're done.
now_epoch="$(date +%s)"
cutoff_epoch=$(( now_epoch - MAX_AGE_H * 3600 ))

runs_json="$(gh run list --repo "$RELEASE_REPO" --workflow "$BUILD_WORKFLOW" \
    --limit 40 --json createdAt,event,status,conclusion,databaseId 2>/dev/null)"

if [[ -z "$runs_json" ]] || ! printf '%s' "$runs_json" | jq -e . >/dev/null 2>&1; then
    log "ERROR: could not list workflow runs (gh/API/scope issue)."
    jq -nc '{ok:false, stage:"list_runs", message:"gh run list failed or returned non-JSON"}'
    exit 1
fi

# Count schedule runs newer than the cutoff (any status — a queued/in-progress
# nightly still means GitHub fired it; don't double up).
fresh_schedule="$(printf '%s' "$runs_json" | jq -r --argjson cut "$cutoff_epoch" '
  [ .[] | select(.event=="schedule") | select((.createdAt|fromdateiso8601) >= $cut) ] | length')"

# Also note the most-recent schedule run overall (for the report).
last_schedule="$(printf '%s' "$runs_json" | jq -r '
  [ .[] | select(.event=="schedule") ] | sort_by(.createdAt) | reverse | .[0]
  | if . == null then "none" else "\(.createdAt) \(.status)/\(.conclusion)" end')"

if [[ "$force" != "true" && "$fresh_schedule" -gt 0 ]]; then
    log "fresh: a scheduled nightly ran within ${MAX_AGE_H}h (last schedule: ${last_schedule}); nothing to do."
    jq -nc --argjson n "$fresh_schedule" --arg last "$last_schedule" \
        '{ok:true, action:"fresh", fresh_schedule_runs:$n, last_schedule:$last}' >&2
    exit 0
fi

# ---- gap detected (or --force): guard against re-dispatch, then dispatch ----
# Claim file prevents dispatching every tick while our own catch-up build runs.
if [[ "$force" != "true" && -f "$CLAIM_FILE" ]]; then
    claim_at="$(jq -r '.dispatched_at // empty' "$CLAIM_FILE" 2>/dev/null)"
    if [[ -n "$claim_at" ]]; then
        claim_epoch="$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$claim_at" +%s 2>/dev/null || echo 0)"
        age_h=$(( (now_epoch - claim_epoch) / 3600 ))
        if [[ "$claim_epoch" -gt 0 && "$age_h" -lt "$MAX_AGE_H" ]]; then
            log "gap detected but we already dispatched a catch-up ${age_h}h ago (< ${MAX_AGE_H}h); waiting."
            jq -nc --arg at "$claim_at" --argjson age "$age_h" \
                '{ok:true, action:"already_dispatched", dispatched_at:$at, age_hours:$age}' >&2
            exit 0
        fi
    fi
fi

if [[ "$dry_run" == "true" ]]; then
    log "[dry-run] GAP: no scheduled nightly within ${MAX_AGE_H}h (last: ${last_schedule}) -> WOULD dispatch a rolling build."
    jq -nc --arg last "$last_schedule" '{ok:true, action:"would_dispatch", dry_run:true, last_schedule:$last}'
    exit 0
fi

dispatch_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
disp_out="$(gh workflow run "$BUILD_WORKFLOW" --repo "$RELEASE_REPO" 2>&1)"
disp_rc=$?
if [[ $disp_rc -ne 0 ]]; then
    log "ERROR: dispatch failed (rc=${disp_rc}): ${disp_out}"
    jq -nc --arg out "$disp_out" '{ok:false, stage:"dispatch", message:$out}'
    exit 1
fi

mkdir -p "$(dirname "$CLAIM_FILE")" 2>/dev/null || true
jq -nc --arg at "$dispatch_at" --arg last "$last_schedule" \
    '{dispatched_at:$at, reason:"missed_nightly", last_schedule_before:$last}' \
    > "$CLAIM_FILE" 2>/dev/null || true

log "GAP FILLED: GitHub skipped the nightly (last schedule: ${last_schedule}). Dispatched a rolling build of develop."
jq -nc --arg at "$dispatch_at" --arg last "$last_schedule" \
    '{ok:true, action:"dispatched", dispatched_at:$at, last_schedule_before:$last,
      note:"GitHub scheduled nightly was missed; watchdog dispatched a catch-up rolling build."}'
