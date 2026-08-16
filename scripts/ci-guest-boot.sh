#!/usr/bin/env bash
# PAS-186 CI helper: probe /dev/kvm and run guest-boot BDD without a TCG fallback.
#
# Usage:
#   ./scripts/ci-guest-boot.sh probe     # print kvm=yes|no (exit 0 unless REQUIRE_KVM=1)
#   ./scripts/ci-guest-boot.sh blank     # mise run guest-smoke mapper
#   ./scripts/ci-guest-boot.sh real      # mise run guest-smoke-real mapper
#   DRY_RUN=1 ./scripts/ci-guest-boot.sh
#
# Env:
#   REQUIRE_KVM=1      Fail when /dev/kvm is not usable (self-hosted linux/kvm lane)
#   CI_FORCE_NO_KVM=1  Pretend /dev/kvm is missing (unit tests)
#   BARKVISOR_DATA_DIR Smoke server.log directory (smoke script default: mktemp)
#
# Hosted ubuntu-24.04: if KVM is missing, print SKIP and exit 0. Never TCG in CI.
# A Device still owns Workload runtime in local SQLite if other Home Devices are down.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAPPER="$ROOT/scripts/guest-boot-bdd.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

kvm_usable() {
  if [[ "${CI_FORCE_NO_KVM:-0}" == "1" ]]; then
    return 1
  fi
  [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]
}

emit_probe() {
  if kvm_usable; then
    echo "kvm=yes"
    if [[ -e /dev/kvm ]]; then
      ls -l /dev/kvm || true
    fi
    return 0
  fi
  echo "kvm=no"
  if [[ -e /dev/kvm ]]; then
    ls -l /dev/kvm || true
    echo "note: /dev/kvm exists but is not a writable character device for this user"
  else
    echo "note: /dev/kvm is absent"
  fi
  if [[ "${REQUIRE_KVM:-0}" == "1" ]]; then
    die "/dev/kvm is required (REQUIRE_KVM=1). See docs/ci-kvm-runner.md"
  fi
  return 0
}

skip_no_kvm() {
  echo "SKIP: /dev/kvm is not usable; not running guest-boot on TCG in CI."
  echo "Install KVM or register a self-hosted linux/kvm runner (docs/ci-kvm-runner.md)."
}

run_scenario() {
  local scenario="$1"
  if ! kvm_usable; then
    if [[ "${REQUIRE_KVM:-0}" == "1" ]]; then
      die "/dev/kvm is required (REQUIRE_KVM=1). See docs/ci-kvm-runner.md"
    fi
    skip_no_kvm
    return 0
  fi
  [[ -x "$MAPPER" ]] || die "not executable: $MAPPER"
  log "running guest-boot-bdd.sh ${scenario} (KVM)"
  "$MAPPER" "$scenario"
}

dry_run() {
  log "DRY_RUN=1 — bash -n + inventory"
  bash -n "$0"
  bash -n "$MAPPER"
  [[ -x "$MAPPER" ]] || die "not executable: $MAPPER"

  for needle in \
    "guest-boot-bdd.sh" \
    "REQUIRE_KVM" \
    "CI_FORCE_NO_KVM" \
    "/dev/kvm" \
    "SKIP: /dev/kvm" \
    "docs/ci-kvm-runner.md" \
    "Workload"; do
    grep -qF "$needle" "$0" || die "helper missing reference to $needle"
  done

  log "DRY_RUN OK (no server started, no QEMU)"
}

cmd="${1:-probe}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  dry_run
  exit 0
fi

case "$cmd" in
  probe)
    emit_probe
    ;;
  blank | guest-smoke)
    run_scenario blank
    ;;
  real | guest-smoke-real)
    run_scenario real
    ;;
  -h | --help | help)
    sed -n '2,20p' "$0"
    ;;
  *)
    die "unknown command '$cmd' (probe|blank|real)"
    ;;
esac
