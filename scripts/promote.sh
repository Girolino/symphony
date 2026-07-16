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

# Interactive agent sessions leak NODE_OPTIONS preloads that kill any Node
# subprocess (codex) spawned downstream. Promotion always runs clean.
unset NODE_OPTIONS

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
    # The escript may survive a TERM to the mise wrapper; kill by workflow path.
    pkill -f "$BOOT_TMP/WORKFLOW.md" 2>/dev/null || true
    rm -rf "$BOOT_TMP"
    BOOT_TMP=""
  fi
}
trap cleanup_boot EXIT

# Returns non-zero when any consumer command fails: a release is not live
# until every consumer activated it, and a failed rollback activation must
# surface as a promotion failure rather than a log line.
run_consumer_cmds() {
  local failures=0
  if [ -z "$CONSUMER_CMDS" ]; then
    log "no consumer control commands configured"
    return 0
  fi
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    log "consumer: $cmd"
    if ! bash -lc "$cmd"; then
      log "consumer command FAILED: $cmd"
      failures=$((failures + 1))
    fi
  done <<< "$CONSUMER_CMDS"
  [ "$failures" -eq 0 ]
}

file_fail_issue() {
  local title="$1" body_file="$2"
  log "filing FAIL issue: $title"
  (cd "$ELIXIR_DIR" && mise exec -- mix ops.file_issue --title "$title" --body-file "$body_file") ||
    log "WARNING: could not file the FAIL issue; report kept at $body_file"
}

# Reports are scoped per promotion run so a FAIL issue can never attach a
# stale report from an earlier invocation.
PROMO_REPORT_DIR=""

latest_report() {
  ls -t "$PROMO_REPORT_DIR"/prod-smoke-*.json 2>/dev/null | head -1
}

flip_to() {
  local target="$1"
  mkdir -p "$RELEASES_ROOT"
  local tmp_link
  tmp_link="$(mktemp -u "$RELEASES_ROOT/.current.XXXXXX")"
  ln -s "$target" "$tmp_link"
  # -h replaces the symlink itself; plain -f follows a symlink-to-directory and
  # drops the temp link INSIDE the old release, silently keeping the old pin.
  mv -fh "$tmp_link" "$CURRENT_LINK"

  local resolved
  resolved="$(readlink "$CURRENT_LINK" || true)"
  if [ "$resolved" != "$target" ]; then
    log "FAIL: current flip did not land (points at ${resolved:-nothing})"
    return 1
  fi
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

  # The health probe must be answered by OUR spawned process — an unrelated
  # daemon already on the port would greenlight an untested release.
  if (exec 3<>"/dev/tcp/127.0.0.1/$BOOT_PORT") 2>/dev/null; then
    log "boot check FAILED: port $BOOT_PORT is already in use"
    cleanup_boot
    return 1
  fi

  log "boot check on port $BOOT_PORT"
  (cd "$release_dir/elixir" && mise trust --quiet 2>/dev/null || true)
  # The escript shebang needs mise-managed erlang on PATH; run from the
  # release's elixir dir so its mise.toml provides the right toolchain.
  (cd "$release_dir/elixir" && exec mise exec -- ./bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    "$BOOT_TMP/WORKFLOW.md" --logs-root "$BOOT_TMP/logs" --port "$BOOT_PORT") &
  BOOT_PID=$!

  local deadline=$((SECONDS + 30))
  local state_body
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$BOOT_PID" 2>/dev/null; then
      log "boot check FAILED: release process exited before becoming healthy"
      cleanup_boot
      return 1
    fi

    # No pipeline here: under pipefail an early-exiting grep SIGPIPEs curl and
    # kills the whole promotion (observed as exit 141).
    state_body="$(curl -sf -m 2 "http://127.0.0.1:$BOOT_PORT/api/v1/state" || true)"
    if [[ "$state_body" == *'"status":"healthy"'* ]]; then
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

# Single failure path after the flip: restore the previous pin, reactivate
# consumers on it, and always leave a deduplicated FAIL issue behind.
rollback_and_fail() {
  local reason="$1"
  log "$reason; rolling back"
  local note
  if [ -n "$PREVIOUS_TARGET" ]; then
    # flip_to failure must not abort (set -e) before the FAIL issue is filed.
    if ! flip_to "$PREVIOUS_TARGET"; then
      note="ROLLBACK FLIP FAILED: current may still point at the failed release — manual pin state, see logs"
    elif run_consumer_cmds; then
      note="rolled back to $(basename "$PREVIOUS_TARGET")"
    else
      note="rolled back pin to $(basename "$PREVIOUS_TARGET") BUT consumer reactivation failed — consumers may still run the failed release"
    fi
  else
    note="no previous release existed; current left on $SHORT_SHA (bootstrap promotion)"
    log "$note"
  fi

  local report body_file
  report="$(latest_report || true)"
  body_file="${report:-$(mktemp)}"
  if [ -z "${report:-}" ]; then
    echo "promotion failed for $SHA: $reason. $note" > "$body_file"
  fi
  file_fail_issue "promote FAIL: $reason on $SHORT_SHA" "$body_file"
  log "PROMOTION FAIL: $note"
  exit 1
}

# ── 0. Exclusive promotion lock ─────────────────────────────────────────────
# Two concurrent promotions can flip in different orders and let the older
# run's rollback restore a stale pin over the newer success. mkdir is atomic;
# a held lock fails fast and the caller retries on its own cadence.
mkdir -p "$RELEASES_ROOT"
PROMO_LOCK="$RELEASES_ROOT/.promote.lock"
if ! mkdir "$PROMO_LOCK" 2>/dev/null; then
  echo "[promote] FAIL: another promotion holds $PROMO_LOCK" >&2
  exit 1
fi
release_lock() { rmdir "$PROMO_LOCK" 2>/dev/null || true; }
trap 'cleanup_boot; release_lock' EXIT

# ── 1. Gate ────────────────────────────────────────────────────────────────
cd "$REPO_ROOT"
SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short HEAD)"
PROMO_REPORT_DIR="$REPO_ROOT/qa-output/promote-$SHORT_SHA-$$"
mkdir -p "$PROMO_REPORT_DIR"

# The gate runs in the working tree while the release builds from the HEAD
# commit; tracked local modifications would let the gate validate code that
# is not in the artifact being promoted.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  log "FAIL: tracked working-tree changes present; commit or stash before promoting"
  exit 1
fi

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
  # Archive to a file instead of piping into tar: a transient consumer exit
  # under pipefail would SIGPIPE git-archive and abort the promotion.
  git archive "$SHA" --output="$BUILD_TMP/src.tar"
  tar -xf "$BUILD_TMP/src.tar" -C "$BUILD_TMP"
  rm -f "$BUILD_TMP/src.tar"
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
if ! run_consumer_cmds; then
  rollback_and_fail "consumer activation failed"
fi

# ── 6. Real production smoke; rollback on failure ──────────────────────────
if [ "$SKIP_SMOKE" -eq 1 ]; then
  log "smoke skipped by flag; promotion of $SHORT_SHA complete (UNSMOKED)"
  exit 0
fi

log "running prod smoke against release $SHORT_SHA"
if (cd "$ELIXIR_DIR" && mise exec -- mix prod.smoke \
  --escript-path "$RELEASE_DIR/elixir/bin/symphony" \
  --report-dir "$PROMO_REPORT_DIR"); then
  log "PROMOTION PASS: $SHORT_SHA is live"
  exit 0
fi

rollback_and_fail "smoke failed"
