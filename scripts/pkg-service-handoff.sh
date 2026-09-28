#!/bin/bash
set -euo pipefail

daemon_unit=barkvisor-daemon
server_unit=barkvisor-server
daemon_label=dev.barkvisor.daemon
server_label=dev.barkvisor.server
combined_label=dev.barkvisor
account=barkvisor

root="${BARKVISOR_HOST_ROOT:-}"

host_path() {
  if [ -n "$root" ]; then
    printf '%s%s' "$root" "$1"
  else
    printf '%s' "$1"
  fi
}

data_dir="$(host_path /var/lib/barkvisor)"
run_dir="$(host_path /var/run/barkvisor)"
log_dir="$(host_path /var/log/barkvisor)"
schema_file="$data_dir/schema-version"
handoff_log="$data_dir/service-handoff.log"
outcome_file="$data_dir/update-outcome.json"

write_outcome() {
  local status="$1"
  local detail="$2"
  mkdir -p "$data_dir"
  detail=$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"status":"%s","detail":"%s"}\n' "$status" "$detail" > "$outcome_file"
  chmod 0644 "$outcome_file"
}

fail_handoff() {
  write_outcome failed "$1"
  echo "$1" >&2
  exit 1
}

reject_downgrade() {
  if [ -f "$schema_file" ]; then
    local on_disk
    on_disk=$(tr -cd '0-9' < "$schema_file" || true)
    if [ -n "$on_disk" ] && [ "$on_disk" -gt 1 ]; then
      echo "unsupported downgrade: schema $on_disk" >&2
      exit 1
    fi
  fi
}

ensure_account() {
  if [ -n "$root" ]; then
    mkdir -p "$root/Users" "$root/Groups"
    printf '%s\n' 'UserShell=/usr/bin/false' > "$root/Users/$account"
    printf '%s\n' "$account" > "$root/Groups/$account"
    return
  fi
  if id "$account" >/dev/null 2>&1; then
    return
  fi
  local next_id
  next_id=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
  next_id=$((next_id + 1))
  dscl . -create "/Groups/$account"
  dscl . -create "/Groups/$account" PrimaryGroupID "$next_id"
  dscl . -create "/Users/$account"
  dscl . -create "/Users/$account" UserShell /usr/bin/false
  dscl . -create "/Users/$account" UniqueID "$next_id"
  dscl . -create "/Users/$account" PrimaryGroupID "$next_id"
  dscl . -create "/Groups/$account" GroupMembership "$account"
}

prepare_tree() {
  mkdir -p \
    "$data_dir/backups" \
    "$data_dir/firmware" \
    "$data_dir/images" \
    "$data_dir/disks" \
    "$data_dir/cloud-init" \
    "$data_dir/efivars" \
    "$data_dir/monitor" \
    "$data_dir/tus-uploads" \
    "$data_dir/pids" \
    "$data_dir/console" \
    "$log_dir" \
    "$run_dir/management"
  chmod 0755 "$data_dir" "$log_dir"
  chmod 0750 "$run_dir" "$run_dir/management"
  if [ ! -f "$schema_file" ]; then
    printf '1\n' > "$schema_file"
  fi
  chmod 0644 "$schema_file"
  if [ -z "$root" ]; then
    chgrp "$account" "$run_dir" "$run_dir/management" || true
    touch "$log_dir/server-public.log" "$log_dir/server-public.err"
    chgrp "$account" "$log_dir/server-public.log" "$log_dir/server-public.err" || true
    chmod 0640 "$log_dir/server-public.log" "$log_dir/server-public.err" || true
  fi
}

lock_private_files() {
  local rel
  for rel in \
    authority/management.key \
    home-ca/ca.key \
    jwt-secret \
    api-key-hmac-secret \
    agent/membership.json \
    db.sqlite \
    db.sqlite-wal \
    db.sqlite-shm
  do
    if [ -f "$data_dir/$rel" ]; then
      chmod 0600 "$data_dir/$rel"
      if [ -z "$root" ]; then
        chown root:wheel "$data_dir/$rel" || true
      fi
    fi
  done
  for rel in agent/device.crt agent/device.key agent/ca.crt home-ca/ca.crt authority/management.pub; do
    if [ -f "$data_dir/$rel" ]; then
      chmod 0640 "$data_dir/$rel"
      if [ -z "$root" ]; then
        chgrp "$account" "$data_dir/$rel" || true
      fi
    fi
  done
}

