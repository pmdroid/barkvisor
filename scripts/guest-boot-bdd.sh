#!/usr/bin/env bash
# Thin Gherkin mapper for features/guest-boot.feature (PAS-183).
#
# This is not a Cucumber runtime. Each named scenario execs an existing
# smoke script. Failure output prints the scenario and step that ran.
#
# Usage:
#   ./scripts/guest-boot-bdd.sh blank     # mise run guest-smoke
#   ./scripts/guest-boot-bdd.sh real      # mise run guest-smoke-real
#   ./scripts/guest-boot-bdd.sh list
#   DRY_RUN=1 ./scripts/guest-boot-bdd.sh
#
# Skip: if qemu-system-* is missing, print SKIP and exit 0.
# Set ALLOW_NO_QEMU=1 to run the create-only API path instead.
# BDD_FORCE_NO_QEMU=1 forces the skip path (used by unit tests).
#
# Not part of default `mise run prepush`. TCG boots can take ~15 min;
# KVM/HVF is typically a few minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEATURE="$ROOT/features/guest-boot.feature"
BLANK_SCRIPT="$ROOT/scripts/linux-guest-smoke.sh"
REAL_SCRIPT="$ROOT/scripts/linux-real-guest-smoke.sh"

SCENARIO_BLANK="a blank-disk Workload reaches running"
SCENARIO_REAL="a Linux Workload boots from a cloud image and answers SSH"

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

has_qemu() {
  if [[ "${BDD_FORCE_NO_QEMU:-0}" == "1" ]]; then
    return 1
  fi
  command -v qemu-system-aarch64 >/dev/null 2>&1 \
    || command -v qemu-system-x86_64 >/dev/null 2>&1
}

skip_no_qemu() {
  local name="$1"
  echo "SKIP: qemu-system-* is not on PATH; skipping scenario \"$name\"."
  echo "Install qemu-system-aarch64 or qemu-system-x86_64 and re-run."
  echo "Set ALLOW_NO_QEMU=1 to exercise API create-only instead of skipping."
  exit 0
}

require_feature() {
  [[ -f "$FEATURE" ]] || die "missing $FEATURE"
  grep -qF "Scenario: $SCENARIO_BLANK" "$FEATURE" \
    || die "feature missing scenario: $SCENARIO_BLANK"
  grep -qF "Scenario: $SCENARIO_REAL" "$FEATURE" \
    || die "feature missing scenario: $SCENARIO_REAL"
}

list_scenarios() {
  require_feature
  grep -E '^[[:space:]]*Scenario:' "$FEATURE" | sed -E 's/^[[:space:]]*Scenario:[[:space:]]*//'
}

dry_run() {
  log "DRY_RUN=1 — bash -n + scenario inventory"
  bash -n "$0"
  bash -n "$BLANK_SCRIPT"
  bash -n "$REAL_SCRIPT"
  require_feature
  [[ -x "$BLANK_SCRIPT" ]] || die "not executable: $BLANK_SCRIPT"
  [[ -x "$REAL_SCRIPT" ]] || die "not executable: $REAL_SCRIPT"

  for needle in \
    "linux-guest-smoke.sh" \
    "linux-real-guest-smoke.sh" \
    "SKIP: qemu-system-*" \
    "ALLOW_NO_QEMU" \
    "Workload"; do
    grep -qF "$needle" "$0" || die "mapper missing reference to $needle"
  done

  log "scenarios:"
  list_scenarios | while IFS= read -r line; do
    echo "  - $line"
  done
  log "DRY_RUN OK (no server started, no QEMU)"
}

run_blank() {
  local name="$SCENARIO_BLANK"
  echo "Scenario: $name"
  if ! has_qemu; then
    if [[ "${ALLOW_NO_QEMU:-0}" == "1" ]]; then
      echo "Step: create a blank-disk Workload (ALLOW_NO_QEMU=1, no start)"
      # Unset leftover REAL_GUEST / cloud image so this stays blank-disk.
      env -u REAL_GUEST -u BARKVISOR_CLOUD_IMAGE_URL ALLOW_NO_QEMU=1 "$BLANK_SCRIPT"
      return
    fi
    skip_no_qemu "$name"
  fi
  echo "Step: create and start a blank-disk Workload"
  env -u REAL_GUEST -u BARKVISOR_CLOUD_IMAGE_URL "$BLANK_SCRIPT" \
    || die "failed scenario: $name"
  echo "Then: Workload state is running or starting"
}

run_real() {
  local name="$SCENARIO_REAL"
  echo "Scenario: $name"
  if ! has_qemu; then
    if [[ "${ALLOW_NO_QEMU:-0}" == "1" ]]; then
      echo "Step: create a cloud-image Workload (ALLOW_NO_QEMU=1, no start)"
      ALLOW_NO_QEMU=1 "$REAL_SCRIPT"
      return
    fi
    skip_no_qemu "$name"
  fi
  echo "Step: download cloud image, create Workload, start, probe SSH"
  echo "Note: TCG can take ~15 minutes; KVM/HVF is typically a few minutes."
  "$REAL_SCRIPT" || die "failed scenario: $name"
  echo "Then: Workload is running and guest SSH answers"
}

cmd="${1:-blank}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  dry_run
  exit 0
fi

case "$cmd" in
  blank | guest-smoke)
    require_feature
    run_blank
    ;;
  real | guest-smoke-real)
    require_feature
    run_real
    ;;
  list)
    list_scenarios
    ;;
  all)
    require_feature
    run_blank
    run_real
    ;;
  -h | --help | help)
    sed -n '2,20p' "$0"
    ;;
  *)
    die "unknown scenario '$cmd' (blank|real|list|all)"
    ;;
esac
