# Shared helpers for Linux smoke entry points.
# Source from scripts/linux-*.sh after ROOT is set:
#   # shellcheck source=lib/linux-smoke-common.sh
#   source "$ROOT/scripts/lib/linux-smoke-common.sh"
#
# Provides: die, log, fail, pick_port, pick_free_port, find_bin, build_barkvisor,
# start_server, stop_server, wait_health, api, api_code, setup_or_login,
# print_log_tail, smoke_cleanup_trap, smoke_track_pid, smoke_track_log
#
# Env used:
#   BARKVISOR_PORT, BARKVISOR_DATA_DIR, BARKVISOR_AGENT_PORT
#   BARKVISOR_ADMIN_USER, BARKVISOR_ADMIN_PASSWORD
#   SKIP_BUILD, TOKEN (set by setup_or_login), SERVER_PID, LOG_FILE, BASE
#   SMOKE_PIDS / SMOKE_LOG_FILES (multi-daemon; PAS-185)

SMOKE_PIDS=()
SMOKE_LOG_FILES=()

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

print_one_log_tail() {
  local log_file="$1"
  echo "---- server log tail (${log_file}) ----" >&2
  if [[ -n "${log_file}" && -f "$log_file" ]]; then
    tail -80 "$log_file" >&2 || true
  else
    echo "(no log file)" >&2
  fi
  echo "---- end log ----" >&2
}

