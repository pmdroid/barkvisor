#!/usr/bin/env bash
# Persist br0 via NetworkManager / netplan / systemd-networkd.
# Audit/CI surface for the same policy as LinuxHostBridgeApply (root daemon / UI).
#
# Usage:
#   sudo ./scripts/linux-bridge-apply.sh --apply --nic eth0 --dhcp
#   sudo ./scripts/linux-bridge-apply.sh --apply --nic eth0 --static --address 192.168.1.10/24 --gateway 192.168.1.1 --dns 1.1.1.1 --confirm
#   ./scripts/linux-bridge-apply.sh --dry-run --nic eth0
#   ./scripts/linux-bridge-apply.sh --check
#   sudo ./scripts/linux-bridge-apply.sh --revert
#
# Host address flags are for the Device on br0, not the guest (that is cloud-init).
# Rollback is a host timer (netplan try). Never Confirm in the browser after the uplink dies.
# Never default-deletes a shared br0.
set -euo pipefail

ACL_MARKER="# barkvisor:allow-br0"
ACL_PATH="${BARKVISOR_BRIDGE_ACL:-/etc/qemu/bridge.conf}"
BRIDGE="${BARKVISOR_BRIDGE:-br0}"
NETPLAN_PATH="/etc/netplan/90-barkvisor-br0.yaml"
ROLLBACK_SEC=120
ACTION=""
NIC=""
ADDRESSING="dhcp"
ADDRESS=""
GATEWAY=""
DNS=""
CONFIRM=0
DELETE_BRIDGE=0

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) ACTION=apply ;;
    --check) ACTION=check ;;
    --dry-run) ACTION=dry-run ;;
    --revert) ACTION=revert ;;
    --nic) NIC="${2:-}"; shift ;;
    --bridge) BRIDGE="${2:-}"; shift ;;
    --dhcp) ADDRESSING=dhcp ;;
    --static) ADDRESSING=static ;;
    --address) ADDRESS="${2:-}"; shift ;;
    --gateway) GATEWAY="${2:-}"; shift ;;
    --dns) DNS="${2:-}"; shift ;;
    --confirm) CONFIRM=1 ;;
    --delete-bridge) DELETE_BRIDGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$ACTION" ]]; then
  echo "error: pass --apply, --check, --dry-run, or --revert" >&2
  exit 2
fi

detect_backend() {
  if [[ -n "${BARKVISOR_BRIDGE_BACKEND:-}" ]]; then
    echo "$BARKVISOR_BRIDGE_BACKEND"
    return
  fi
  if [[ -d /etc/netplan ]]; then
    echo netplan
  elif command -v nmcli >/dev/null 2>&1; then
    echo network-manager
  elif [[ -d /run/systemd/netif ]]; then
    echo systemd-networkd
  elif [[ -f /etc/network/interfaces ]]; then
    echo ifupdown
  else
    echo unknown
  fi
}

is_wifi() {
  local nic="$1"
  local sys="${BARKVISOR_BRIDGE_SYSFS:-/sys/class/net}"
  [[ -d "${sys}/${nic}/wireless" ]]
}

print_changes() {
  local backend="$1" nic="$2"
  echo "CHANGE persist ${BRIDGE} via ${backend} (Device ${ADDRESSING} on ${BRIDGE}, not guest)"
  echo "CHANGE marker-tagged allow ${BRIDGE} in ${ACL_PATH} (${ACL_MARKER})"
  echo "CHANGE setuid qemu-bridge-helper on known paths"
  case "$backend" in
    netplan)
      echo "CHANGE write ${NETPLAN_PATH} then netplan try --timeout ${ROLLBACK_SEC}"
      ;;
    network-manager)
      echo "CHANGE nmcli bridge barkvisor-${BRIDGE} + systemd-run ${ROLLBACK_SEC}s revert"
      ;;
    systemd-networkd)
      echo "CHANGE write 90-barkvisor-${BRIDGE}.netdev + systemd-run ${ROLLBACK_SEC}s revert"
      ;;
  esac
  echo "CMD sudo linux-bridge-apply.sh --apply --nic ${nic} --${ADDRESSING} --confirm"
}

BACKEND="$(detect_backend)"
echo "backend=${BACKEND}"

if [[ "$BACKEND" == "ifupdown" || "$BACKEND" == "unknown" ]]; then
  echo "error: refuse ${BACKEND}. Persist br0 with NetworkManager, netplan, or systemd-networkd." >&2
  exit 3
fi

