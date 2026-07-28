#!/usr/bin/env bash
# Quick Linux smoke: build daemon, start briefly, check health + capabilities.
# Usage: ./scripts/linux-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not on PATH. Install Ubuntu 24.04 Swift toolchain first." >&2
  exit 1
fi

PORT="${BARKVISOR_PORT:-17777}"
export BARKVISOR_PORT="$PORT"
export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d /tmp/barkvisor-smoke.XXXXXX)}"
echo "data dir: $BARKVISOR_DATA_DIR"
echo "port: $PORT"

echo "==> swift build --product BarkVisorApp"
swift build --product BarkVisorApp

BIN="$ROOT/.build/debug/BarkVisorApp"
if [[ ! -x "$BIN" ]]; then
  BIN="$ROOT/.build/release/BarkVisorApp"
fi

"$BIN" >"$BARKVISOR_DATA_DIR/server.log" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT

ok=0
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null; then
    ok=1
    break
  fi
  sleep 0.5
done
if [[ "$ok" -ne 1 ]]; then
  echo "health check failed; server log:" >&2
  tail -40 "$BARKVISOR_DATA_DIR/server.log" >&2 || true
  exit 1
fi

echo "==> health"
curl -sS "http://127.0.0.1:${PORT}/api/health"
echo

echo "==> capabilities"
CAPS=$(curl -sS "http://127.0.0.1:${PORT}/api/system/capabilities")
echo "$CAPS"
echo "$CAPS" | grep -q '"platform"' || {
  echo "capabilities JSON missing platform" >&2
  exit 1
}

echo
echo "linux-smoke: OK"
