#!/usr/bin/env bash
# Installs the durable lane stack: KeepAlive daemon, 5-minute watchdog, and
# weekly credential probe. Idempotent; refuses paths that would corrupt the
# sed render.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_ROOT="${SYMPHONY_LANE_LOGS_ROOT:-$HOME/.cache/symphony-upkeep/logs}"

case "$REPO_ROOT$LOGS_ROOT" in
  *"|"* | *"&"* | *"\\"* | *"<"* | *">"*)
    echo "paths containing | & \\ < > would corrupt the sed/XML render" >&2
    exit 1
    ;;
esac

mkdir -p "$LOGS_ROOT" "$HOME/Library/LaunchAgents"

for label in com.symphony.lane com.symphony.lane-watchdog com.symphony.credential-probe com.symphony.auto-promote; do
  plist="$HOME/Library/LaunchAgents/$label.plist"
  sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" -e "s|__LOGS_ROOT__|$LOGS_ROOT|g" -e "s|__HOME__|$HOME|g" \
    "$SCRIPT_DIR/launchd/$label.plist.template" > "$plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "installed $label"
done
