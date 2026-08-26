#!/usr/bin/env bash
# Start a throwaway BarkVisor instance and record its meta for the other helpers.
# Usage: helpers/up.sh [--seed] [--name TAG] [--data-dir DIR] [--keep]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
NAME="verify"
ARGS=(--name "$NAME")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; ARGS+=(--name "$2"); shift 2 ;;
    --data-dir|--keep) ARGS+=("$1"); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

mkdir -p "$SKILL_DIR/current"
"$ROOT/scripts/dev-instance.sh" start "${ARGS[@]}" | tee "$SKILL_DIR/current/meta.json"
