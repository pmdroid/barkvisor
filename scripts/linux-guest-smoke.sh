#!/usr/bin/env bash
# First NAT guest-boot smoke for Linux (and local API dry-run on any host).
#
# Flow:
#   1. Build BarkVisorApp (or reuse existing binary)
#   2. Start server on a free port with a temp BARKVISOR_DATA_DIR
#   3. Complete setup via API if needed
#   4. Login
#   5. Pick default NAT network
#   6. Create a small VM (cloud image if BARKVISOR_CLOUD_IMAGE_URL is set,
#      otherwise blank disk via existingDiskId) and attempt start
#   7. Verify GET /api/vms/:id reports running or starting
#
# Usage:
#   ./scripts/linux-guest-smoke.sh
#   DRY_RUN=1 ./scripts/linux-guest-smoke.sh   # syntax + endpoint inventory only
#   SKIP_BUILD=1 ./scripts/linux-guest-smoke.sh
#   BARKVISOR_CLOUD_IMAGE_URL=https://...qcow2 ./scripts/linux-guest-smoke.sh
#
# Env:
#   BARKVISOR_PORT              Prefer this port (else pick free)
#   BARKVISOR_DATA_DIR          Override data dir (else mktemp)
#   BARKVISOR_ADMIN_USER        Default: admin
#   BARKVISOR_ADMIN_PASSWORD    Default: barkvisor-smoke-pass (must be >= 10 chars)
#   BARKVISOR_CLOUD_IMAGE_URL   Cloud-image URL (set by REAL_GUEST=1 default)
#   REAL_GUEST=1                Ubuntu 24.04 arm64 cloud image + cloud-init + SSH probe
#   BARKVISOR_DEFAULT_CLOUD_IMAGE_URL  Override default image when REAL_GUEST=1
#   BARKVISOR_VM_TYPE           Override vmType (default: host-arch mapping)
#   DISK_SIZE_GB                Default: 2 (blank) / 8 (REAL_GUEST)
#   CPU_COUNT / MEMORY_MB       Defaults: 1/512 (blank) or 2/1024 (REAL_GUEST)
#   SSH_HOST_PORT               Host port for guest SSH (default: free port)
#   SKIP_SSH_PROBE=1            Do not wait for SSH after start
#   SSH_WAIT_SECS               Max wait for SSH (default 900; TCG is slow)
#   ALLOW_SSH_TIMEOUT=1         Accept running VM if SSH not ready in time
#   SKIP_BUILD=1                Reuse existing BarkVisorApp binary
#   DRY_RUN=1                   No server/QEMU; validate script + list endpoints
#   ALLOW_NO_QEMU=1             If qemu missing, stop after create (still exercise API)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ADMIN_USER="${BARKVISOR_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${BARKVISOR_ADMIN_PASSWORD:-barkvisor-smoke-pass}"
VM_NAME="${VM_NAME:-linux-guest-smoke}"

# Default Ubuntu 24.04 LTS minimal cloud image (arm64) for cloud-init + QEMU virt.
DEFAULT_CLOUD_IMAGE_URL="${BARKVISOR_DEFAULT_CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img}"

if [[ "${REAL_GUEST:-0}" == "1" ]]; then
  export BARKVISOR_CLOUD_IMAGE_URL="${BARKVISOR_CLOUD_IMAGE_URL:-$DEFAULT_CLOUD_IMAGE_URL}"
  DISK_SIZE_GB="${DISK_SIZE_GB:-8}"
  CPU_COUNT="${CPU_COUNT:-2}"
  MEMORY_MB="${MEMORY_MB:-1024}"
  VM_NAME="${VM_NAME:-linux-real-guest}"
  SSH_WAIT_SECS="${SSH_WAIT_SECS:-900}"
else
  DISK_SIZE_GB="${DISK_SIZE_GB:-2}"
  CPU_COUNT="${CPU_COUNT:-1}"
  MEMORY_MB="${MEMORY_MB:-512}"
  SSH_WAIT_SECS="${SSH_WAIT_SECS:-120}"
fi

