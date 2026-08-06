#!/usr/bin/env bash
# Health-checks the lane daemon (the alpine incident showed BEAM-alive but
# HTTP-dead zombies that KeepAlive cannot see). Dead, stale, or malformed
# health -> kick the launchd job AND file the deduplicated ops issue
# (CONSTITUTION.md C4).
set -uo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${SYMPHONY_LANE_PORT:-4767}"
LABEL="com.symphony.lane"
# Probe immediately, then once per second through the supported 30s boot window
# used by the release promotion path.
READBACK_ATTEMPTS="${SYMPHONY_WATCHDOG_READBACK_ATTEMPTS:-31}"
READBACK_SLEEP_SECONDS="${SYMPHONY_WATCHDOG_READBACK_SLEEP_SECONDS:-1}"

case "$READBACK_ATTEMPTS" in
  "" | *[!0-9]*) READBACK_ATTEMPTS=31 ;;
esac

case "$READBACK_SLEEP_SECONDS" in
  "" | *[!0-9]*) READBACK_SLEEP_SECONDS=1 ;;
esac

if [ "$READBACK_ATTEMPTS" -lt 1 ]; then
  READBACK_ATTEMPTS=31
fi

state_url() {
  printf 'http://127.0.0.1:%s/api/v1/state' "$PORT"
}

probe_body() {
  curl -sf -m 5 "$(state_url)" || true
}

parse_health_fields() {
  local payload="$1"

  printf '%s' "$payload" | (cd "$REPO_ROOT/elixir" && mise exec -- elixir -e '
input = IO.read(:stdio, :eof)

try do
  case :json.decode(input) do
    %{"health" => health} when is_map(health) ->
      status = Map.get(health, "status")
      degraded_reason = Map.get(health, "degraded_reason")

      normalized_status =
        case status do
          value when value in ["healthy", "degraded", "stale", "unavailable"] -> value
          value when is_binary(value) -> "invalid"
          _ -> "missing"
        end

      IO.write(normalized_status)
      IO.write("\t")

      if is_binary(degraded_reason) do
        IO.write(String.replace(degraded_reason, ~r/[\t\r\n]+/, " "))
      end

    _ ->
      IO.write("missing\t")
  end
rescue
  _ -> IO.write("missing\t")
end
') 2>/dev/null || true
}

live_health_status() {
  case "$1" in
    healthy | degraded) return 0 ;;
    *) return 1 ;;
  esac
}

probe_detail() {
  local payload="$1"
  local status="$2"
  local degraded="$3"
  local detail="health.status=${status:-missing}"

  if [ -n "$degraded" ]; then
    detail="$detail degraded_reason=$degraded"
  fi

  if [ -n "$payload" ]; then
    detail="$detail probe_returned_body=true"
  else
    detail="$detail probe_returned_body=false"
  fi

  printf '%s' "$detail"
}

body="$(probe_body)"
health_fields="$(parse_health_fields "$body")"
IFS=$'\t' read -r health_status degraded_reason <<< "$health_fields"

if live_health_status "$health_status"; then
  exit 0
fi

detail="$(probe_detail "$body" "$health_status" "$degraded_reason")"

echo "lane unhealthy on port $PORT ($detail); restarting $LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null
kickstart_status=$?

verified=0
readback_body=""
readback_health_status=""
readback_degraded_reason=""

if [ "$kickstart_status" -eq 0 ]; then
  for ((_attempt = 1; _attempt <= READBACK_ATTEMPTS; _attempt++)); do
    readback_body="$(probe_body)"
    readback_health_fields="$(parse_health_fields "$readback_body")"
    IFS=$'\t' read -r readback_health_status readback_degraded_reason <<< "$readback_health_fields"

    if live_health_status "$readback_health_status"; then
      verified=1
      break
    fi

    if [ "$_attempt" -lt "$READBACK_ATTEMPTS" ] && [ "$READBACK_SLEEP_SECONDS" -gt 0 ]; then
      sleep "$READBACK_SLEEP_SECONDS"
    fi
  done
fi

readback_detail="$(probe_detail "$readback_body" "$readback_health_status" "$readback_degraded_reason")"

if [ "$verified" -eq 1 ]; then
  issue_title="watchdog restarted the symphony lane daemon"
  issue_body="The lane daemon on port $PORT failed its daemon-liveness health check ($detail) and was restarted by the watchdog; recovery readback reported $readback_detail. If this recurs, the daemon has a boot or bind defect — investigate logs under ~/.cache/symphony-upkeep/logs."
  echo "lane restart verified on port $PORT ($readback_detail)"
else
  issue_title="watchdog failed to restart the symphony lane daemon"
  if [ "$kickstart_status" -ne 0 ]; then
    issue_body="The lane daemon on port $PORT failed its daemon-liveness health check ($detail), and the watchdog restart attempt failed because launchctl exited $kickstart_status. If this recurs, the daemon has a boot or bind defect — investigate logs under ~/.cache/symphony-upkeep/logs."
    echo "lane restart failed on port $PORT (launchctl_exit=$kickstart_status)"
  else
    issue_body="The lane daemon on port $PORT failed its daemon-liveness health check ($detail), and the watchdog kicked launchd but recovery readback did not return live health ($readback_detail). If this recurs, the daemon has a boot or bind defect — investigate logs under ~/.cache/symphony-upkeep/logs."
    echo "lane restart unverified on port $PORT ($readback_detail)"
  fi
fi

export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"
(cd "$REPO_ROOT/elixir" && mise exec -- mix ops.file_issue \
  --title "$issue_title" \
  --body "$issue_body") || \
  echo "WARNING: watchdog could not file the ops issue"
