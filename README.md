# wiz-ops

Operational scripts and tooling for the [story-wizard](https://github.com/story-wizard) repositories.

## Overview

This repo collects convenience scripts that support day-to-day development workflows across the Wizard ecosystem — starting with PR review automation.

## Requirements

- [`gh`](https://cli.github.com/) — GitHub CLI, authenticated
- [`jq`](https://stedolan.github.io/jq/)
- [`node`](https://nodejs.org/) (for the Maestro CLI)
- A local clone of the [Maestro](https://github.com/ksylvan/Maestro) `preview` worktree at `~/src/worktrees/Maestro/preview`
- Code Review playbooks at `~/src/maestro-playbooks-custom/playbooks/Code_Review/`
- Worktree helper functions sourced from `~/.zshrc.d/80-git-worktrees.zsh`

## Scripts

### `setup_pr.sh` — PR Review Setup

Sets up a full, isolated PR review environment for a given repo and PR number.

**Usage:**

```zsh
./setup_pr.sh <repo> <pr_number>
```

**Arguments:**

| Argument | Description |
|---|---|
| `repo` | One of: `wizard`, `wizard-ai`, `wizard-core` |
| `pr_number` | The PR number (numeric) |

**Examples:**

```zsh
./setup_pr.sh wizard-core 209
./setup_pr.sh wizard 42
```

**What it does:**

1. Validates the PR is open and not a draft
2. Creates a git worktree named `<repo>-<pr_number>` under `~/wizard/worktrees/<repo>/`
3. Creates autorun directories and copies Code Review playbooks into `~/wizard/worktrees/autorun/<repo>/<worktree>/development/code-review/`
4. Patches the correct PR URL into `1_ANALYZE_CHANGES.md`
5. Checks out the PR branch in the worktree via `gh pr checkout`
6. Creates a `claude-code` Maestro agent scoped to the worktree with a "no changes" nudge message
7. Triggers the auto-run sequence against the playbooks

The agent is always nudged with: _"Do not make any changes this is only a review task."_
Worktree cleanup is left to the user after the review is complete.
