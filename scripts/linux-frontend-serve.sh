#!/usr/bin/env bash
# Build the Vue SPA and print how to serve it from BarkVisorApp.
#
# Usage:
#   ./scripts/linux-frontend-serve.sh           # build only, print BARKVISOR_FRONTEND_DIR
#   ./scripts/linux-frontend-serve.sh --run     # build, then start BarkVisorApp with that env
#
# Prefers bun when available; falls back to npm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/frontend"
DIST="$FRONTEND/dist"
RUN=0

for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --run)" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$FRONTEND" ]]; then
  echo "error: frontend/ not found at $FRONTEND" >&2
  exit 1
fi

cd "$FRONTEND"

if command -v bun >/dev/null 2>&1; then
  echo "==> bun install"
  bun install
  echo "==> bun run build"
  bun run build
elif command -v npm >/dev/null 2>&1; then
  echo "==> npm install (bun not found)"
  npm install
  echo "==> npm run build"
  npm run build
else
  echo "error: need bun or npm to build the frontend" >&2
  exit 1
fi

if [[ ! -f "$DIST/index.html" ]]; then
  echo "error: build finished but $DIST/index.html is missing" >&2
  exit 1
fi

echo
echo "SPA dist: $DIST"
echo
echo "Point the daemon at this build with:"
echo "  export BARKVISOR_FRONTEND_DIR=\"$DIST\""
echo "  swift run BarkVisorApp"
echo
echo "Or reuse an existing binary:"
echo "  BARKVISOR_FRONTEND_DIR=\"$DIST\" ./.build/debug/BarkVisorApp"
echo
echo "Without BARKVISOR_FRONTEND_DIR, BarkVisor also probes:"
echo "  - frontend/dist (dev cwd / project root)"
echo "  - Sources/BarkVisor/Resources/frontend/dist"
echo "  - installed share path (Config.frontendDir)"

if [[ "$RUN" -eq 1 ]]; then
  export BARKVISOR_FRONTEND_DIR="$DIST"
  BIN=""
  if [[ -x "$ROOT/.build/debug/BarkVisorApp" ]]; then
    BIN="$ROOT/.build/debug/BarkVisorApp"
  elif [[ -x "$ROOT/.build/release/BarkVisorApp" ]]; then
    BIN="$ROOT/.build/release/BarkVisorApp"
  fi

  if [[ -n "$BIN" ]]; then
    echo "==> starting $BIN with BARKVISOR_FRONTEND_DIR=$DIST"
    exec "$BIN"
  fi

  if command -v swift >/dev/null 2>&1; then
    echo "==> swift run BarkVisorApp (BARKVISOR_FRONTEND_DIR=$DIST)"
    cd "$ROOT"
    exec swift run BarkVisorApp
  fi

  echo "error: no BarkVisorApp binary and no swift on PATH" >&2
  exit 1
fi
