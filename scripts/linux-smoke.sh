#!/usr/bin/env bash
# Quick Linux smoke: build daemon, start briefly, check health + capabilities.
# Usage: ./scripts/linux-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/linux-smoke-common.sh
source "$ROOT/scripts/lib/linux-smoke-common.sh"

command -v swift >/dev/null 2>&1 || die "swift not on PATH. Install Ubuntu 24.04 Swift toolchain first."
command -v curl >/dev/null 2>&1 || die "curl is required"

PORT="$(pick_port)"
export BARKVISOR_PORT="$PORT"
export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d /tmp/barkvisor-smoke.XXXXXX)}"
log "data dir: $BARKVISOR_DATA_DIR"
log "port: $PORT"

smoke_cleanup_trap
build_barkvisor
BIN="$(find_bin)" || die "BarkVisorApp binary not found under .build/"
start_server "$BIN"
wait_health 30 0.5

log "health"
curl -sS "${BASE}/api/health"
echo

log "capabilities"
CAPS=$(curl -sS "${BASE}/api/system/capabilities")
echo "$CAPS"
echo "$CAPS" | grep -q '"platform"' || die "capabilities JSON missing platform"

echo
echo "linux-smoke: OK"
