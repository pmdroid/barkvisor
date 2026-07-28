#!/usr/bin/env bash
# Phase A: real Ubuntu cloud-image guest on NAT with cloud-init + SSH probe.
#
# Thin wrapper around linux-guest-smoke.sh with REAL_GUEST=1 defaults.
# Prefer Orb barkvisor-u24 (or any Linux host with QEMU; KVM if /dev/kvm exists).
#
# Usage:
#   ./scripts/linux-real-guest-smoke.sh
#   # Orb TCG can take many minutes for cloud-init; allow start-only success:
#   SKIP_BUILD=1 ALLOW_SSH_TIMEOUT=1 ./scripts/linux-real-guest-smoke.sh
#   BARKVISOR_CLOUD_IMAGE_URL=https://… ./scripts/linux-real-guest-smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REAL_GUEST=1
exec "$ROOT/scripts/linux-guest-smoke.sh" "$@"