# Required API paths exercised by this smoke (documented for DRY_RUN / reviewers)
REQUIRED_ENDPOINTS=(
  "GET  /api/health"
  "GET  /api/setup/status"
  "POST /api/setup/admin"
  "POST /api/setup/bridge/skip"
  "POST /api/setup/complete"
  "POST /api/auth/login"
  "GET  /api/networks"
  "GET  /api/images"
  "POST /api/images/download"
  "GET  /api/images/:id"
  "POST /api/disks"
  "POST /api/vms"
  "POST /api/vms/:id/start"
  "GET  /api/vms/:id"
)

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

# --- DRY_RUN: syntax + endpoint inventory (no server) ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1 — bash -n self-check"
  bash -n "$0"

  log "required API endpoints:"
  for ep in "${REQUIRED_ENDPOINTS[@]}"; do
    echo "  - $ep"
  done

  # Structural: script references must stay aligned with SetupController / VMController
  for path in \
    "/api/setup/status" \
    "/api/setup/admin" \
    "/api/setup/bridge/skip" \
    "/api/setup/complete" \
    "/api/auth/login" \
    "/api/networks" \
    "/api/images/download" \
    "/api/disks" \
    "/api/vms" \
    "/start" \
    "cloudInit" \
    "portForwards" \
    "REAL_GUEST"; do
    grep -qF "$path" "$0" || die "script missing reference to $path"
  done

  log "DRY_RUN OK (no server started)"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (free-port picker)"

# Host arch → guest vmType (API CreateVMRequest currently validates linux-arm64 / windows-arm64;
# lifecycle also accepts linux-amd64 / linux-x86_64 — use host-matched type.)
detect_vm_type() {
  local m
  m="$(uname -m)"
  case "$m" in
    arm64 | aarch64) echo "linux-arm64" ;;
    x86_64 | amd64) echo "linux-amd64" ;;
    *) echo "linux-arm64" ;;
  esac
}

detect_image_arch() {
  # Image download API currently accepts arch "arm64" only.
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    *) echo "arm64" ;;
  esac
}

VM_TYPE="${BARKVISOR_VM_TYPE:-$(detect_vm_type)}"
IMAGE_ARCH="$(detect_image_arch)"

# Free port (or honor BARKVISOR_PORT if free-ish)
pick_port() {
  if [[ -n "${BARKVISOR_PORT:-}" ]]; then
    echo "$BARKVISOR_PORT"
    return
  fi
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

PORT="$(pick_port)"
export BARKVISOR_PORT="$PORT"
export BARKVISOR_DATA_DIR="${BARKVISOR_DATA_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/barkvisor-guest-smoke.XXXXXX")}"
BASE="http://127.0.0.1:${PORT}"
LOG_FILE="${BARKVISOR_DATA_DIR}/server.log"
TOKEN=""
SERVER_PID=""

log "data dir: $BARKVISOR_DATA_DIR"
log "port: $PORT"
log "vmType: $VM_TYPE"

print_log_tail() {
  echo "---- server log tail ($LOG_FILE) ----" >&2
  if [[ -f "$LOG_FILE" ]]; then
    tail -80 "$LOG_FILE" >&2 || true
  else
    echo "(no log file)" >&2
  fi
  echo "---- end log ----" >&2
}

cleanup() {
  local code=$?
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ $code -ne 0 ]]; then
    print_log_tail
  fi
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  print_log_tail
  exit 1
}

