#!/usr/bin/env bash
# Weekly credential validity probe (names only, never values): an expired key
# must surface as a queued issue BEFORE it silently breaks the lanes.
set -uo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SYMPHONY_OPS_TEAM_KEY="${SYMPHONY_OPS_TEAM_KEY:-SYM}"
export SYMPHONY_OPS_PROJECT_SLUG="${SYMPHONY_OPS_PROJECT_SLUG:-3c60ffa59268}"

failures=()

KEY_FILE="$HOME/.config/linear-codex/env"
KEY="$(sed -n 's/^LINEAR_API_KEY=//p' "$KEY_FILE" 2>/dev/null | head -1 | tr -d '"' | tr -d "'")"
if [ -z "$KEY" ]; then
  failures+=("LINEAR_API_KEY missing from $KEY_FILE")
else
  status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
    -H "Authorization: $KEY" -H "Content-Type: application/json" \
    -d '{"query":"query { viewer { id } }"}' https://api.linear.app/graphql)
  [ "$status" = "200" ] || failures+=("LINEAR_API_KEY invalid (viewer query returned $status)")
fi

if ! gh auth status >/dev/null 2>&1; then
  failures+=("gh auth status failed (GitHub credential)")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "credential probe: all capabilities valid (by name)"
  exit 0
fi

printf 'credential probe failures:\n'; printf ' - %s\n' "${failures[@]}"
(cd "$REPO_ROOT/elixir" && mise exec -- mix ops.file_issue \
  --title "credential probe failure" \
  --body "$(printf 'The weekly credential probe found:\n'; printf ' - %s\n' "${failures[@]}"; printf '\nRotate or re-authenticate the named credential. Values are never printed.')") || \
  echo "WARNING: could not file the credential ops issue"
exit 1