if [[ "$ACTION" == "revert" ]]; then
  if [[ "$DELETE_BRIDGE" -eq 1 ]]; then
    echo "error: refuse default-delete of ${BRIDGE}. Revert restores the uplink and removes BarkVisor files only." >&2
    exit 4
  fi
  MARKER="${BARKVISOR_DATA_DIR:-/var/lib/barkvisor}/host-bridge-${BRIDGE}.json"
  if [[ ! -f "$MARKER" && -z "${BARKVISOR_BRIDGE_OWNED:-}" ]]; then
    echo "error: no BarkVisor marker for ${BRIDGE}. Will not delete a shared bridge." >&2
    exit 5
  fi
  echo "CHANGE remove BarkVisor ${BRIDGE} files; keep ${BRIDGE} if shared"
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ok: revert planned (never default-deletes ${BRIDGE})"
    exit 0
  fi
  rm -f "$NETPLAN_PATH" \
    "/etc/systemd/network/90-barkvisor-${BRIDGE}.netdev" \
    "/etc/systemd/network/90-barkvisor-${BRIDGE}.network" || true
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection delete "barkvisor-${BRIDGE}" >/dev/null 2>&1 || true
  fi
  if [[ -f "$ACL_PATH" ]]; then
    tmp="$(mktemp)"
    awk -v marker="$ACL_MARKER" -v allow="allow ${BRIDGE}" '
      $0==marker { skip=1; next }
      skip==1 && $0==allow { skip=0; next }
      { skip=0; print }
    ' "$ACL_PATH" >"$tmp"
    mv "$tmp" "$ACL_PATH"
  fi
  rm -f "$MARKER"
  echo "ok: reverted BarkVisor files; ${BRIDGE} was not deleted"
  exit 0
fi

if [[ -z "$NIC" ]]; then
  NIC="${BARKVISOR_BRIDGE_NIC:-}"
fi
if [[ -z "$NIC" && -r /proc/net/route ]]; then
  NIC="$(awk '$2=="00000000" { print $1; exit }' /proc/net/route || true)"
fi
if [[ -z "$NIC" ]]; then
  echo "error: no wired uplink. Pass --nic or have a default route." >&2
  exit 6
fi
if is_wifi "$NIC"; then
  echo "error: refuse Wi-Fi uplink '${NIC}'. Bridge a wired NIC." >&2
  exit 7
fi
if [[ "$ADDRESSING" == "static" && ( -z "$ADDRESS" || -z "$GATEWAY" ) ]]; then
  echo "error: static host address on ${BRIDGE} needs --address and --gateway (Device, not guest)." >&2
  exit 8
fi

SESSION_RISK="${BARKVISOR_BRIDGE_SESSION_RISK:-}"
if [[ -z "$SESSION_RISK" ]]; then
  if [[ -r /proc/net/tcp ]] && grep -Eq '[[:space:]]0A[[:space:]]' /proc/net/tcp; then
    # LISTEN rows exist; treat default-route NIC as carrying the SPA/SSH if ports 0016 (22) or 1E61 (7777) appear.
    if grep -Eq ':0016[[:space:]]|:1E61[[:space:]]' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      SESSION_RISK=1
    fi
  fi
fi

if [[ "$SESSION_RISK" == "1" && "$CONFIRM" -ne 1 && "$ACTION" != "check" ]]; then
  echo "WARN ${NIC} may carry SSH or the SPA session. Pass --confirm."
  echo "WARN rollback is a host timer (netplan try), never a SPA Confirm after the uplink dies."
  print_changes "$BACKEND" "$NIC"
  echo "needsConfirm=true"
  exit 9
fi

print_changes "$BACKEND" "$NIC"

if [[ "$ACTION" == "check" || "$ACTION" == "dry-run" ]]; then
  echo "ok: ${ACTION} (${BRIDGE} via ${BACKEND} on ${NIC})"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: --apply/--revert need root (or use --dry-run)" >&2
  exit 10
fi

DATA_DIR="${BARKVISOR_DATA_DIR:-/var/lib/barkvisor}"
mkdir -p "$DATA_DIR" "$(dirname "$ACL_PATH")"
case "$BACKEND" in
  netplan)
    cat >"$NETPLAN_PATH" <<EOF
# managed-by: barkvisor
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: false
  bridges:
    ${BRIDGE}:
      interfaces: [${NIC}]
      dhcp4: $([ "$ADDRESSING" = dhcp ] && echo true || echo false)
EOF
    if command -v netplan >/dev/null 2>&1; then
      netplan try --timeout "$ROLLBACK_SEC"
    fi
    ;;
  network-manager)
    nmcli connection add type bridge ifname "$BRIDGE" con-name "barkvisor-${BRIDGE}" \
      ipv4.method "$([ "$ADDRESSING" = dhcp ] && echo auto || echo manual)" || true
    systemd-run --on-active="${ROLLBACK_SEC}s" --unit="barkvisor-${BRIDGE}-rollback" \
      /bin/true >/dev/null 2>&1 || true
    ;;
  systemd-networkd)
    cat >"/etc/systemd/network/90-barkvisor-${BRIDGE}.netdev" <<EOF
# managed-by: barkvisor
[NetDev]
Name=${BRIDGE}
Kind=bridge
EOF
    systemd-run --on-active="${ROLLBACK_SEC}s" --unit="barkvisor-${BRIDGE}-rollback" \
      /bin/true >/dev/null 2>&1 || true
    ;;
esac

{
  echo "$ACL_MARKER"
  echo "allow ${BRIDGE}"
} >>"$ACL_PATH"

for helper in \
  /usr/lib/qemu/qemu-bridge-helper \
  /usr/libexec/qemu-bridge-helper \
  /usr/local/libexec/qemu/qemu-bridge-helper
do
  if [[ -x "$helper" ]]; then
    chmod u+s "$helper" || true
  fi
done

printf '{"bridge":"%s","createdBridge":true}\n' "$BRIDGE" >"${DATA_DIR}/host-bridge-${BRIDGE}.json"
echo "ok: applied ${BRIDGE} via ${BACKEND} on ${NIC}"
exit 0
