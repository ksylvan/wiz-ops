#!/usr/bin/env bash
# _maestro_env.sh — Resolve the Maestro CLI path and user-data dir.
#
# Source (do NOT execute) this from the maestro_*.sh scripts. After sourcing,
# the variable `maestro_cli` holds the path to the maestro-cli.js to invoke
# with `node`, and MAESTRO_USER_DATA is exported only when appropriate.
#
# Resolution order:
#   1. A sibling .env file (next to this helper) is sourced if present, so a
#      developer can point the scripts at a checked-out rc/preview branch.
#      See .env.example.
#   2. If MAESTRO_CLI_JS is set (typically from .env or the environment), it
#      wins, and MAESTRO_USER_DATA is honored as given.
#   3. Otherwise, if the installed Maestro.app CLI exists, use it and leave
#      MAESTRO_USER_DATA untouched — the app manages its own data location.
#   4. Otherwise fall back to the dev preview worktree CLI + maestro-dev data.

# Directory holding this helper (and any sibling .env).
_maestro_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Source a sibling .env, if present.
if [[ -f "${_maestro_env_dir}/.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${_maestro_env_dir}/.env"
fi

_maestro_installed_cli="/Applications/Maestro.app/Contents/Resources/maestro-cli.js"

# maestro_cli is consumed by the script that sources this helper.
# shellcheck disable=SC2034
if [[ -n "${MAESTRO_CLI_JS:-}" ]]; then
    # 2. Explicit override (env or .env) wins; honor MAESTRO_USER_DATA as given.
    maestro_cli="${MAESTRO_CLI_JS}"
elif [[ -f "${_maestro_installed_cli}" ]]; then
    # 3. Installed app: use its CLI, do NOT override MAESTRO_USER_DATA.
    maestro_cli="${_maestro_installed_cli}"
else
    # 4. Dev fallback: preview worktree CLI + maestro-dev data dir.
    maestro_cli="${HOME}/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
    export MAESTRO_USER_DATA="${MAESTRO_USER_DATA:-${HOME}/Library/Application Support/maestro-dev}"
fi

unset _maestro_env_dir _maestro_installed_cli
