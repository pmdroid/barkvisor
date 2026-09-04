#!/usr/bin/env bash
# PAS-188: probe every documented OpenAPI operation on a local Device.
#
# Usage:
#   ./scripts/api-contract-bdd.sh
#   DRY_RUN=1 ./scripts/api-contract-bdd.sh
#   API_BDD_QEMU=1 ./scripts/api-contract-bdd.sh   # also HIT start/stop/restart
#   API_BDD_USB=1 ./scripts/api-contract-bdd.sh    # attach a connected USB device if any
#
# Not in default mise prepush. Fast (no QEMU). mise run api-bdd
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/linux-smoke-common.sh
source "$ROOT/scripts/lib/linux-smoke-common.sh"

FEATURE="$ROOT/features/api-contract.feature"
PROBE="$ROOT/scripts/lib/api-contract-probe.py"
OPENAPI="$ROOT/docs/api/openapi.yaml"

export BARKVISOR_ADMIN_USER="${BARKVISOR_ADMIN_USER:-admin}"
if [[ -z "${BARKVISOR_ADMIN_PASSWORD:-}" ]]; then
  echo "error: BARKVISOR_ADMIN_PASSWORD is required; no default is used (set it explicitly to avoid creating well-known admin accounts)" >&2
  exit 1
fi
export BARKVISOR_ADMIN_PASSWORD

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1 — syntax + OpenAPI vs feature"
  bash -n "$0"
  bash -n "$ROOT/scripts/lib/linux-smoke-common.sh"
  python3 -m py_compile "$PROBE"
  [[ -f "$FEATURE" ]] || die "missing $FEATURE"
  [[ -f "$OPENAPI" ]] || die "missing $OPENAPI"
  grep -q "every documented API operation is probed" "$FEATURE" \
    || die "feature missing the coverage scenario"
  while IFS= read -r p; do
    grep -qF "$p" "$FEATURE" || true
  done < <(python3 - <<PY
import re
text=open("$OPENAPI",encoding="utf-8").read()
paths=set(re.findall(r"^  (/[^:]+):", text, re.M))
print(len(paths), "paths in OpenAPI")
PY
)
  log "DRY_RUN OK"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

export BARKVISOR_PORT="${BARKVISOR_PORT:-$(pick_port)}"
export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/barkvisor-api-bdd.XXXXXX")}"
TOKEN=""
SERVER_PID=""

log "data dir: $BARKVISOR_DATA_DIR"
log "port: $BARKVISOR_PORT"
smoke_cleanup_trap
build_barkvisor
BIN="$(find_bin)" || die "BarkVisorApp binary not found"
start_server "$BIN"
wait_health
setup_or_login

# Seed resources so {id} paths can be HIT.
NETWORK_ID="$(api GET /api/networks | jq -r '.[0].id // empty')"
[[ -n "$NETWORK_ID" ]] || fail "no NAT network after setup"

DISK_BODY="$(jq -n '{name:"bdd-disk",sizeGB:2,format:"qcow2"}')"
DISK_CODE="$(api_code POST /api/disks -d "$DISK_BODY")"
[[ "$DISK_CODE" == "200" || "$DISK_CODE" == "201" ]] \
  || fail "POST /api/disks HTTP $DISK_CODE: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
DISK_ID="$(jq -r '.id // empty' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
[[ -n "$DISK_ID" ]] || fail "disk create returned no id"

VM_TYPE="${BARKVISOR_VM_TYPE:-linux-amd64}"
case "$(uname -m)" in
  arm64|aarch64) VM_TYPE="${BARKVISOR_VM_TYPE:-linux-arm64}" ;;
esac
VM_BODY="$(jq -n --arg name "bdd-api" --arg disk "$DISK_ID" --arg net "$NETWORK_ID" --arg vt "$VM_TYPE" \
  '{name:$name,osFamily:"linux",cpuCount:1,memoryMB:512,existingDiskId:$disk,networkId:$net,vmType:$vt}')"
VM_CODE="$(api_code POST /api/vms -d "$VM_BODY")"
[[ "$VM_CODE" == "200" || "$VM_CODE" == "201" || "$VM_CODE" == "202" ]] \
  || fail "POST /api/vms HTTP $VM_CODE: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
VM_ID="$(jq -r '.id // .vm.id // empty' "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"
[[ -n "$VM_ID" ]] || fail "VM create returned no id"

HOST_ID="$(api GET /api/home/devices | jq -r '.devices[0].hostId // .[0].hostId // empty')"
IMAGE_ID="$(api GET /api/images | jq -r '.[0].id // empty')"

export TOKEN
export API_CONTRACT_OPENAPI="$OPENAPI"
export BASE="${BASE:-http://127.0.0.1:${BARKVISOR_PORT}}"
export SEED_VM_ID="$VM_ID"
export SEED_DISK_ID="$DISK_ID"
export SEED_NETWORK_ID="$NETWORK_ID"
export SEED_IMAGE_ID="${IMAGE_ID:-}"
export SEED_HOST_ID="${HOST_ID:-}"

log "seeds vm=$VM_ID disk=$DISK_ID net=$NETWORK_ID host=${HOST_ID:-none} image=${IMAGE_ID:-none}"
python3 "$PROBE"
log "api-bdd OK"
