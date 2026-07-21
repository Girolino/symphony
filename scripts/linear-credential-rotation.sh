#!/usr/bin/env bash
# Repo-local Linear credential rotation/check wrapper. Values are passed only
# through files or environment and are never printed by the Mix task.
set -euo pipefail
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT/elixir"
exec mise exec -- mix linear.rotate_credential "$@"
