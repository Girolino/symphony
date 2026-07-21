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
temp_files=()

cleanup_temp_files() {
  for tmp in "${temp_files[@]}"; do
    [ -n "$tmp" ] && rm -f "$tmp"
  done
}
trap cleanup_temp_files EXIT

KEY_FILE="$HOME/.config/linear-codex/env"

read_linear_key_file() {
  local path="$1"

  sed -n 's/^LINEAR_API_KEY=//p' "$path" 2>/dev/null | head -1 | tr -d '"' | tr -d "'"
}

FILE_KEY="$(read_linear_key_file "$KEY_FILE")"
PRIMARY_KEY="${LINEAR_API_KEY:-}"
PRIMARY_LABEL="LINEAR_API_KEY primary"
BOOTSTRAP_KEY=""
BOOTSTRAP_LABEL="LINEAR_API_KEY bootstrap file $KEY_FILE"

# The scheduled LaunchAgent mirrors scripts/lane-daemon.sh: it may provide only
# PATH, while the daemon resolves LINEAR_API_KEY from the configured env file.
if [ -z "$PRIMARY_KEY" ] && [ -n "$FILE_KEY" ]; then
  PRIMARY_KEY="$FILE_KEY"
  PRIMARY_LABEL="LINEAR_API_KEY primary file $KEY_FILE"
elif [ -n "$FILE_KEY" ]; then
  BOOTSTRAP_KEY="$FILE_KEY"
fi

parse_linear_viewer_payload() {
  local body_file="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "JSON parser unavailable"
    return 1
  fi

  python3 - "$body_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    print("invalid JSON")
    sys.exit(1)

errors = payload.get("errors")
if isinstance(errors, list) and errors:
    print("GraphQL errors")
    sys.exit(1)

data = payload.get("data")
viewer = data.get("viewer") if isinstance(data, dict) else None
viewer_id = viewer.get("id") if isinstance(viewer, dict) else None

if not isinstance(viewer_id, str) or not viewer_id.strip():
    print("missing viewer id")
    sys.exit(1)

print("ok")
PY
}

check_linear_key() {
  local label="$1"
  local key="$2"
  local hdr
  local body_file
  local payload_status
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
  temp_files+=("$hdr")
  chmod 600 "$hdr"
  printf 'Authorization: %s\n' "$key" > "$hdr"

  body_file="$(mktemp 2>/dev/null)" || {
    failures+=("$label validation failed (temporary body unavailable)")
    return 1
  }
  temp_files+=("$body_file")

  status="$(curl -sS -w "%{http_code}" -o "$body_file" -m 10 \
    -H @"$hdr" -H "Content-Type: application/json" \
    -d '{"query":"query { viewer { id } }"}' https://api.linear.app/graphql 2>/dev/null)"
  status="${status:-000}"

  if [ "$status" != "200" ]; then
    failures+=("$label invalid (viewer query returned HTTP $status)")
    return 1
  fi

  payload_status="$(parse_linear_viewer_payload "$body_file")"
  if [ "$payload_status" = "ok" ]; then
    return 0
  fi

  failures+=("$label invalid (viewer query returned $payload_status)")
  return 1
}

primary_ok=0
bootstrap_ok=0
check_linear_key "$PRIMARY_LABEL" "$PRIMARY_KEY" && primary_ok=1
if [ -n "$BOOTSTRAP_KEY" ]; then
  check_linear_key "$BOOTSTRAP_LABEL" "$BOOTSTRAP_KEY" && bootstrap_ok=1
fi

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