api() {
  # api METHOD PATH [curl body args...]
  local method="$1"
  local path="$2"
  shift 2
  local args=(-sS -X "$method" "${BASE}${path}" -H "Content-Type: application/json")
  if [[ -n "${TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

api_code() {
  local method="$1"
  local path="$2"
  shift 2
  local args=(-sS -o /tmp/barkvisor-smoke-body.$$ -w "%{http_code}" -X "$method" "${BASE}${path}" -H "Content-Type: application/json")
  if [[ -n "${TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

# --- build ---
find_bin() {
  if [[ -x "$ROOT/.build/debug/BarkVisorApp" ]]; then
    echo "$ROOT/.build/debug/BarkVisorApp"
  elif [[ -x "$ROOT/.build/release/BarkVisorApp" ]]; then
    echo "$ROOT/.build/release/BarkVisorApp"
  else
    return 1
  fi
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  command -v swift >/dev/null 2>&1 || die "swift not on PATH"
  log "swift build --product BarkVisorApp"
  swift build --product BarkVisorApp
else
  log "SKIP_BUILD=1 — reusing binary"
fi

BIN="$(find_bin)" || die "BarkVisorApp binary not found under .build/"

# QEMU presence (soft unless we plan to start)
QEMU_OK=1
if ! command -v qemu-system-aarch64 >/dev/null 2>&1 && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  QEMU_OK=0
  if [[ "${ALLOW_NO_QEMU:-0}" != "1" ]]; then
    echo "warning: no qemu-system-* on PATH; start may fail. Set ALLOW_NO_QEMU=1 to stop after create." >&2
  fi
fi

# --- start server ---
log "starting BarkVisorApp"
"$BIN" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

ok=0
for _ in $(seq 1 60); do
  if curl -sf "${BASE}/api/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  # bail early if process died
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "server exited before health check"
  fi
  sleep 0.5
done
[[ "$ok" -eq 1 ]] || fail "health check failed"

log "health OK"

# --- setup ---
STATUS_JSON="$(api GET /api/setup/status || true)"
COMPLETE="$(echo "$STATUS_JSON" | jq -r '.complete // false' 2>/dev/null || echo false)"

if [[ "$COMPLETE" != "true" ]]; then
  log "setup incomplete — creating admin + skipping bridge"
  code="$(api_code POST /api/setup/admin -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')")"
  # 200 success; 409 if user already exists with password
  if [[ "$code" != "200" && "$code" != "409" ]]; then
    fail "POST /api/setup/admin returned HTTP $code: $(cat /tmp/barkvisor-smoke-body.$$ 2>/dev/null || true)"
  fi

  code="$(api_code POST /api/setup/bridge/skip -d '{}')"
  [[ "$code" == "200" ]] || fail "POST /api/setup/bridge/skip returned HTTP $code"

  COMPLETE_JSON="$(api POST /api/setup/complete -d '{}')"
  TOKEN="$(echo "$COMPLETE_JSON" | jq -r '.token // empty')"
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    fail "setup complete did not return token: $COMPLETE_JSON"
  fi
  log "setup complete (token from /api/setup/complete)"
else
  log "setup already complete — logging in"
fi

if [[ -z "${TOKEN:-}" ]]; then
  LOGIN_JSON="$(api POST /api/auth/login -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')")"
  TOKEN="$(echo "$LOGIN_JSON" | jq -r '.token // empty')"
  [[ -n "$TOKEN" && "$TOKEN" != "null" ]] || fail "login failed: $LOGIN_JSON"
  log "login OK"
fi

# --- default NAT network ---
NETWORKS_JSON="$(api GET /api/networks)"
NETWORK_ID="$(echo "$NETWORKS_JSON" | jq -r '
  (map(select(.mode=="nat" and (.isDefault==true or .isDefault==1))) | .[0].id)
  // (map(select(.mode=="nat")) | .[0].id)
  // empty
')"
[[ -n "$NETWORK_ID" && "$NETWORK_ID" != "null" ]] || fail "no NAT network found: $NETWORKS_JSON"
log "NAT network: $NETWORK_ID"

# --- image or blank disk ---
CLOUD_IMAGE_ID=""
EXISTING_DISK_ID=""

if [[ -n "${BARKVISOR_CLOUD_IMAGE_URL:-}" ]]; then
  log "downloading cloud image: $BARKVISOR_CLOUD_IMAGE_URL"
  DL_BODY="$(jq -n \
    --arg name "smoke-cloud" \
    --arg url "$BARKVISOR_CLOUD_IMAGE_URL" \
    --arg arch "$IMAGE_ARCH" \
    '{name:$name,url:$url,imageType:"cloud-image",arch:$arch}')"
  code="$(api_code POST /api/images/download -d "$DL_BODY")"
  [[ "$code" == "200" ]] || fail "image download start failed HTTP $code: $(cat /tmp/barkvisor-smoke-body.$$)"
  CLOUD_IMAGE_ID="$(jq -r '.id' /tmp/barkvisor-smoke-body.$$)"
  [[ -n "$CLOUD_IMAGE_ID" && "$CLOUD_IMAGE_ID" != "null" ]] || fail "no image id from download"

  # Poll until ready / error (download can be large)
  ready=0
  for i in $(seq 1 600); do
    IMG_JSON="$(api GET "/api/images/${CLOUD_IMAGE_ID}")"
    st="$(echo "$IMG_JSON" | jq -r '.status // empty')"
    case "$st" in
      ready)
        ready=1
        break
        ;;
      error)
        fail "image download error: $(echo "$IMG_JSON" | jq -r '.error // .')"
        ;;
    esac
    if ((i % 10 == 0)); then
      log "image status=$st (wait ${i}s)"
    fi
    sleep 1
  done
  [[ "$ready" -eq 1 ]] || fail "image download timed out"
  log "cloud image ready: $CLOUD_IMAGE_ID"
else
  log "no BARKVISOR_CLOUD_IMAGE_URL — creating blank ${DISK_SIZE_GB}GB disk (start proves QEMU path; guest will not boot an OS)"
  DISK_BODY="$(jq -n --arg name "${VM_NAME}-disk" --argjson size "$DISK_SIZE_GB" '{name:$name,sizeGB:$size}')"
  code="$(api_code POST /api/disks -d "$DISK_BODY")"
  [[ "$code" == "200" ]] || fail "POST /api/disks failed HTTP $code: $(cat /tmp/barkvisor-smoke-body.$$)"
  EXISTING_DISK_ID="$(jq -r '.id' /tmp/barkvisor-smoke-body.$$)"
  [[ -n "$EXISTING_DISK_ID" && "$EXISTING_DISK_ID" != "null" ]] || fail "no disk id"
  log "disk: $EXISTING_DISK_ID"
fi

# --- optional SSH key for cloud-init ---
SSH_PUBKEY=""
SSH_KEY_PATH=""
SSH_HOST_PORT="${SSH_HOST_PORT:-}"
if [[ -n "$CLOUD_IMAGE_ID" && "${SKIP_SSH_PROBE:-0}" != "1" ]]; then
  if command -v ssh-keygen >/dev/null 2>&1; then
    SSH_KEY_PATH="${BARKVISOR_DATA_DIR}/smoke_guest_ed25519"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH" -C "barkvisor-smoke" >/dev/null
    SSH_PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"
    log "generated smoke SSH key: $SSH_KEY_PATH"
  else
    log "ssh-keygen missing — skipping cloud-init SSH key injection"
  fi
  if [[ -z "$SSH_HOST_PORT" ]]; then
    SSH_HOST_PORT="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  fi
  log "SSH port-forward hostPort=$SSH_HOST_PORT -> guest 22"
fi

# --- create VM ---
if [[ -n "$CLOUD_IMAGE_ID" ]]; then
  VM_BODY="$(jq -n \
    --arg name "$VM_NAME" \
    --arg vmType "$VM_TYPE" \
    --argjson cpu "$CPU_COUNT" \
    --argjson mem "$MEMORY_MB" \
    --argjson disk "$DISK_SIZE_GB" \
    --arg net "$NETWORK_ID" \
    --arg cloud "$CLOUD_IMAGE_ID" \
    --arg pubkey "$SSH_PUBKEY" \
    --argjson hostPort "${SSH_HOST_PORT:-0}" \
    '
    {
      name:$name,
      vmType:$vmType,
      cpuCount:$cpu,
      memoryMB:$mem,
      diskSizeGB:$disk,
      networkId:$net,
      cloudImageId:$cloud,
      uefi: true
    }
    + (if $pubkey != "" then
        {cloudInit: {sshAuthorizedKeys: [$pubkey], userData: "package_update: false\n"}}
      else {} end)
    + (if $hostPort > 0 then
        {portForwards: [{protocol: "tcp", hostPort: $hostPort, guestPort: 22}]}
      else {} end)
    ')"
else
  VM_BODY="$(jq -n \
    --arg name "$VM_NAME" \
    --arg vmType "$VM_TYPE" \
    --argjson cpu "$CPU_COUNT" \
    --argjson mem "$MEMORY_MB" \
    --arg net "$NETWORK_ID" \
    --arg diskId "$EXISTING_DISK_ID" \
    '{
      name:$name,
      vmType:$vmType,
      cpuCount:$cpu,
      memoryMB:$mem,
      networkId:$net,
      existingDiskId:$diskId
    }')"
fi

log "creating VM"
code="$(api_code POST /api/vms -d "$VM_BODY")"
# 200 created, 202 provisioning (cloud image clone)
if [[ "$code" != "200" && "$code" != "202" ]]; then
  fail "POST /api/vms failed HTTP $code: $(cat /tmp/barkvisor-smoke-body.$$)"
fi

VM_JSON="$(cat /tmp/barkvisor-smoke-body.$$)"
# Response may be VM directly or {taskID, vm}
VM_ID="$(echo "$VM_JSON" | jq -r '.vm.id // .id // empty')"
[[ -n "$VM_ID" && "$VM_ID" != "null" ]] || fail "no VM id in create response: $VM_JSON"
log "VM id: $VM_ID"

# Wait out provisioning if needed
for i in $(seq 1 120); do
  CUR="$(api GET "/api/vms/${VM_ID}")"
  st="$(echo "$CUR" | jq -r '.state // empty')"
  if [[ "$st" != "provisioning" ]]; then
    break
  fi
  sleep 1
done
st="$(api GET "/api/vms/${VM_ID}" | jq -r '.state // empty')"
[[ "$st" != "provisioning" ]] || fail "VM stuck provisioning"
[[ "$st" != "error" ]] || fail "VM in error state before start"
log "VM state before start: $st"

if [[ "$QEMU_OK" -eq 0 && "${ALLOW_NO_QEMU:-0}" == "1" ]]; then
  log "ALLOW_NO_QEMU=1 and no qemu — skipping start"
  log "linux-guest-smoke: OK (create-only)"
  exit 0
fi

# --- start ---
log "starting VM"
code="$(api_code POST "/api/vms/${VM_ID}/start" -d '{}')"
if [[ "$code" != "204" && "$code" != "200" ]]; then
  fail "POST /api/vms/${VM_ID}/start failed HTTP $code: $(cat /tmp/barkvisor-smoke-body.$$ 2>/dev/null || true)"
fi

# Verify running/starting
final=""
for _ in $(seq 1 30); do
  CUR="$(api GET "/api/vms/${VM_ID}")"
  final="$(echo "$CUR" | jq -r '.state // empty')"
  case "$final" in
    running | starting)
      log "VM state: $final"
      if [[ -n "$CLOUD_IMAGE_ID" && -n "${SSH_KEY_PATH:-}" && "${SKIP_SSH_PROBE:-0}" != "1" && -n "${SSH_HOST_PORT:-}" ]]; then
        log "waiting up to ${SSH_WAIT_SECS}s for guest SSH on 127.0.0.1:${SSH_HOST_PORT} (TCG boots are slow)"
        ssh_ok=0
        for i in $(seq 1 "$SSH_WAIT_SECS"); do
          if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=2 -o LogLevel=ERROR \
            -i "$SSH_KEY_PATH" -p "$SSH_HOST_PORT" ubuntu@127.0.0.1 "echo barkvisor-ssh-ok" 2>/dev/null \
            | grep -q barkvisor-ssh-ok; then
            ssh_ok=1
            log "guest SSH OK after ${i}s"
            break
          fi
          if ((i % 30 == 0)); then
            log "still waiting for SSH (${i}/${SSH_WAIT_SECS}s)…"
          fi
          sleep 1
        done
        if [[ "$ssh_ok" -ne 1 ]]; then
          if [[ "${ALLOW_SSH_TIMEOUT:-0}" == "1" ]]; then
            log "SSH probe timed out (ALLOW_SSH_TIMEOUT=1) — create+start treated as OK"
          else
            fail "guest SSH not ready within ${SSH_WAIT_SECS}s (set ALLOW_SSH_TIMEOUT=1 to accept QEMU-running-only)"
          fi
        fi
      fi
      log "linux-guest-smoke: OK"
      exit 0
      ;;
    error)
      fail "VM entered error state after start: $CUR"
      ;;
  esac
  sleep 0.5
done

fail "VM did not reach running/starting (last state=${final:-unknown})"
