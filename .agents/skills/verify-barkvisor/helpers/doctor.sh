#!/usr/bin/env bash
# Read-only "is this instance worth driving?" check.
# Usage: helpers/doctor.sh URL [USER] [PASS]
set -euo pipefail

URL="${1:?usage: doctor.sh URL [USER] [PASS]}"
USER="${2:-admin}"
PASS="${3:-dev-instance-pass}"

port="${URL##*:}"
if [[ "$port" == "7777" && "${BARKVISOR_ALLOW_7777:-0}" != "1" ]]; then
  echo "REFUSING $URL — port 7777 is likely the user's real daemon." >&2
  echo "Start a throwaway via helpers/up.sh, or set BARKVISOR_ALLOW_7777=1 to override." >&2
  exit 1
fi

fail() { echo "doctor FAIL: $*" >&2; exit 1; }

curl -sf "$URL/api/health" >/dev/null || fail "no /api/health at $URL"
echo "ok   /api/health answers"

complete="$(curl -sf "$URL/api/setup/status" | jq -r '.complete // false')"
[[ "$complete" == "true" ]] || fail "setup incomplete at $URL"
echo "ok   setup complete"

token="$(curl -sf -X POST "$URL/api/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$USER" --arg p "$PASS" '{username:$u,password:$p}')" | jq -r '.token // empty')"
[[ -n "$token" && "$token" != "null" ]] || fail "login as $USER failed"
echo "ok   login returns JWT"

curl -sf -H "Authorization: Bearer $token" "$URL/api/system/about" \
  | jq -c '{version,platform,hostArch,accelerator}'
echo "PASS $URL"
