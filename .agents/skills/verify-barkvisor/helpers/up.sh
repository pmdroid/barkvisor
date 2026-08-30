#!/usr/bin/env bash
# Start a throwaway BarkVisor instance and record its meta for the other helpers.
# Usage: helpers/up.sh [--seed] [--name TAG] [--data-dir DIR] [--keep]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
NAME=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; ARGS+=(--name "$2"); shift 2 ;;
    --data-dir|--keep) ARGS+=("$1"); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$NAME" ]]; then
  NAME="verify-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
  ARGS=(--name "$NAME" "${ARGS[@]}")
fi

mkdir -p "$SKILL_DIR/current"
FRONTEND_DIR="$ROOT/Sources/BarkVisor/Resources/frontend/dist"
if [[ -f "$FRONTEND_DIR/index.html" ]]; then
  export BARKVISOR_FRONTEND_DIR="$FRONTEND_DIR"
fi
"$ROOT/scripts/dev-instance.sh" start "${ARGS[@]}" | tee "$SKILL_DIR/current/meta.json"
