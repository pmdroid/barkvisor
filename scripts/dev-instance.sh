#!/usr/bin/env bash
# Dev/demo instance harness: throwaway BarkVisor daemons for agents and humans.
#
# Usage:
#   scripts/dev-instance.sh start [--name TAG] [--data-dir DIR] [--seed]
#                                 [--keep] [--port N] [--admin-user U]
#                                 [--admin-pass P] [--skip-build]
#   scripts/dev-instance.sh stop [--name TAG | --data-dir DIR | --all] [--keep]
#   scripts/dev-instance.sh list
#   scripts/dev-instance.sh token [--name TAG]
#   scripts/dev-instance.sh pair <home-name> <joiner-name>
#   scripts/dev-instance.sh clean
#   scripts/dev-instance.sh self-test
#   scripts/dev-instance.sh help
#
# start prints one JSON line: {name,url,port,agentPort,pid,dataDir,logFile,
# adminUser,adminPass,seeded,provisioned}. The daemon runs detached; state
# lives in a fresh BARKVISOR_DATA_DIR (temp dir unless --data-dir). --seed
# fills networks, disks, API key, and SSH key through the real API so pages
# have content. --no-provision leaves setup incomplete so the setup wizard
# can be driven; pair then walks a joiner through /api/pairing/join,
# completes its setup, restarts it, and asserts the Home sees it reachable.
# stop removes the registry entry and auto temp data dirs unless --keep;
# custom --data-dir paths are never deleted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/linux-smoke-common.sh"
log() { echo "[dev-instance] $*" >&2; }

REGISTRY_DIR="${BARKVISOR_INSTANCE_DIR:-${TMPDIR:-/tmp}/barkvisor-dev-instances}"
DEFAULT_NAME="default"
SELF_TEST_NAME_PREFIX="selftest"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

die_usage() {
  echo "dev-instance: $*" >&2
  echo "run 'scripts/dev-instance.sh help' for usage" >&2
  exit 64
}

auto_tmp_prefix() {
  local tmp="${TMPDIR:-/tmp}"
  echo "${tmp%/}/barkvisor-dev-"
}

is_auto_data_dir() {
  case "$1" in
    "$(auto_tmp_prefix)"*) return 0 ;;
    *) return 1 ;;
  esac
}

meta_file() { echo "$REGISTRY_DIR/$1/meta.json"; }
token_file() { echo "$REGISTRY_DIR/$1/token"; }

registry_names() {
  [[ -d "$REGISTRY_DIR" ]] || return 0
  for d in "$REGISTRY_DIR"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
}

read_meta_field() {
  local meta
  meta="$(meta_file "$2")"
  [[ -f "$meta" ]] || return 0
  jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$meta" 2>/dev/null || true
}

