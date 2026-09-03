#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BDD="$ROOT/scripts/linux-host-network-bdd.sh"
FEATURE="$ROOT/features/host-network-extra-ip.feature"
IMAGE="${SWIFT_IMAGE:-swift:6.3.3-noble}"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1 — syntax + feature"
  bash -n "$0"
  bash -n "$BDD"
  [[ -x "$BDD" ]] || die "not executable: $BDD"
  [[ -f "$FEATURE" ]] || die "missing $FEATURE"
  grep -qF "Scenario: add an extra IP then remove it" "$FEATURE" || die "feature missing scenario"
  log "DRY_RUN OK"
  exit 0
fi

if [[ "${BDD_FORCE_SKIP:-0}" == "1" ]]; then
  echo "SKIP: forced skip of Docker extra-IP suite."
  exit 0
fi

if [[ "$(uname -s)" == "Linux" ]] && [[ "$(id -u)" -eq 0 ]] && command -v ip >/dev/null 2>&1; then
  log "Linux root with ip — running extra-IP suite on this host"
  exec "$BDD"
fi

command -v docker >/dev/null 2>&1 || {
  echo "SKIP: docker not on PATH; extra-IP live suite needs Docker or a root Linux Device."
  exit 0
}

log "Docker $IMAGE + NET_ADMIN — extra-IP add/remove"
docker run --rm \
  --name barkvisor-hostnet-bdd \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  -e SKIP_BUILD="${SKIP_BUILD:-0}" \
  -e HOSTNET_NIC="${HOSTNET_NIC:-bvtest0}" \
  -e HOSTNET_PRIMARY="${HOSTNET_PRIMARY:-10.200.55.1/24}" \
  -e HOSTNET_ALIAS="${HOSTNET_ALIAS:-10.200.55.50/24}" \
  -v "$ROOT:/src:ro" \
  "$IMAGE" \
  bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iproute2 jq curl ca-certificates python3 tar >/dev/null
mkdir -p /work /etc/netplan /etc/systemd/network /run/barkvisor
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
if [ -d /src/.build/checkouts ]; then
  mkdir -p /work/.build
  cp -a /src/.build/checkouts /work/.build/checkouts
fi
export ROOT=/work
swift build --product BarkVisorApp
export SKIP_BUILD=1
exec /work/scripts/linux-host-network-bdd.sh
'
