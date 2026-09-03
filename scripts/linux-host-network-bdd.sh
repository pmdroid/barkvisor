#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/linux-smoke-common.sh
source "$ROOT/scripts/lib/linux-smoke-common.sh"

FEATURE="$ROOT/features/host-network-extra-ip.feature"
SCENARIO="add an extra IP then remove it"
NIC="${HOSTNET_NIC:-bvtest0}"
PRIMARY="${HOSTNET_PRIMARY:-10.200.55.1/24}"
ALIAS="${HOSTNET_ALIAS:-10.200.55.50/24}"
export BARKVISOR_ADMIN_USER="${BARKVISOR_ADMIN_USER:-admin}"
export BARKVISOR_ADMIN_PASSWORD="${BARKVISOR_ADMIN_PASSWORD:-barkvisor-smoke-pass}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1 — syntax + feature"
  bash -n "$0"
  bash -n "$ROOT/scripts/lib/linux-smoke-common.sh"
  [[ -f "$FEATURE" ]] || die "missing $FEATURE"
  grep -qF "Scenario: $SCENARIO" "$FEATURE" || die "feature missing scenario: $SCENARIO"
  grep -qF "/api/system/bridges" "$FEATURE" || grep -qF "address-only" "$FEATURE" || die "feature missing address-only apply"
  grep -qF "ip addr del" "$FEATURE" || die "feature missing ip addr del"
  log "DRY_RUN OK"
  exit 0
fi

if [[ "${BDD_FORCE_SKIP:-0}" == "1" ]]; then
  echo "SKIP: forced skip of scenario \"$SCENARIO\"."
  exit 0
fi

[[ "$(uname -s)" == "Linux" ]] || {
  echo "SKIP: Linux required; use ./scripts/linux-host-network-docker.sh"
  exit 0
}

command -v ip >/dev/null 2>&1 || die "ip (iproute2) is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ "$(id -u)" -eq 0 ]] || die "run as root (Docker or sudo)"

mkdir -p /etc/systemd/network /run/barkvisor

cleanup_nic() {
  nmcli connection delete "$NIC" >/dev/null 2>&1 || true
  ip link del "$NIC" 2>/dev/null || true
  ip link del "${NIC}p" 2>/dev/null || true
  rm -rf "/etc/systemd/network/20-${NIC}.network" "/etc/systemd/network/20-${NIC}.network.d" \
    "/etc/systemd/network/90-barkvisor-${NIC}.network" "/etc/netplan/90-barkvisor-${NIC}-aliases.yaml" \
    2>/dev/null || true
  rmdir /etc/netplan 2>/dev/null || true
}

has_inet() {
  ip -4 -o addr show dev "$1" 2>/dev/null | grep -F "inet $2" >/dev/null
}

make_nic() {
  cleanup_nic
  mkdir -p /etc/systemd/network
  rm -rf "/etc/systemd/network/20-${NIC}.network.d" "/etc/systemd/network/90-barkvisor-${NIC}.network"
  /usr/bin/networkctl reload >/dev/null 2>&1 || true
  if ip link show "$NIC" >/dev/null 2>&1; then
    log "reusing $NIC"
  elif ip link add "$NIC" type dummy; then
    log "dummy $NIC"
  else
    ip link add "$NIC" type veth peer name "${NIC}p"
    ip link set "${NIC}p" up
    log "veth $NIC"
  fi
  ip link set "$NIC" up
  printf '%s\n' "[Match]" "Name=${NIC}" "" "[Network]" "DHCP=no" "Address=${PRIMARY}" \
    >"/etc/systemd/network/20-${NIC}.network"
  rm -rf "/etc/systemd/network/20-${NIC}.network.d"
  /usr/bin/networkctl reload >/dev/null 2>&1 || true
  nmcli device reapply "$NIC" >/dev/null 2>&1 || true
  ip addr flush dev "$NIC" || true
  ip addr add "$PRIMARY" dev "$NIC" || true
  ip addr del "$ALIAS" dev "$NIC" >/dev/null 2>&1 || true
  has_inet "$NIC" "$PRIMARY" || die "failed to add $PRIMARY on $NIC"
  if has_inet "$NIC" "$ALIAS"; then
    die "alias $ALIAS already on $NIC before Apply: $(ip -4 -o addr show dev "$NIC")"
  fi
  log "ip before Apply: $(ip -4 -o addr show dev "$NIC")"
}

