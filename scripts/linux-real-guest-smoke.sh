#!/usr/bin/env bash
# Alias for real cloud-image guest smoke (NAT + cloud-init + SSH).
#
# Equivalent to:
#   REAL_GUEST=1 ./scripts/linux-guest-smoke.sh
#
# Host arch picks the default Ubuntu noble minimal image (arm64 vs amd64).
# Prefer any Linux host with QEMU (KVM if /dev/kvm exists; TCG is slow).
#
# Usage:
#   ./scripts/linux-real-guest-smoke.sh
#   SKIP_BUILD=1 ALLOW_SSH_TIMEOUT=1 ./scripts/linux-real-guest-smoke.sh
#   BARKVISOR_CLOUD_IMAGE_URL=https://… ./scripts/linux-real-guest-smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REAL_GUEST=1
exec "$ROOT/scripts/linux-guest-smoke.sh" "$@"
