#!/usr/bin/env bash
# Build Linux packages inside Docker (usable from macOS or any host with Docker).
#
# Builds the release binary + SPA in Ubuntu 24.04 (matches official Swift
# channel), then runs build-linux-packages.sh for tar + deb (+ rpm tools).
#
# Usage:
#   ./scripts/build-linux-packages-docker.sh
#   VERSION=1.0.0 ./scripts/build-linux-packages-docker.sh
#   ./scripts/build-linux-packages-docker.sh --formats tar,deb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/linux-packages}"
FORMATS="${FORMATS:-tar,deb,rpm}"
SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
IMAGE_TAG="${IMAGE_TAG:-barkvisor-pkgbuild:local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formats) FORMATS="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --swift) SWIFT_VERSION="${2:?}"; shift 2 ;;
    -h | --help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  echo "error: docker not found" >&2
  exit 1
}

mkdir -p "$OUT_DIR"

# Host arch → docker platform
HOST_M="$(uname -m)"
case "$HOST_M" in
  x86_64 | amd64) DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}" ;;
  arm64 | aarch64) DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}" ;;
  *) DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}" ;;
esac

echo "==> Docker package build"
echo "    platform: $DOCKER_PLATFORM"
echo "    swift:    $SWIFT_VERSION (Ubuntu $UBUNTU_VERSION)"
echo "    formats:  $FORMATS"
echo "    out:      $OUT_DIR"

# Resolve version for both binary inject (Config.swift) and package metadata.
if [[ -z "${VERSION:-}" ]]; then
  if GIT_TAG="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null)"; then
    VERSION="${GIT_TAG#v}"
  else
    VERSION="0.0.0+git.$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi
fi
echo "    version:  $VERSION"

DOCKERFILE="$ROOT/packaging/linux/Dockerfile.package"
docker build \
  --platform "$DOCKER_PLATFORM" \
  -f "$DOCKERFILE" \
  --build-arg "SWIFT_VERSION=$SWIFT_VERSION" \
  --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" \
  --build-arg "BARKVISOR_VERSION=$VERSION" \
  -t "$IMAGE_TAG" \
  "$ROOT"

# Run package step with bind-mounted output (script is ENTRYPOINT)
docker run --rm \
  --platform "$DOCKER_PLATFORM" \
  -e "VERSION=${VERSION:-}" \
  -e "FORMATS=$FORMATS" \
  -e "OUT_DIR=/out" \
  -e "FRONTEND_DIST=/src/frontend/dist" \
  -e "BUNDLE_SWIFT=1" \
  -e "SWIFT_LINUX_LIBDIR=/usr/lib/swift/linux" \
  -v "$OUT_DIR:/out" \
  "$IMAGE_TAG"
echo
echo "Docker package build finished → $OUT_DIR"
ls -la "$OUT_DIR" | head -40