note() {
  printf '%s\n' "$1" >> "$handoff_log"
}

bootout_label() {
  local label="$1"
  if [ -n "$root" ]; then
    return
  fi
  launchctl bootout "system/$label" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    if ! launchctl print "system/$label" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  if launchctl print "system/$label" >/dev/null 2>&1; then
    fail_handoff "$label is still loaded"
  fi
}

retire_combined() {
  bootout_label "$combined_label"
  rm -f "$(host_path "/Library/LaunchDaemons/${combined_label}.plist")"
  note "bootout dev.barkvisor"
}

bootstrap_named() {
  local label="$1"
  local name="$2"
  local plist
  plist="$(host_path "/Library/LaunchDaemons/${label}.plist")"
  if [ ! -f "$plist" ]; then
    fail_handoff "$name plist missing"
  fi
  if [ -z "$root" ]; then
    bootout_label "$label"
    launchctl bootstrap system "$plist"
  fi
  note "bootstrap $name"
}

wait_running() {
  local label="$1"
  local name="$2"
  local i text
  for i in $(seq 1 30); do
    text=$(launchctl print "system/$label" 2>/dev/null || true)
    if printf '%s' "$text" | grep -q 'state = running' \
      && printf '%s' "$text" | grep -q '/usr/local/bin/barkvisor'; then
      return 0
    fi
    sleep 1
  done
  fail_handoff "$name did not start"
}

verify_live() {
  wait_running "$daemon_label" BarkDaemon
  wait_running "$server_label" BarkServer
  local daemon_text server_text daemon_uid server_uid body i
  daemon_text=$(launchctl print "system/$daemon_label")
  server_text=$(launchctl print "system/$server_label")
  daemon_uid=$(printf '%s\n' "$daemon_text" | awk '/uid = / { print $3; exit }')
  server_uid=$(id -u "$account")
  local got_server
  got_server=$(printf '%s\n' "$server_text" | awk '/uid = / { print $3; exit }')
  if [ "$daemon_uid" != "0" ]; then
    fail_handoff "BarkDaemon uid is ${daemon_uid:-unknown}"
  fi
  if [ "$got_server" != "$server_uid" ]; then
    fail_handoff "BarkServer uid is ${got_server:-unknown}"
  fi
  if ! printf '%s' "$daemon_text" | grep -q 'daemon'; then
    fail_handoff "BarkDaemon is not running the daemon subcommand"
  fi
  if ! printf '%s' "$server_text" | grep -q 'server'; then
    fail_handoff "BarkServer is not running the server subcommand"
  fi
  if launchctl print "system/$combined_label" >/dev/null 2>&1; then
    fail_handoff "combined dev.barkvisor is still loaded"
  fi
  body=""
  for i in $(seq 1 30); do
    body=$(curl -fsS --max-time 2 "http://127.0.0.1:${BARKVISOR_PORT:-7777}/api/health" || true)
    if printf '%s' "$body" | grep -q '"status":"ok"' \
      && printf '%s' "$body" | grep -q '"protocol":"1"' \
      && printf '%s' "$body" | grep -q 'BarkDaemon' \
      && printf '%s' "$body" | grep -q 'BarkServer'; then
      return 0
    fi
    sleep 1
  done
  fail_handoff "public health or local protocol was not ready: ${body:-no response}"
}

verify() {
  if [ "${BARKVISOR_PKG_HEALTH:-}" = "fail" ]; then
    fail_handoff "public health failed"
  fi
  if [ -n "$root" ]; then
    if [ -f "$(host_path "/Library/LaunchDaemons/${combined_label}.plist")" ]; then
      fail_handoff "combined job still installed"
    fi
    return
  fi
  verify_live
}

if [ -z "$root" ] && [ "$(id -u)" -ne 0 ]; then
  echo "BarkVisor service handoff must run as root." >&2
  exit 1
fi

reject_downgrade
ensure_account
prepare_tree
lock_private_files
: > "$handoff_log"
retire_combined
bootstrap_named "$daemon_label" BarkDaemon
bootstrap_named "$server_label" BarkServer
verify
write_outcome succeeded "BarkDaemon and BarkServer ready"
printf '%s\n' "$daemon_unit $server_unit"
