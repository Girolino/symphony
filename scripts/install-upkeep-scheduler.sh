#!/usr/bin/env bash
# Renders and loads the upkeep heartbeat LaunchAgent. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_ROOT="${SYMPHONY_UPKEEP_LOGS_ROOT:-$HOME/.cache/symphony-upkeep/logs}"
LABEL="com.symphony.upkeep-heartbeat"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "$REPO_ROOT$LOGS_ROOT" in
  *"|"* | *"&"* | *"\\"* | *"<"* | *">"*)
    echo "paths containing | & \\ < > would corrupt the sed/XML render" >&2
    exit 1
    ;;
esac

mkdir -p "$LOGS_ROOT" "$HOME/Library/LaunchAgents"
sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" -e "s|__LOGS_ROOT__|$LOGS_ROOT|g" -e "s|__HOME__|$HOME|g" \
  "$SCRIPT_DIR/launchd/$LABEL.plist.template" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (daily 09:00) -> $PLIST"
