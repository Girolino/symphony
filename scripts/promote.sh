#!/usr/bin/env bash
# Symphony blue-green promotion. Idempotent and safe to re-run.
#
# Pipeline: full gate -> ff-push HEAD to origin main -> versioned release build
# -> boot health check (memory tracker, no Linear usage) -> atomic `current`
# symlink flip -> optional consumer control commands -> real prod smoke
# -> on any post-flip failure: flip back to the previous release, rerun the
# consumer commands, and auto-file a deduplicated Linear issue with the report.
#
# Environment:
#   SYMPHONY_RELEASES_ROOT        release store (default ~/.cache/symphony-releases)
#   SYMPHONY_PROMOTE_BOOT_PORT    boot-check port (default 4798)
#   SYMPHONY_PROMOTE_CONSUMER_CMDS newline-separated repo-owned control commands
#                                 run after every flip (forward and rollback)
#   SYMPHONY_OPS_TEAM_KEY / SYMPHONY_OPS_PROJECT_SLUG  target for FAIL issues
#
# Flags: --skip-gate --skip-smoke --no-push (each narrows the pipeline; the
# default full run is the promotion contract).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ELIXIR_DIR="$REPO_ROOT/elixir"
RELEASES_ROOT="${SYMPHONY_RELEASES_ROOT:-$HOME/.cache/symphony-releases}"
CURRENT_LINK="$RELEASES_ROOT/current"
BOOT_PORT="${SYMPHONY_PROMOTE_BOOT_PORT:-4798}"
CONSUMER_CMDS="${SYMPHONY_PROMOTE_CONSUMER_CMDS:-}"

SKIP_GATE=0
SKIP_SMOKE=0
NO_PUSH=0

for arg in "$@"; do
  case "$arg" in
    --skip-gate) SKIP_GATE=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --no-push) NO_PUSH=1 ;;
    *) echo "[promote] unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '[promote] %s\n' "$*"; }

BOOT_PID=""
BOOT_TMP=""
cleanup_boot() {
  if [ -n "$BOOT_PID" ] && kill -0 "$BOOT_PID" 2>/dev/null; then
    kill -TERM "$BOOT_PID" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true
  fi
  BOOT_PID=""
  if [ -n "$BOOT_TMP" ]; then
    rm -rf "$BOOT_TMP"
    BOOT_TMP=""
  fi
}
trap cleanup_boot EXIT

run_consumer_cmds() {
  if [ -z "$CONSUMER_CMDS" ]; then
    log "no consumer control commands configured"
    return 0
  fi
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    log "consumer: $cmd"
    if ! bash -lc "$cmd"; then
      log "consumer command failed (continuing): $cmd"
    fi
  done <<< "$CONSUMER_CMDS"
}

file_fail_issue() {
  local title="$1" body_file="$2"
  log "filing FAIL issue: $title"
  (cd "$ELIXIR_DIR" && mise exec -- mix ops.file_issue --title "$title" --body-file "$body_file") ||
    log "WARNING: could not file the FAIL issue; report kept at $body_file"
}

latest_report() {
  ls -t "$REPO_ROOT/qa-output"/prod-smoke-*.json 2>/dev/null | head -1
}

flip_to() {
  local target="$1"
  mkdir -p "$RELEASES_ROOT"
  local tmp_link
  tmp_link="$(mktemp -u "$RELEASES_ROOT/.current.XXXXXX")"
  ln -s "$target" "$tmp_link"
  mv -f "$tmp_link" "$CURRENT_LINK"
  log "current -> $target"
}

boot_check() {
  local release_dir="$1"
  BOOT_TMP="$(mktemp -d)"
  cat > "$BOOT_TMP/WORKFLOW.md" <<'EOF'
---
tracker:
  kind: memory
polling:
  interval_ms: 60000
workspace:
  root: BOOT_WORKSPACES
agent:
  max_concurrent_agents: 1
observability:
  enabled: false
---

Boot check prompt (never dispatched: memory tracker has no issues).
EOF
  mkdir -p "$BOOT_TMP/workspaces"
  sed -i '' "s|BOOT_WORKSPACES|$BOOT_TMP/workspaces|" "$BOOT_TMP/WORKFLOW.md"

  log "boot check on port $BOOT_PORT"
  "$release_dir/elixir/bin/symphony" \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    "$BOOT_TMP/WORKFLOW.md" --logs-root "$BOOT_TMP/logs" --port "$BOOT_PORT" &
  BOOT_PID=$!

  local deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sf -m 2 "http://127.0.0.1:$BOOT_PORT/api/v1/state" | grep -q '"status":"healthy"'; then
      log "boot check healthy"
      cleanup_boot
      return 0
    fi
    sleep 1
  done

  log "boot check FAILED"
  cleanup_boot
  return 1
}

