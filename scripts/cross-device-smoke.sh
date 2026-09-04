#!/usr/bin/env bash
# Two-Device Home proxy smoke (PAS-185).
#
# Boots two BarkVisorApp processes on one host (two data dirs, two HTTP
# ports, two agent ports). Device B joins Device A's Home with a real
# pairing code. Create + start a Workload on B through
# /api/home/devices/:id/v1 and assert running from the Home proxy and
# from B locally.
#
# Usage:
#   ./scripts/cross-device-smoke.sh
#   ./scripts/cross-device-smoke.sh list
#   DRY_RUN=1 ./scripts/cross-device-smoke.sh
#   SKIP_BUILD=1 ./scripts/cross-device-smoke.sh
#   ALLOW_NO_QEMU=1 ./scripts/cross-device-smoke.sh   # pair + create; skip start
#
# Not part of default `mise run prepush`. Mapped from
# features/cross-device.feature (mise run cross-device-smoke).
#
# Pairing redeem is LAN-only (not 127.0.0.1). After join the member is
# restarted so the agent plane presents the Home-issued certificate.
# First-time join only. No in-process fake topology.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/linux-smoke-common.sh
source "$ROOT/scripts/lib/linux-smoke-common.sh"

FEATURE="$ROOT/features/cross-device.feature"
SCENARIO="a Workload created from the Home runs on a paired Device"

export BARKVISOR_ADMIN_USER="${BARKVISOR_ADMIN_USER:-admin}"
if [[ -z "${BARKVISOR_ADMIN_PASSWORD:-}" ]]; then
  echo "error: BARKVISOR_ADMIN_PASSWORD is required; no default is used (set it explicitly to avoid creating well-known admin accounts)" >&2
  exit 1
fi
export BARKVISOR_ADMIN_PASSWORD

REQUIRED_ENDPOINTS=(
  "GET  /api/health"
  "GET  /api/setup/status"
  "POST /api/setup/admin"
  "POST /api/setup/bridge/skip"
  "POST /api/setup/complete"
  "POST /api/auth/login"
  "POST /api/pairing/codes"
  "POST /api/pairing/join"
  "GET  /api/home/devices"
  "GET  /api/home/devices/health"
  "GET  /api/home/devices/:id/v1/networks"
  "POST /api/home/devices/:id/v1/disks"
  "POST /api/home/devices/:id/v1/vms"
  "POST /api/home/devices/:id/v1/vms/:id/start"
  "GET  /api/home/devices/:id/v1/vms/:id"
  "GET  /api/vms/:id"
)

require_feature() {
  [[ -f "$FEATURE" ]] || die "missing $FEATURE"
  grep -qF "Scenario: $SCENARIO" "$FEATURE" \
    || die "feature missing scenario: $SCENARIO"
}

list_scenarios() {
  require_feature
  grep -E '^[[:space:]]*Scenario:' "$FEATURE" | sed -E 's/^[[:space:]]*Scenario:[[:space:]]*//'
}

dry_run() {
  log "DRY_RUN=1 — bash -n + scenario inventory"
  bash -n "$0"
  bash -n "$ROOT/scripts/lib/linux-smoke-common.sh"
  require_feature
  [[ -x "$0" ]] || die "not executable: $0"

  for needle in \
    "/api/pairing/codes" \
    "/api/pairing/join" \
    "/api/home/devices/health" \
    "/api/home/devices/" \
    "/v1/vms" \
    "BARKVISOR_DATA_DIR" \
    "BARKVISOR_AGENT_PORT" \
    "pick_free_port" \
    "linux-smoke-common.sh" \
    "Workload"; do
    grep -qF "$needle" "$0" || die "script missing reference to $needle"
  done

  log "required API endpoints:"
  for ep in "${REQUIRED_ENDPOINTS[@]}"; do
    echo "  - $ep"
  done

  log "scenarios:"
  list_scenarios | while IFS= read -r line; do
    echo "  - $line"
  done
  log "DRY_RUN OK (no server started, no QEMU)"
}

has_qemu() {
  if [[ "${BDD_FORCE_NO_QEMU:-0}" == "1" ]]; then
    return 1
  fi
  command -v qemu-system-aarch64 >/dev/null 2>&1 \
    || command -v qemu-system-x86_64 >/dev/null 2>&1
}

use_home() {
  export BARKVISOR_PORT="$HOME_PORT"
  export BARKVISOR_DATA_DIR="$HOME_DIR"
  export BARKVISOR_AGENT_PORT="$HOME_AGENT"
  export BASE="$HOME_BASE"
  export TOKEN="${HOME_TOKEN:-}"
  export LOG_FILE="$HOME_LOG"
  SERVER_PID="${HOME_PID:-}"
}

use_member() {
  export BARKVISOR_PORT="$MEMBER_PORT"
  export BARKVISOR_DATA_DIR="$MEMBER_DIR"
  export BARKVISOR_AGENT_PORT="$MEMBER_AGENT"
  export BASE="$MEMBER_BASE"
  export TOKEN="${MEMBER_TOKEN:-}"
  export LOG_FILE="$MEMBER_LOG"
  SERVER_PID="${MEMBER_PID:-}"
}