entry_pid() { read_meta_field pid "$1"; }
entry_alive() {
  local pid
  pid="$(entry_pid "$1")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

resolve_name_by_data_dir() {
  local want="$1" name
  for name in $(registry_names); do
    if [[ "$(read_meta_field dataDir "$name")" == "$want" ]]; then
      echo "$name"
      return 0
    fi
  done
  return 1
}

kill_entry_process() {
  local pid="$1"
  kill "$pid" 2>/dev/null || return 0
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null || true
}

remove_entry() {
  local name="$1" keep_data="$2" data_dir
  data_dir="$(read_meta_field dataDir "$name")"
  rm -f "$(token_file "$name")"
  rm -rf "$REGISTRY_DIR/$name"
  if [[ "$keep_data" != "1" && -n "$data_dir" ]] && is_auto_data_dir "$data_dir"; then
    rm -rf "$data_dir"
  fi
}

stop_one() {
  local name="$1" keep_data="$2" meta pid
  meta="$(meta_file "$name")"
  [[ -f "$meta" ]] || die_usage "no instance named '$name'"
  pid="$(entry_pid "$name")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill_entry_process "$pid"
    log "stopped '$name' (pid $pid)"
  else
    log "instance '$name' was not running; cleaning registry entry"
  fi
  remove_entry "$name" "$keep_data"
}

seed_demo_data() {
  local code warnings=0
  local ssh_pub="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHXv0YbPjW9kOQK8tE1gZqLmNvXyCdRfS2uJhAw4T demo@barkvisor.local"

  code="$(api_code POST /api/networks -d '{"name":"lab-isolated","mode":"isolated"}')"
  if [[ "$code" != "200" && "$code" != "201" && "$code" != "409" ]]; then
    log "WARN seed network lab-isolated -> HTTP $code"; warnings=$((warnings+1))
  fi
  code="$(api_code POST /api/networks -d '{"name":"lab-nat","mode":"nat"}')"
  if [[ "$code" != "200" && "$code" != "201" && "$code" != "409" ]]; then
    log "WARN seed network lab-nat -> HTTP $code"; warnings=$((warnings+1))
  fi
  code="$(api_code POST /api/disks -d '{"name":"demo-data","sizeGB":10,"format":"qcow2"}')"
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    log "WARN seed disk demo-data -> HTTP $code"; warnings=$((warnings+1))
  fi
  code="$(api_code POST /api/disks -d '{"name":"demo-scratch","sizeGB":25,"format":"qcow2"}')"
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    log "WARN seed disk demo-scratch -> HTTP $code"; warnings=$((warnings+1))
  fi
  code="$(api_code POST /api/auth/keys -d '{"name":"demo-ci","expiresIn":"never","kind":"full"}')"
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    log "WARN seed API key -> HTTP $code"; warnings=$((warnings+1))
  fi
  code="$(api_code POST /api/ssh-keys -d "$(jq -n --arg k "$ssh_pub" '{name:"demo-key",publicKey:$k}')")"
  if [[ "$code" != "200" && "$code" != "201" && "$code" != "409" ]]; then
    log "WARN seed SSH key -> HTTP $code"; warnings=$((warnings+1))
  fi
  [[ "$warnings" -eq 0 ]] || log "seed finished with $warnings warning(s)"
}

write_entry_files() {
  local name="$1" token="$2" admin_user="$3" admin_pass="$4" seeded="$5" provisioned="$6"
  mkdir -p "$REGISTRY_DIR/$name"
  jq -n \
    --arg name "$name" \
    --arg url "$BASE" \
    --argjson port "$BARKVISOR_PORT" \
    --argjson agentPort "${BARKVISOR_AGENT_PORT}" \
    --argjson pid "$SERVER_PID" \
    --arg dataDir "$BARKVISOR_DATA_DIR" \
    --arg logFile "$LOG_FILE" \
    --arg adminUser "$admin_user" \
    --arg adminPass "$admin_pass" \
    --argjson seeded "$seeded" \
    --argjson provisioned "$provisioned" \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name,url:$url,port:$port,agentPort:$agentPort,pid:$pid,
      dataDir:$dataDir,logFile:$logFile,adminUser:$adminUser,
      adminPass:$adminPass,seeded:$seeded,provisioned:$provisioned,
      createdAt:$createdAt}' > "$(meta_file "$name")"
  printf '%s\n' "$token" > "$(token_file "$name")"
  chmod 600 "$(meta_file "$name")" "$(token_file "$name")"
}

