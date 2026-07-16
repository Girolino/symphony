#!/usr/bin/env bash
# Runs the Symphony self-maintenance lane daemon from the PROMOTED release
# (CONSTITUTION.md C7: the pin moves only through promote.sh). Resolves the
# Linear key at the edge and marks the environment as an agent lane so
# constitution.check enforces the protected-file boundary.
set -euo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="${SYMPHONY_RELEASES_ROOT:-$HOME/.cache/symphony-releases}/current"
PORT="${SYMPHONY_LANE_PORT:-4767}"
LOGS_ROOT="${SYMPHONY_LANE_LOGS_ROOT:-$HOME/.cache/symphony-upkeep/logs}"

if [ ! -x "$RELEASE/elixir/bin/symphony" ]; then
  echo "no promoted release at $RELEASE; run scripts/promote.sh first" >&2
  exit 1
fi

KEY_FILE="$HOME/.config/linear-codex/env"
if [ -z "${LINEAR_API_KEY:-}" ] && [ -f "$KEY_FILE" ]; then
  LINEAR_API_KEY="$(sed -n 's/^LINEAR_API_KEY=//p' "$KEY_FILE" | head -1 | tr -d '"' | tr -d "'")"
  export LINEAR_API_KEY
fi

export SYMPHONY_AGENT_LANE=1
export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"

mkdir -p "$LOGS_ROOT"
cd "$RELEASE/elixir"
mise trust --quiet 2>/dev/null || true
exec mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$REPO_ROOT/elixir/WORKFLOW.md" --logs-root "$LOGS_ROOT" --port "$PORT"