# ── 1. Gate ────────────────────────────────────────────────────────────────
cd "$REPO_ROOT"
SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short HEAD)"

if [ "$SKIP_GATE" -eq 1 ]; then
  log "gate skipped by flag"
else
  log "running full gate on $SHORT_SHA"
  (cd "$ELIXIR_DIR" && mise exec -- make all)
fi

# ── 2. Advance main (fast-forward only) ────────────────────────────────────
if [ "$NO_PUSH" -eq 1 ]; then
  log "push skipped by flag"
else
  git fetch origin
  if ! git merge-base --is-ancestor origin/main "$SHA"; then
    log "FAIL: origin/main is not an ancestor of HEAD; reconcile history first"
    exit 1
  fi
  log "pushing $SHORT_SHA to origin main (ff-only)"
  git push origin "$SHA:refs/heads/main"
fi

# ── 3. Versioned release build ─────────────────────────────────────────────
RELEASE_DIR="$RELEASES_ROOT/$SHA"
if [ -x "$RELEASE_DIR/elixir/bin/symphony" ]; then
  log "release $SHORT_SHA already built"
else
  log "building release $SHORT_SHA"
  BUILD_TMP="$(mktemp -d "$RELEASES_ROOT/.build.XXXXXX" 2>/dev/null || mktemp -d)"
  git archive "$SHA" | tar -x -C "$BUILD_TMP"
  (cd "$BUILD_TMP/elixir" && mise trust --quiet 2>/dev/null || true)
  (cd "$BUILD_TMP/elixir" && mise exec -- mix setup && mise exec -- mix build)
  mkdir -p "$RELEASES_ROOT"
  rm -rf "$RELEASE_DIR"
  mv "$BUILD_TMP" "$RELEASE_DIR"
fi

# ── 4. Boot health check (pre-flip; no production impact) ─────────────────
boot_check "$RELEASE_DIR"

# ── 5. Atomic flip with rollback memory ────────────────────────────────────
PREVIOUS_TARGET=""
if [ -L "$CURRENT_LINK" ]; then
  PREVIOUS_TARGET="$(readlink "$CURRENT_LINK")"
fi
flip_to "$RELEASE_DIR"
run_consumer_cmds

# ── 6. Real production smoke; rollback on failure ──────────────────────────
if [ "$SKIP_SMOKE" -eq 1 ]; then
  log "smoke skipped by flag; promotion of $SHORT_SHA complete (UNSMOKED)"
  exit 0
fi

log "running prod smoke against release $SHORT_SHA"
if (cd "$ELIXIR_DIR" && mise exec -- mix prod.smoke --escript-path "$RELEASE_DIR/elixir/bin/symphony"); then
  log "PROMOTION PASS: $SHORT_SHA is live"
  exit 0
fi

log "smoke FAILED; rolling back"
if [ -n "$PREVIOUS_TARGET" ]; then
  flip_to "$PREVIOUS_TARGET"
  run_consumer_cmds
  ROLLBACK_NOTE="rolled back to $(basename "$PREVIOUS_TARGET")"
else
  ROLLBACK_NOTE="no previous release existed; current left on $SHORT_SHA (bootstrap promotion)"
  log "$ROLLBACK_NOTE"
fi

REPORT="$(latest_report || true)"
BODY_FILE="${REPORT:-$(mktemp)}"
if [ -z "${REPORT:-}" ]; then
  echo "prod smoke failed for $SHA but no report file was found. $ROLLBACK_NOTE" > "$BODY_FILE"
fi
file_fail_issue "promote FAIL: smoke failed on $SHORT_SHA" "$BODY_FILE"
log "PROMOTION FAIL: $ROLLBACK_NOTE"
exit 1
