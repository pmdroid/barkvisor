#!/usr/bin/env bash
# Stop the throwaway instance recorded by up.sh (or --name TAG).
# Kills only the registered pid; never matches process names.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

if [[ "${1:-}" == "--name" ]]; then
  "$ROOT/scripts/dev-instance.sh" stop --name "$2"
else
  [[ -f "$SKILL_DIR/current/meta.json" ]] || { echo "no current/meta.json — nothing to stop" >&2; exit 1; }
  name="$(jq -r .name "$SKILL_DIR/current/meta.json")"
  "$ROOT/scripts/dev-instance.sh" stop --name "$name"
  rm -rf "$SKILL_DIR/current"
fi
