#!/usr/bin/env bash
# Health-checks the lane daemon (the alpine incident showed BEAM-alive but
# HTTP-dead zombies that KeepAlive cannot see). Unhealthy -> kick the launchd
# job AND file the deduplicated ops issue (CONSTITUTION.md C4).
set -uo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${SYMPHONY_LANE_PORT:-4767}"
LABEL="com.symphony.lane"

body="$(curl -sf -m 5 "http://127.0.0.1:$PORT/api/v1/state" || true)"
if [[ "$body" == *'"status":"healthy"'* ]]; then
  exit 0
fi

echo "lane unhealthy on port $PORT; restarting $LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"
(cd "$REPO_ROOT/elixir" && mise exec -- mix ops.file_issue \
  --title "watchdog restarted the symphony lane daemon" \
  --body "The lane daemon on port $PORT failed its health check and was restarted by the watchdog. If this recurs, the daemon has a boot or bind defect — investigate logs under ~/.cache/symphony-upkeep/logs.") || \
  echo "WARNING: watchdog could not file the ops issue"