start_instance() {
  local name="$1" data_dir_arg="$2" want_seed="$3" port_arg="$4" want_provision="${5:-1}"
  local admin_user="${BARKVISOR_ADMIN_USER:-admin}"
  local admin_pass="${BARKVISOR_ADMIN_PASSWORD:-dev-instance-pass}"
  local bin data_dir port agent_port token

  if entry_alive "$name"; then
    die_usage "instance '$name' already running at $(read_meta_field url "$name")"
  fi

  bin="$(find_bin)" || { build_barkvisor; bin="$(find_bin)" || fail "build did not produce BarkVisorApp"; }

  if [[ -n "$data_dir_arg" ]]; then
    data_dir="$data_dir_arg"
    mkdir -p "$data_dir"
  else
    data_dir="$(mktemp -d "$(auto_tmp_prefix)${name}.XXXXXX")"
  fi
  port="${port_arg:-0}"
  agent_port=0

  export BARKVISOR_PORT="$port"
  export BARKVISOR_AGENT_PORT="$agent_port"
  export BARKVISOR_DATA_DIR="$data_dir"
  export BARKVISOR_ADMIN_USER="$admin_user"
  export BARKVISOR_ADMIN_PASSWORD="$admin_pass"
  LOG_FILE="${data_dir}/server.log"

  log "starting '$name' (ephemeral ports) data=${data_dir}"
  "$bin" >"$LOG_FILE" 2>&1 &
  SERVER_PID=$!
  if [[ "$port" == "0" ]]; then
    port="$(wait_bound_port "${data_dir}/http.port" 200)" || fail "server never wrote http.port"
    export BARKVISOR_PORT="$port"
  fi
  if [[ "$agent_port" == "0" ]]; then
    if agent_port="$(wait_bound_port "${data_dir}/agent.port" 50)"; then
      export BARKVISOR_AGENT_PORT="$agent_port"
    else
      agent_port=0
      export BARKVISOR_AGENT_PORT=0
    fi
  fi
  BASE="http://127.0.0.1:${port}"
  log "starting '$name' on :${port} (agent :${agent_port}) data=${data_dir}"
  wait_health 120 1

  if [[ "$want_provision" == "1" ]]; then
    setup_or_login
    TOKEN="$(api POST /api/auth/login -d "$(jq -n --arg u "$admin_user" --arg p "$admin_pass" '{username:$u,password:$p}')" | jq -r '.token')"
    [[ -n "$TOKEN" && "$TOKEN" != "null" ]] || fail "login after setup returned no token"
  else
    local complete
    complete="$(api GET /api/setup/status | jq -r '.complete // false')"
    [[ "$complete" == "false" ]] || fail "--no-provision requested but setup is already complete"
    log "leaving '$name' unprovisioned for setup driving"
    TOKEN=""
  fi

  if [[ "$want_seed" == "1" ]]; then
    [[ -n "$TOKEN" ]] || fail "--seed needs a provisioned instance"
    log "seeding demo data"
    seed_demo_data
  fi

  write_entry_files "$name" "$TOKEN" "$admin_user" "$admin_pass" "$([[ $want_seed == 1 ]] && echo true || echo false)" "$([[ $want_provision == 1 ]] && echo true || echo false)"
  cat "$(meta_file "$name")"
}

cmd_start() {
  local name="$DEFAULT_NAME" data_dir="" seed=0 keep=0 port="" provision=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --data-dir) data_dir="$2"; shift 2 ;;
      --seed) seed=1; shift ;;
      --keep) keep=1; shift ;;
      --port) port="$2"; shift 2 ;;
      --no-provision) provision=0; shift ;;
      --admin-user) BARKVISOR_ADMIN_USER="$2"; shift 2 ;;
      --admin-pass) BARKVISOR_ADMIN_PASSWORD="$2"; shift 2 ;;
      --skip-build) SKIP_BUILD=1; shift ;;
      *) die_usage "unknown start flag: $1" ;;
    esac
  done
  [[ "$keep" == "1" && -z "$data_dir" ]] && log "--keep ignored (temp dirs are cleaned by 'stop'; custom --data-dir paths are never deleted)"
  start_instance "$name" "$data_dir" "$seed" "$port" "$provision"
}

cmd_stop() {
  local name="" data_dir="" all=0 keep=0 candidate
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --data-dir) data_dir="$2"; shift 2 ;;
      --all) all=1; shift ;;
      --keep) keep=1; shift ;;
      *) die_usage "unknown stop flag: $1" ;;
    esac
  done
  if [[ "$all" == "1" ]]; then
    for candidate in $(registry_names); do
      stop_one "$candidate" "$keep"
    done
    return 0
  fi
  if [[ -n "$data_dir" ]]; then
    name="$(resolve_name_by_data_dir "$data_dir")" || die_usage "no instance registered for data dir $data_dir"
  fi
  [[ -n "$name" ]] || name="$DEFAULT_NAME"
  stop_one "$name" "$keep"
}

