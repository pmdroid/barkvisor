#!/usr/bin/env bash
# Build the Vue SPA and point BarkVisorApp at it (Linux / multi-platform).
#
# Usage:
#   ./scripts/linux-frontend-serve.sh              # build only, print BARKVISOR_FRONTEND_DIR
#   ./scripts/linux-frontend-serve.sh --run        # build, then start BarkVisorApp with SPA
#   ./scripts/linux-frontend-serve.sh --verify     # build, start briefly, assert GET / is HTML
#   ./scripts/linux-frontend-serve.sh --install-dev # copy dist → Sources/BarkVisor/Resources/frontend/dist
#
# Prefers bun when available; falls back to npm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/frontend"
DIST="$FRONTEND/dist"
INSTALL_TARGET="$ROOT/Sources/BarkVisor/Resources/frontend/dist"
RUN=0
VERIFY=0
INSTALL_DEV=0

for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    --verify) VERIFY=1 ;;
    --install-dev) INSTALL_DEV=1 ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --run, --verify, --install-dev)" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$FRONTEND" ]]; then
  echo "error: frontend/ not found at $FRONTEND" >&2
  exit 1
fi

cd "$FRONTEND"

# Prefer vite build directly: `vue-tsc -b` can fail on some Linux toolchains
# with "Cannot find module '*.vue'" even when sources are present. Vite alone
# is enough for a working SPA dist.
if command -v bun >/dev/null 2>&1; then
  echo "==> bun install"
  bun install
  echo "==> bunx vite build"
  bunx vite build
elif command -v npm >/dev/null 2>&1; then
  echo "==> npm install (bun not found)"
  npm install
  echo "==> npx vite build"
  npx vite build
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
echo "Without BARKVISOR_FRONTEND_DIR, BarkVisor also probes:"
echo "  - frontend/dist (dev cwd / project root)"
echo "  - Sources/BarkVisor/Resources/frontend/dist"
echo "  - installed share path (Config.frontendDir)"

if [[ "$INSTALL_DEV" -eq 1 ]]; then
  echo "==> installing dist → $INSTALL_TARGET"
  mkdir -p "$(dirname "$INSTALL_TARGET")"
  rm -rf "$INSTALL_TARGET"
  mkdir -p "$INSTALL_TARGET"
  cp -a "$DIST"/. "$INSTALL_TARGET"/
  echo "installed. Next run without BARKVISOR_FRONTEND_DIR will pick up Resources/frontend/dist if on search path."
fi

find_bin() {
  if [[ -x "$ROOT/.build/debug/BarkVisorApp" ]]; then
    echo "$ROOT/.build/debug/BarkVisorApp"
  elif [[ -x "$ROOT/.build/release/BarkVisorApp" ]]; then
    echo "$ROOT/.build/release/BarkVisorApp"
  else
    return 1
  fi
}

if [[ "$VERIFY" -eq 1 ]]; then
  command -v curl >/dev/null 2>&1 || { echo "error: curl required for --verify" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 required for --verify" >&2; exit 1; }
  export BARKVISOR_FRONTEND_DIR="$DIST"
  PORT="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  export BARKVISOR_PORT="$PORT"
  export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/barkvisor-spa-verify.XXXXXX")}"
  BIN="$(find_bin || true)"
  if [[ -z "$BIN" ]]; then
    if command -v swift >/dev/null 2>&1; then
      echo "==> swift build --product BarkVisorApp"
      (cd "$ROOT" && swift build --product BarkVisorApp)
      BIN="$(find_bin)"
    fi
  fi
  [[ -n "$BIN" && -x "$BIN" ]] || { echo "error: BarkVisorApp binary required for --verify" >&2; exit 1; }
  echo "==> verify SPA via $BIN on :$PORT"
  "$BIN" >"$BARKVISOR_DATA_DIR/server.log" 2>&1 &
  PID=$!
  cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
  trap cleanup EXIT
  ok=0
  for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null; then ok=1; break; fi
    kill -0 "$PID" 2>/dev/null || { echo "server died"; tail -40 "$BARKVISOR_DATA_DIR/server.log"; exit 1; }
    sleep 0.5
  done
  [[ "$ok" -eq 1 ]] || { echo "health failed"; tail -40 "$BARKVISOR_DATA_DIR/server.log"; exit 1; }
  BODY="$(curl -sS "http://127.0.0.1:${PORT}/")"
  echo "$BODY" | grep -qi '<html\|<!doctype html' || {
    echo "error: GET / did not return HTML (SPA not served?)" >&2
    echo "body head: ${BODY:0:200}" >&2
    exit 1
  }
  echo "==> SPA verify OK (GET / is HTML)"
  exit 0
fi

if [[ "$RUN" -eq 1 ]]; then
  export BARKVISOR_FRONTEND_DIR="$DIST"
  if BIN="$(find_bin)"; then
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
