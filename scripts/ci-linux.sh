#!/usr/bin/env bash
# Same commands as .github/workflows/ci.yml job "Linux Build":
#   swift build --product BarkVisorApp
#   swift test --skip-update
#
# On Linux: native toolchain.
# On macOS: Docker image swift:6.3.3-noble (Ubuntu 24.04), with .build in a
# named volume so the host Darwin cache is not reused.
#
#   ./scripts/ci-linux.sh
#   SKIP_LINUX_CI=1 ./scripts/ci-linux.sh   # emergency bypass (never in EVE)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [ "${SKIP_LINUX_CI:-}" = "1" ]; then
  echo "ci-linux: SKIP_LINUX_CI=1, skipping GitHub linux-build gate" >&2
  exit 0
fi

run_native() {
  echo "ci-linux: swift build --product BarkVisorApp" >&2
  swift build --product BarkVisorApp
  echo "ci-linux: swift test --skip-update" >&2
  swift test --skip-update
}

if [ "$(uname -s)" = "Linux" ]; then
  run_native
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ci-linux: docker is required on macOS so GitHub linux-build is caught before push." >&2
  echo "  Install Docker, or set SKIP_LINUX_CI=1 (EVE agents must never set this)." >&2
  exit 1
fi

IMAGE="${LINUX_CI_IMAGE:-swift:6.3.3-noble}"
HOST_M="$(uname -m)"
case "$HOST_M" in
  x86_64 | amd64) PLATFORM="${DOCKER_PLATFORM:-linux/amd64}" ;;
  arm64 | aarch64) PLATFORM="${DOCKER_PLATFORM:-linux/arm64}" ;;
  *) PLATFORM="${DOCKER_PLATFORM:-linux/amd64}" ;;
esac

echo "ci-linux: docker $IMAGE ($PLATFORM) — matches CI linux-build" >&2
exec docker run --rm \
  --platform "$PLATFORM" \
  -v "$ROOT:/src" \
  -v barkvisor-ci-linux-build:/src/.build \
  -w /src \
  "$IMAGE" \
  bash -lc 'set -euo pipefail
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libsqlite3-dev >/dev/null
    swift build --product BarkVisorApp
    swift test --skip-update
  '
