#!/usr/bin/env bash
# Files the recurring "Symphony upkeep" issue into the symphony lane.
# OpsIssue dedupes by open title, so running this on any cadence guarantees
# at most one open upkeep issue; a new one appears only after the lane
# completes the previous cycle. Zero human action anywhere.
set -euo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"

cd "$REPO_ROOT/elixir"
mise exec -- mix ops.file_issue \
  --title "Symphony upkeep" \
  --body "Recurring maintenance cycle. Follow the 'Upkeep issues' flow in elixir/WORKFLOW.md: gate + docs.check, metrics/log patterns, hygiene report, re-open eligible Deferred issues, rule telemetry, file one deduplicated issue per recurring friction, write the daily digest, then complete this issue."