start_daemon() {
  local role="$1"
  local port="$2"
  local agent="$3"
  local dir="$4"
  export BARKVISOR_PORT="$port"
  export BARKVISOR_DATA_DIR="$dir"
  export BARKVISOR_AGENT_PORT="$agent"
  start_server "$BIN"
  wait_health 60 0.5
  if [[ "$role" == "home" ]]; then
    HOME_PID="$SERVER_PID"
    HOME_LOG="$LOG_FILE"
    HOME_BASE="$BASE"
  else
    MEMBER_PID="$SERVER_PID"
    MEMBER_LOG="$LOG_FILE"
    MEMBER_BASE="$BASE"
  fi
}

assert_running() {
  local label="$1"
  local json="$2"
  local st
  st="$(echo "$json" | jq -r '.state // empty')"
  case "$st" in
    running | starting)
      log "$label state: $st"
      ;;
    *)
      fail "$label Workload is not running/starting (state=${st:-unknown}): $json"
      ;;
  esac
}

run_scenario() {
  echo "Scenario: $SCENARIO"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required (free-port picker)"

  local tmp_root
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/barkvisor-cross-device.XXXXXX")"
  HOME_DIR="${tmp_root}/home"
  MEMBER_DIR="${tmp_root}/member"
  mkdir -p "$HOME_DIR" "$MEMBER_DIR"
  HOME_LOG="${HOME_DIR}/server.log"
  MEMBER_LOG="${MEMBER_DIR}/server.log"

  HOME_PORT="$(pick_free_port)"
  HOME_AGENT="$(pick_free_port)"
  MEMBER_PORT="$(pick_free_port)"
  MEMBER_AGENT="$(pick_free_port)"
  HOME_BASE="http://127.0.0.1:${HOME_PORT}"
  MEMBER_BASE="http://127.0.0.1:${MEMBER_PORT}"
  HOME_TOKEN=""
  MEMBER_TOKEN=""

  log "Home dataDir=$HOME_DIR port=$HOME_PORT agent=$HOME_AGENT"
  log "Device B dataDir=$MEMBER_DIR port=$MEMBER_PORT agent=$MEMBER_AGENT"

  smoke_cleanup_trap
  build_barkvisor
  BIN="$(find_bin)" || die "BarkVisorApp binary not found under .build/"

  echo "Step: start Device A (Home) and complete setup"
  start_daemon home "$HOME_PORT" "$HOME_AGENT" "$HOME_DIR"
  use_home
  setup_or_login
  HOME_TOKEN="$TOKEN"
  export HOME_TOKEN

  echo "Step: start Device B"
  start_daemon member "$MEMBER_PORT" "$MEMBER_AGENT" "$MEMBER_DIR"

  echo "Step: issue a pairing code on the Home"
  use_home
  local issue_code issue_json qr
  issue_code="$(api_code POST /api/pairing/codes -d '{}')"
  [[ "$issue_code" == "200" ]] \
    || fail "POST /api/pairing/codes returned HTTP $issue_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
  issue_json="$(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  qr="$(echo "$issue_json" | jq -r '.qrPayload // empty')"
  [[ -n "$qr" && "$qr" != "null" ]] || fail "pairing issue returned no qrPayload: $issue_json"
  log "issued pairing offer for Home hostId=$(echo "$issue_json" | jq -r '.hostId // empty')"

  echo "Step: Device B joins via POST /api/pairing/join"
  use_member
  unset TOKEN
  TOKEN=""
  local join_code join_json
  join_code="$(api_code POST /api/pairing/join -d "$(jq -n --arg q "$qr" '{qrPayload:$q}')")"
  [[ "$join_code" == "200" ]] \
    || fail "POST /api/pairing/join returned HTTP $join_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
  join_json="$(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  log "joined Home peer=$(echo "$join_json" | jq -r '.peerHostId // empty')"

  echo "Step: complete setup on Device B"
  use_member
  TOKEN=""
  setup_or_login
  MEMBER_TOKEN="$TOKEN"

  echo "Step: restart Device B so the agent presents the Home-issued certificate"
  stop_server "$MEMBER_PID"
  start_daemon member "$MEMBER_PORT" "$MEMBER_AGENT" "$MEMBER_DIR"

  echo "Step: GET /api/home/devices/health shows Device B reachable"
  use_home
  TOKEN="$HOME_TOKEN"
  local health member_id reach i
  member_id=""
  for i in $(seq 1 40); do
    health="$(api GET /api/home/devices/health || true)"
    member_id="$(echo "$health" | jq -r '[.devices[]? | select(.role != "self")] | .[0].hostId // empty')"
    reach="$(echo "$health" | jq -r --arg id "$member_id" \
      '[.devices[]? | select(.hostId == $id)] | .[0].reachability // empty')"
    if [[ -n "$member_id" && "$reach" == "ok" ]]; then
      break
    fi
    sleep 0.5
  done
  [[ -n "$member_id" ]] || fail "Home health has no member Device: $health"
  [[ "$reach" == "ok" ]] || fail "Device B is not reachable from Home (reachability=${reach:-unknown}): $health"
  log "Device B hostId=$member_id reachability=$reach"

  local qemu_ok=1
  if ! has_qemu; then
    qemu_ok=0
    if [[ "${ALLOW_NO_QEMU:-0}" != "1" && "${BDD_FORCE_NO_QEMU:-0}" == "1" ]]; then
      echo "SKIP: qemu-system-* is not on PATH; skipping start after pair+create."
    elif [[ "${ALLOW_NO_QEMU:-0}" != "1" ]]; then
      echo "warning: no qemu-system-* on PATH; start may fail. Set ALLOW_NO_QEMU=1 to stop after create." >&2
    fi
  fi

  echo "Step: create a Workload on Device B through the Home proxy"
  local networks network_id disk_code disk_id vm_body vm_code vm_json vm_id
  networks="$(api GET "/api/home/devices/${member_id}/v1/networks")"
  network_id="$(echo "$networks" | jq -r '
    (map(select(.mode=="nat" and (.isDefault==true or .isDefault==1))) | .[0].id)
    // (map(select(.mode=="nat")) | .[0].id)
    // empty
  ')"
  [[ -n "$network_id" && "$network_id" != "null" ]] || fail "no NAT network on Device B: $networks"

  disk_code="$(api_code POST "/api/home/devices/${member_id}/v1/disks" \
    -d "$(jq -n '{name:"cross-device-disk",sizeGB:2}')")"
  [[ "$disk_code" == "200" ]] \
    || fail "POST member /disks failed HTTP $disk_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  disk_id="$(jq -r '.id // empty' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  [[ -n "$disk_id" && "$disk_id" != "null" ]] || fail "no disk id from Device B"

  local vm_type
  vm_type="$(detect_vm_type)"
  vm_body="$(jq -n \
    --arg name "cross-device-smoke" \
    --arg vmType "$vm_type" \
    --arg net "$network_id" \
    --arg diskId "$disk_id" \
    '{name:$name,vmType:$vmType,cpuCount:1,memoryMB:512,networkId:$net,existingDiskId:$diskId}')"
  vm_code="$(api_code POST "/api/home/devices/${member_id}/v1/vms" -d "$vm_body")"
  if [[ "$vm_code" != "200" && "$vm_code" != "202" ]]; then
    fail "POST member /vms failed HTTP $vm_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  fi
  vm_json="$(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  vm_id="$(echo "$vm_json" | jq -r '.vm.id // .id // empty')"
  [[ -n "$vm_id" && "$vm_id" != "null" ]] || fail "no Workload id from Device B create: $vm_json"
  log "Workload id=$vm_id on Device B"

  if [[ "$qemu_ok" -eq 0 ]]; then
    echo "SKIP: qemu-system-* is not on PATH; skipping start (pair + create via Home proxy OK)."
    echo "Set ALLOW_NO_QEMU=1 to treat create-only as the intended path."
    echo "Then: Workload created on Device B through the Home proxy"
    log "cross-device-smoke: OK (create-only)"
    return 0
  fi

  echo "Step: start the Workload through the Home proxy"
  local start_code
  start_code="$(api_code POST "/api/home/devices/${member_id}/v1/vms/${vm_id}/start" -d '{}')"
  if [[ "$start_code" != "204" && "$start_code" != "200" ]]; then
    fail "POST member /vms/${vm_id}/start failed HTTP $start_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
  fi

  echo "Then: Workload state is running or starting from the Home proxy"
  local proxy_json="" final="" attempt
  for attempt in $(seq 1 30); do
    : "$attempt"
    proxy_json="$(api GET "/api/home/devices/${member_id}/v1/vms/${vm_id}")"
    final="$(echo "$proxy_json" | jq -r '.state // empty')"
    case "$final" in
      running | starting) break ;;
      error) fail "Workload entered error via Home proxy: $proxy_json" ;;
    esac
    sleep 0.5
  done
  assert_running "Home proxy" "$proxy_json"

  echo "Then: Workload state is running or starting on Device B locally"
  use_member
  TOKEN="$HOME_TOKEN"
  local local_json
  local_json="$(api GET "/api/vms/${vm_id}")"
  assert_running "Device B local" "$local_json"

  log "cross-device-smoke: OK"
}

cmd="${1:-run}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  dry_run
  exit 0
fi

case "$cmd" in
  run | cross-device | cross-device-smoke)
    require_feature
    run_scenario
    ;;
  list)
    list_scenarios
    ;;
  -h | --help | help)
    sed -n '2,24p' "$0"
    ;;
  *)
    die "unknown command '$cmd' (run|list)"
    ;;
esac
