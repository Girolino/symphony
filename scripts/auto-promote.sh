#!/usr/bin/env bash
# The autonomous promotion driver: when origin/main is ahead of the current
# release pin, run the full promote pipeline (gate, boot check, verified flip,
# real smoke, auto-rollback) from a DEDICATED clone — never from a shared dev
# checkout. Runs on a launchd timer; promote.sh's lock serializes concurrent
# fires. Closes the land->live gap with zero human action (C7).
set -euo pipefail
unset NODE_OPTIONS

RELEASES_ROOT="${SYMPHONY_RELEASES_ROOT:-$HOME/.cache/symphony-releases}"
PROMOTE_REPO="${SYMPHONY_PROMOTE_REPO:-$HOME/.cache/symphony-promote/repo}"
ORIGIN_URL="git@github.com:Girolino/symphony.git"
export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"
export SYMPHONY_LIVE_LINEAR_TEAM_KEY="${SYMPHONY_LIVE_LINEAR_TEAM_KEY:-SYM}"

if [ ! -d "$PROMOTE_REPO/.git" ]; then
  mkdir -p "$(dirname "$PROMOTE_REPO")"
  git clone --quiet "$ORIGIN_URL" "$PROMOTE_REPO"
fi

cd "$PROMOTE_REPO"
git fetch origin --quiet
git checkout --quiet main
git reset --hard --quiet origin/main

main_sha="$(git rev-parse HEAD)"
current_sha="$(basename "$(readlink "$RELEASES_ROOT/current" 2>/dev/null || echo none)")"

if [ "$main_sha" = "$current_sha" ]; then
  echo "auto-promote: current release already at origin/main ($main_sha)"
  exit 0
fi

echo "auto-promote: promoting $main_sha (current pin: $current_sha)"
# --skip-gate --no-push: this SHA is already on origin/main (we reset to it),
# so it already passed CI and is already pushed. Re-running the full gate and
# re-pushing here only re-triggers timing-sensitive tests under the loaded
# promote environment — the recurring flaky-gate blocker. The boot check and
# real smoke still validate the actual release artifact; rollback still
# protects against a genuinely broken release.
# One Linear API key is shared by every daemon; the promote smoke runs a real
# Codex turn that needs Linear rate-limit headroom to complete its disposable
# issue. Quiesce the always-on lane (and its watchdog, so it doesn't fight the
# pause) for the promote window so the smoke gets the budget to itself. The
# trap guarantees both come back on any exit. Lane-daemon management lives here
# (symphony-specific), never in the generic promote.sh.
UID_NUM="$(id -u)"
quiesce() { launchctl bootout "gui/$UID_NUM/$1" 2>/dev/null || true; }
resume() { launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$1.plist" 2>/dev/null || true; }
restore_daemons() {
  resume com.symphony.lane-watchdog
  resume com.symphony.lane
}
trap restore_daemons EXIT

echo "auto-promote: quiescing lane + watchdog for the smoke window"
quiesce com.symphony.lane-watchdog
quiesce com.symphony.lane

"$PROMOTE_REPO/scripts/promote.sh" --skip-gate --no-push