cmd_list() {
  local name running items="[]" row
  for name in $(registry_names); do
    running=0
    entry_alive "$name" && running=1
    row="$(jq -nc --slurpfile m "$(meta_file "$name")" --argjson r "$running" '$m[0] + {running:$r}')"
    items="$(jq -nc --argjson a "$items" --argjson row "$row" '$a + [$row]')"
  done
  jq . <<<"$items"
}

cmd_token() {
  local name="$DEFAULT_NAME"
  if [[ "${1:-}" == "--name" ]]; then
    [[ -n "${2:-}" ]] || die_usage "--name needs a value"
    name="$2"
  elif [[ -n "${1:-}" ]]; then
    name="$1"
  fi
  local user pass token url
  [[ -f "$(meta_file "$name")" ]] || die_usage "no instance named '$name'"
  url="$(read_meta_field url "$name")"
  user="$(read_meta_field adminUser "$name")"
  pass="$(read_meta_field adminPass "$name")"
  BASE="$url"
  token="$(api POST /api/auth/login -d "$(jq -n --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" | jq -r '.token')"
  [[ -n "$token" && "$token" != "null" ]] || fail "could not log in to $url"
  printf '%s\n' "$token" > "$(token_file "$name")"
  chmod 600 "$(token_file "$name")"
  jq -n --arg url "$url" --arg token "$token" '{url:$url,token:$token}'
}

login_token() {
  local url="$1" user="$2" pass="$3"
  BASE="$url"
  api POST /api/auth/login -d "$(jq -n --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" | jq -r '.token // empty'
}

restart_entry() {
  local name="$1" token="$2"
  local bin pid port agent data_dir
  bin="$(find_bin)" || fail "binary not found for restart"
  port="$(read_meta_field port "$name")"
  agent="$(read_meta_field agentPort "$name")"
  data_dir="$(read_meta_field dataDir "$name")"
  pid="$(entry_pid "$name")"
  kill_entry_process "$pid"

  export BARKVISOR_PORT="$port"
  export BARKVISOR_AGENT_PORT="$agent"
  export BARKVISOR_DATA_DIR="$data_dir"
  BASE="http://127.0.0.1:${port}"
  LOG_FILE="${data_dir}/server.log"
  log "restarting '$name' on :${port}"
  "$bin" >>"$LOG_FILE" 2>&1 &
  SERVER_PID=$!
  wait_health 120 1
  write_entry_files "$name" "$token" \
    "$(read_meta_field adminUser "$name")" "$(read_meta_field adminPass "$name")" \
    "$(read_meta_field seeded "$name")" true
}

cmd_pair() {
  [[ $# -eq 2 ]] || die_usage "usage: dev-instance.sh pair <home-name> <joiner-name>"
  local home_name="$1" joiner_name="$2"
  local home_url home_user home_pass home_token joiner_url joiner_token
  [[ -f "$(meta_file "$home_name")" ]] || die_usage "no instance named '$home_name'"
  [[ -f "$(meta_file "$joiner_name")" ]] || die_usage "no instance named '$joiner_name'"
  entry_alive "$home_name" || die_usage "instance '$home_name' is not running"
  entry_alive "$joiner_name" || die_usage "instance '$joiner_name' is not running"

  [[ "$(read_meta_field provisioned "$joiner_name")" == "false" ]] \
    || die_usage "'$joiner_name' is already provisioned — first-time pairing needs a joiner started with --no-provision"

  home_url="$(read_meta_field url "$home_name")"
  home_user="$(read_meta_field adminUser "$home_name")"
  home_pass="$(read_meta_field adminPass "$home_name")"
  home_token="$(login_token "$home_url" "$home_user" "$home_pass")"
  [[ -n "$home_token" ]] || fail "could not log in to home $home_url"

  export BARKVISOR_ADMIN_USER="$(read_meta_field adminUser "$joiner_name")"
  export BARKVISOR_ADMIN_PASSWORD="$(read_meta_field adminPass "$joiner_name")"

  log "issuing pairing offer on '$home_name'"
  BASE="$home_url"
  TOKEN="$home_token"
  local issue join_code qr
  api_code POST /api/pairing/codes -d '{}' >/dev/null
  qr="$(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}" | jq -r '.qrPayload // empty')"
  [[ -n "$qr" && "$qr" != "null" ]] || fail "pairing issue returned no qrPayload"

  joiner_url="$(read_meta_field url "$joiner_name")"
  log "'$joiner_name' joins via POST /api/pairing/join"
  BASE="$joiner_url"
  TOKEN=""
  join_code="$(api_code POST /api/pairing/join -d "$(jq -n --arg q "$qr" '{qrPayload:$q}')")"
  [[ "$join_code" == "200" ]] || fail "pairing/join returned HTTP $join_code: $(cat "${SMOKE_BODY_FILE:-/tmp/barkvisor-smoke-body.$$}")"

  log "completing setup on '$joiner_name'"
  setup_or_login
  joiner_token="$TOKEN"
  [[ -n "$joiner_token" && "$joiner_token" != "null" ]] || fail "joiner setup/complete returned no token"

  restart_entry "$joiner_name" "$joiner_token"

  log "waiting for '$home_name' to see '$joiner_name' reachable"
  BASE="$home_url"
  TOKEN="$home_token"
  local health member_id reach i
  member_id=""; reach=""
  for i in $(seq 1 40); do
    health="$(api GET /api/home/devices/health || true)"
    member_id="$(echo "$health" | jq -r '[.devices[]? | select(.role != "self")] | .[0].hostId // empty')"
    reach="$(echo "$health" | jq -r --arg id "$member_id" \
      '[.devices[]? | select(.hostId == $id)] | .[0].reachability // empty')"
    [[ -n "$member_id" && "$reach" == "ok" ]] && break
    sleep 0.5
  done
  [[ "$reach" == "ok" ]] || fail "'$home_name' does not see '$joiner_name' reachable (reachability=${reach:-unknown})"

  jq -n --arg home "$home_name" --arg joiner "$joiner_name" \
    --arg homeUrl "$home_url" --arg joinerUrl "$joiner_url" \
    --arg memberHostId "$member_id" --arg reachability "$reach" \
    '{home:$home,homeUrl:$homeUrl,joiner:$joiner,joinerUrl:$joinerUrl,
      memberHostId:$memberHostId,reachability:$reachability,paired:true}'
}

cmd_self_test() {
  local name="${SELF_TEST_NAME_PREFIX}-$$" meta_json url token code count
  trap 'stop_one "'"$name"'" 0 2>/dev/null || true' EXIT
  meta_json="$(SKIP_BUILD="${SKIP_BUILD:-0}" start_instance "$name" "" 1 "")"
  url="$(jq -r .url <<<"$meta_json")"
  token="$(cat "$(token_file "$name")")"
  BASE="$url"

  count="$(curl -sf -H "Authorization: Bearer $token" "$url/api/networks" | jq 'length')"
  [[ "$count" -ge 3 ]] || fail "expected >=3 networks after seed, got $count"
  count="$(curl -sf -H "Authorization: Bearer $token" "$url/api/disks" | jq 'length')"
  [[ "$count" -ge 2 ]] || fail "expected >=2 disks after seed, got $count"
  count="$(curl -sf -H "Authorization: Bearer $token" "$url/api/auth/keys" | jq 'length')"
  [[ "$count" -ge 1 ]] || fail "expected >=1 API key after seed, got $count"
  count="$(curl -sf -H "Authorization: Bearer $token" "$url/api/ssh-keys" | jq 'length')"
  [[ "$count" -ge 1 ]] || fail "expected >=1 SSH key after seed, got $count"
  code="$(api_code GET /api/setup/status)"
  [[ "$code" == "200" ]] || fail "setup status -> HTTP $code"

  log "SELF-TEST PASS ($url)"
}

main() {
  [[ $# -gt 0 ]] || usage
  local cmd="$1"
  shift
  mkdir -p "$REGISTRY_DIR"
  case "$cmd" in
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    list) cmd_list ;;
    token) cmd_token "$@" ;;
    pair) shift 0; cmd_pair "$@" ;;
    clean) cmd_stop --all ;;
    self-test) cmd_self_test ;;
    help|--help|-h) usage ;;
    *) die_usage "unknown command: $cmd" ;;
  esac
}

main "$@"
