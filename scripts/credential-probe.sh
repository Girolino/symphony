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
temp_headers=()

cleanup_headers() {
  for hdr in "${temp_headers[@]}"; do
    [ -n "$hdr" ] && rm -f "$hdr"
  done
}
trap cleanup_headers EXIT

KEY_FILE="$HOME/.config/linear-codex/env"
PRIMARY_KEY="${LINEAR_API_KEY:-}"
BOOTSTRAP_KEY="$(sed -n 's/^LINEAR_API_KEY=//p' "$KEY_FILE" 2>/dev/null | head -1 | tr -d '"' | tr -d "'")"

check_linear_key() {
  local label="$1"
  local key="$2"
  local hdr
  local status

  if [ -z "$key" ]; then
    failures+=("$label missing")
    return 1
  fi

  # Header via file: the key must never appear in process argv (RV-S1).
  hdr="$(mktemp 2>/dev/null)" || {
    failures+=("$label validation failed (temporary header unavailable)")
    return 1
  }
  temp_headers+=("$hdr")
  chmod 600 "$hdr"
  printf 'Authorization: %s\n' "$key" > "$hdr"

  status="$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
    -H @"$hdr" -H "Content-Type: application/json" \
    -d '{"query":"query { viewer { id } }"}' https://api.linear.app/graphql 2>/dev/null)"
  status="${status:-000}"

  if [ "$status" = "200" ]; then
    return 0
  fi

  failures+=("$label invalid (viewer query returned $status)")
  return 1
}

primary_ok=0
bootstrap_ok=0
check_linear_key "LINEAR_API_KEY primary" "$PRIMARY_KEY" && primary_ok=1
check_linear_key "LINEAR_API_KEY bootstrap file $KEY_FILE" "$BOOTSTRAP_KEY" && bootstrap_ok=1

if ! gh auth status >/dev/null 2>&1; then
  failures+=("gh auth status failed (GitHub credential)")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "credential probe: all capabilities valid (by name)"
  exit 0
fi

printf 'credential probe failures:\n'; printf ' - %s\n' "${failures[@]}"
body="$(printf 'The weekly credential probe found:\n'; printf ' - %s\n' "${failures[@]}"; printf '\nRotate or re-authenticate the named credential. Values are never printed.')"

filed=0
# Linear filing needs a known-good Linear credential. If the primary failed but
# the bootstrap file is healthy, explicitly remove the bad primary env so
# mix ops.file_issue can resolve through the documented bootstrap path.
if [ "$primary_ok" = "1" ]; then
  (cd "$REPO_ROOT/elixir" && LINEAR_API_KEY="$PRIMARY_KEY" mise exec -- mix ops.file_issue \
    --title "credential probe failure" --body "$body") && filed=1
elif [ "$bootstrap_ok" = "1" ]; then
  (cd "$REPO_ROOT/elixir" && env -u LINEAR_API_KEY mise exec -- mix ops.file_issue \
    --title "credential probe failure" --body "$body") && filed=1
fi

# When Linear itself is down/expired, fall back to a GitHub issue on the fork.
if [ "$filed" = "0" ] && gh auth status >/dev/null 2>&1; then
  existing="$(gh issue list -R Girolino/symphony --state open --search 'credential probe failure in:title' --json number --jq 'length' 2>/dev/null || echo 0)"
  if [ "${existing:-0}" = "0" ]; then
    gh issue create -R Girolino/symphony --title "credential probe failure" --body "$body" && filed=1
  else
    filed=1
  fi
fi

# Last resort: a durable local marker the upkeep lane and operator can see.
if [ "$filed" = "0" ]; then
  mkdir -p "$REPO_ROOT/qa-output"
  printf '%s\n\n%s\n' "$(date -u +%FT%TZ)" "$body" > "$REPO_ROOT/qa-output/credential-ALERT.md"
  echo "WARNING: all issue channels unavailable; durable marker written to qa-output/credential-ALERT.md"
fi
exit 1
