#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SWIFT_IMAGE:-swift:6.3.3-noble}"

log() { echo "==> linux-ci-local: $*"; }
die() { echo "error: linux-ci-local: $*" >&2; exit 1; }

if [[ "${LINUX_CI_SKIP:-0}" == "1" ]]; then
  echo "linux-ci-local: LINUX_CI_SKIP=1"
  exit 0
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  cd "$ROOT"
  log "native $(uname -m)"
  swift build --product BarkVisorApp
  swift build --build-tests
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "install Docker; this is the Linux CI compile"
docker info >/dev/null 2>&1 || die "start Docker; this is the Linux CI compile"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pull $IMAGE"
  docker pull "$IMAGE"
fi

log "Docker $IMAGE, product + tests"
docker run --rm \
  --name barkvisor-linux-ci-local \
  -v "$ROOT:/src:ro" \
  -v barkvisor-linux-ci-build:/work/.build \
  "$IMAGE" \
  bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev libncurses-dev \
  zlib1g-dev libzstd-dev libedit-dev uuid-dev pkg-config >/dev/null
mkdir -p /work
tar -C /src -cf - \
  --exclude .build \
  --exclude .git \
  --exclude node_modules \
  --exclude frontend/node_modules \
  --exclude website/node_modules \
  --exclude frontend/dist \
  --exclude website/dist \
  --exclude Apps \
  --exclude build \
  . | tar -C /work -xf -
cd /work
swift build --product BarkVisorApp
swift build --build-tests
'