post_bridges() {
  local body="$1"
  api_code POST /api/system/bridges -d "$body"
}

require_http() {
  local code="$1"
  local want="$2"
  [[ "$code" == "$want" ]] || fail "POST /api/system/bridges HTTP $code want $want: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
}

require_success() {
  local ok
  ok="$(jq -r '.success // false' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  [[ "$ok" == "true" ]] || fail "bridges call not success: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
}

commands_file() {
  jq -r '.commands // [] | .[]' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}"
}

apply_keep() {
  local body="$1"
  local code
  code="$(post_bridges "$body")"
  require_http "$code" "200"
  require_success
  local pending
  pending="$(jq -r '.pendingCommit // false' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
  if [[ "$pending" == "true" ]]; then
    local commit
    commit="$(jq -n --arg nic "$NIC" '{interface:$nic,bridge:$nic,action:"commit",confirm:true}')"
    code="$(post_bridges "$commit")"
    require_http "$code" "200"
    require_success
  fi
}

export BARKVISOR_PORT="${BARKVISOR_PORT:-$(pick_port)}"
export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/barkvisor-hostnet-bdd.XXXXXX")}"
TOKEN=""
SERVER_PID=""

log "scenario: $SCENARIO"
log "data dir: $BARKVISOR_DATA_DIR"
log "port: $BARKVISOR_PORT"
log "nic: $NIC primary=$PRIMARY alias=$ALIAS"

smoke_cleanup_trap
trap 'cleanup_nic || true; smoke_cleanup || true' EXIT

make_nic
if [[ -n "${BIN:-}" && -x "${BIN}" ]]; then
  log "BIN=$BIN"
else
  build_barkvisor
  BIN="$(find_bin)" || die "BarkVisorApp binary not found"
fi
start_server "$BIN"
wait_health 60 0.5
setup_or_login

ADD_BODY="$(jq -n --arg nic "$NIC" --arg cidr "$ALIAS" '{
  interface: $nic,
  action: "dry-run",
  confirm: true,
  addresses: [{kind:"dhcp"},{kind:"alias",cidr:$cidr}]
}')"
log "add body: $ADD_BODY"
code="$(post_bridges "$ADD_BODY")"
require_http "$code" "200"
require_success
log "dry-run add: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
log "ifaces: $(api GET /api/system/interfaces)"
commands_file | grep -F "ip addr add $ALIAS dev $NIC" >/dev/null \
  || fail "dry-run add missing ip addr add $ALIAS: $(commands_file)"

ADD_APPLY="$(echo "$ADD_BODY" | jq '.action="apply"')"
apply_keep "$ADD_APPLY"
has_inet "$NIC" "$ALIAS" || fail "after add, $ALIAS missing on $NIC: $(ip -4 -o addr show dev "$NIC")"
has_inet "$NIC" "$PRIMARY" || fail "after add, primary $PRIMARY gone on $NIC: $(ip -4 -o addr show dev "$NIC")"
log "live after add: $(ip -4 -o addr show dev "$NIC")"
log "ifaces after add: $(api GET /api/system/interfaces)"

DEL_BODY="$(jq -n --arg nic "$NIC" '{
  interface: $nic,
  action: "dry-run",
  confirm: true,
  addresses: [{kind:"dhcp"}]
}')"
code="$(post_bridges "$DEL_BODY")"
require_http "$code" "200"
require_success
log "dry-run remove: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
commands_file | grep -F "ip addr del $ALIAS dev $NIC" >/dev/null \
  || fail "dry-run remove missing ip addr del $ALIAS: $(commands_file)"
if commands_file | grep -F "ip addr add $ALIAS" >/dev/null; then
  fail "dry-run remove still adds $ALIAS: $(commands_file)"
fi

DEL_APPLY="$(echo "$DEL_BODY" | jq '.action="apply"')"
apply_keep "$DEL_APPLY"
if has_inet "$NIC" "$ALIAS"; then
  fail "after remove, $ALIAS still on $NIC: $(ip -4 -o addr show dev "$NIC")"
fi
has_inet "$NIC" "$PRIMARY" || fail "primary $PRIMARY gone after remove: $(ip -4 -o addr show dev "$NIC")"
log "live after remove: $(ip -4 -o addr show dev "$NIC")"
log "OK: $SCENARIO"
trap - EXIT
cleanup_nic || true
stop_server "${SERVER_PID:-}" || true
exit 0