print_log_tail() {
  local files=()
  local f seen=" "
  if [[ ${#SMOKE_LOG_FILES[@]} -gt 0 ]]; then
    files+=("${SMOKE_LOG_FILES[@]}")
  fi
  if [[ -n "${LOG_FILE:-}" ]]; then
    files+=("$LOG_FILE")
  elif [[ -n "${BARKVISOR_DATA_DIR:-}" ]]; then
    files+=("${BARKVISOR_DATA_DIR}/server.log")
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "---- no server logs ----" >&2
    return
  fi
  for f in "${files[@]}"; do
    case "$seen" in
      *" $f "*) continue ;;
    esac
    seen+="$f "
    print_one_log_tail "$f"
  done
}

fail() {
  echo "error: $*" >&2
  print_log_tail
  exit 1
}

smoke_track_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  SMOKE_PIDS+=("$pid")
}

smoke_track_log() {
  local log_file="$1"
  [[ -n "$log_file" ]] || return 0
  SMOKE_LOG_FILES+=("$log_file")
}

stop_server() {
  local pid="${1:-${SERVER_PID:-}}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

smoke_cleanup() {
  local code=$?
  local pid
  if [[ ${#SMOKE_PIDS[@]} -gt 0 ]]; then
    for pid in "${SMOKE_PIDS[@]}"; do
      stop_server "$pid"
    done
  fi
  stop_server "${SERVER_PID:-}"
  if [[ $code -ne 0 ]]; then
    print_log_tail
  fi
}

# Install EXIT trap (idempotent enough for smoke scripts).
smoke_cleanup_trap() {
  trap smoke_cleanup EXIT
}

wait_bound_port() {
  local file="$1"
  local attempts="${2:-80}"
  local i p
  for i in $(seq 1 "$attempts"); do
    if [[ -f "$file" ]]; then
      p="$(tr -d '[:space:]' <"$file")"
      if [[ "$p" =~ ^[1-9][0-9]*$ ]] && [[ "$p" -le 65535 ]]; then
        echo "$p"
        return 0
      fi
    fi
    if [[ -n "${SERVER_PID:-}" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

# Always bind an ephemeral port (ignores BARKVISOR_PORT). For multi-daemon.
pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

pick_port() {
  if [[ -n "${BARKVISOR_PORT:-}" ]]; then
    echo "$BARKVISOR_PORT"
    return
  fi
  pick_free_port
}

find_bin() {
  local root="${ROOT:-.}"
  if [[ -x "$root/.build/debug/BarkVisorApp" ]]; then
    echo "$root/.build/debug/BarkVisorApp"
  elif [[ -x "$root/.build/release/BarkVisorApp" ]]; then
    echo "$root/.build/release/BarkVisorApp"
  else
    return 1
  fi
}

build_barkvisor() {
  local root="${ROOT:-.}"
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log "SKIP_BUILD=1 — reusing binary"
    return 0
  fi
  # Best-effort SONAME shims for Ubuntu hosts newer than the Swift LTS toolchain.
  if [[ -f "${root}/scripts/lib/linux-swift-compat.sh" ]]; then
    # shellcheck source=linux-swift-compat.sh
    source "${root}/scripts/lib/linux-swift-compat.sh"
    barkvisor_ensure_swift_compat || true
    barkvisor_export_swift_env
  fi
  command -v swift >/dev/null 2>&1 || die "swift not on PATH"
  log "swift build --product BarkVisorApp"
  (cd "$root" && swift build --product BarkVisorApp)
}

# Start server in background; sets SERVER_PID, LOG_FILE, BASE.
# Requires BARKVISOR_PORT and BARKVISOR_DATA_DIR.
start_server() {
  local bin="$1"
  [[ -x "$bin" ]] || die "binary not executable: $bin"
  [[ -n "${BARKVISOR_PORT:-}" ]] || die "BARKVISOR_PORT not set"
  [[ -n "${BARKVISOR_DATA_DIR:-}" ]] || die "BARKVISOR_DATA_DIR not set"

  # Runtime may need the same SONAME shims as the toolchain (dynamic link).
  if [[ -f "${ROOT:-.}/scripts/lib/linux-swift-compat.sh" ]]; then
    # shellcheck source=linux-swift-compat.sh
    source "${ROOT:-.}/scripts/lib/linux-swift-compat.sh"
    barkvisor_export_swift_env
  fi

  export BARKVISOR_PORT BARKVISOR_DATA_DIR
  if [[ -n "${BARKVISOR_AGENT_PORT:-}" ]]; then
    export BARKVISOR_AGENT_PORT
  fi
  LOG_FILE="${BARKVISOR_DATA_DIR}/server.log"
  # Export so Python/other child probes (api-contract-probe.py) hit this port.
  export BASE="http://127.0.0.1:${BARKVISOR_PORT}"

  log "starting BarkVisorApp (port ${BARKVISOR_PORT}${BARKVISOR_AGENT_PORT:+, agent ${BARKVISOR_AGENT_PORT}})"
  "$bin" >"$LOG_FILE" 2>&1 &
  SERVER_PID=$!
  smoke_track_pid "$SERVER_PID"
  smoke_track_log "$LOG_FILE"
}

# Wait until /api/health succeeds or fail.
# Args: max attempts (default 60), sleep secs (default 0.5)
wait_health() {
  local attempts="${1:-60}"
  local sleep_s="${2:-0.5}"
  local base="${BASE:-http://127.0.0.1:${BARKVISOR_PORT}}"
  local ok=0
  local i
  for i in $(seq 1 "$attempts"); do
    if curl -sf "${base}/api/health" >/dev/null 2>&1; then
      ok=1
      break
    fi
    if [[ -n "${SERVER_PID:-}" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      fail "server exited before health check"
    fi
    sleep "$sleep_s"
  done
  [[ "$ok" -eq 1 ]] || fail "health check failed"
  log "health OK"
}

api() {
  # api METHOD PATH [curl body args...]
  local method="$1"
  local path="$2"
  shift 2
  local base="${BASE:-http://127.0.0.1:${BARKVISOR_PORT}}"
  local args=(-sS -X "$method" "${base}${path}" -H "Content-Type: application/json")
  if [[ -n "${TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

api_code() {
  local method="$1"
  local path="$2"
  shift 2
  local base="${BASE:-http://127.0.0.1:${BARKVISOR_PORT}}"
  local body_file="${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}"
  local args=(-sS -o "$body_file" -w "%{http_code}" -X "$method" "${base}${path}" -H "Content-Type: application/json")
  if [[ -n "${TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

# Complete setup wizard or login. Sets TOKEN.
# Uses BARKVISOR_ADMIN_USER / BARKVISOR_ADMIN_PASSWORD.
setup_or_login() {
  local admin_user="${BARKVISOR_ADMIN_USER:-admin}"
  local admin_password="${BARKVISOR_ADMIN_PASSWORD:-barkvisor-smoke-pass}"
  local status_json complete code complete_json login_json

  STATUS_JSON="$(api GET /api/setup/status || true)"
  complete="$(echo "$STATUS_JSON" | jq -r '.complete // false' 2>/dev/null || echo false)"

  if [[ "$complete" != "true" ]]; then
    log "setup incomplete — creating admin + skipping bridge"
    code="$(api_code POST /api/setup/admin -d "$(jq -n --arg u "$admin_user" --arg p "$admin_password" '{username:$u,password:$p}')")"
    if [[ "$code" != "200" && "$code" != "409" ]]; then
      fail "POST /api/setup/admin returned HTTP $code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" 2>/dev/null || true)"
    fi

    code="$(api_code POST /api/setup/bridge/skip -d '{}')"
    [[ "$code" == "200" ]] || fail "POST /api/setup/bridge/skip returned HTTP $code"

    local lib_json lib_dir
    lib_json="$(api GET /api/setup/library)"
    lib_dir="$(echo "$lib_json" | jq -r '.imageDirectory // empty')"
    [[ -n "$lib_dir" && "$lib_dir" != "null" ]] || fail "GET /api/setup/library missing imageDirectory: $lib_json"
    code="$(api_code PUT /api/setup/library -d "$(jq -n --arg d "$lib_dir" '{imageDirectory:$d}')")"
    [[ "$code" == "200" ]] || fail "PUT /api/setup/library returned HTTP $code"

    complete_json="$(api POST /api/setup/complete -d '{}')"
    TOKEN="$(echo "$complete_json" | jq -r '.token // empty')"
    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
      fail "setup complete did not return token: $complete_json"
    fi
    log "setup complete (token from /api/setup/complete)"
  else
    log "setup already complete — logging in"
  fi

  if [[ -z "${TOKEN:-}" ]]; then
    login_json="$(api POST /api/auth/login -d "$(jq -n --arg u "$admin_user" --arg p "$admin_password" '{username:$u,password:$p}')")"
    TOKEN="$(echo "$login_json" | jq -r '.token // empty')"
    [[ -n "$TOKEN" && "$TOKEN" != "null" ]] || fail "login failed: $login_json"
    log "login OK"
  fi
  export TOKEN
}

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
  # Image download API currently accepts arch "arm64" primarily on Apple Silicon hosts.
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    *) echo "arm64" ;;
  esac
}
