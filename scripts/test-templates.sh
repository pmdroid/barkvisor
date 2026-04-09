#!/usr/bin/env bash
#
# test-templates.sh — Automated template testing for BarkVisor
#
# Deploys templates via the API, waits for the VM to boot, validates via SSH,
# and checks that HTTP ports exposed by the template become reachable.
#
# Usage:
#   ./scripts/test-templates.sh                    # test all templates
#   ./scripts/test-templates.sh <template-slug>    # test a specific template
#   ./scripts/test-templates.sh --list             # list available templates
#
# Environment variables:
#   BARKVISOR_URL      Base URL (default: http://127.0.0.1:7777)
#   BARKVISOR_USER     Login username (default: admin)
#   BARKVISOR_PASS     Login password (required)
#   TEST_SSH_KEY       Path to SSH private key for validation (optional)
#   TEST_SSH_PUBKEY    Path to SSH public key to inject (optional)
#   TEST_PASSWORD      Password to set on test VMs (default: TestPassword123!)
#   BOOT_TIMEOUT       Seconds to wait for VM to boot (default: 60)
#   HTTP_TIMEOUT       Seconds to wait for template HTTP ports (default: 600)
#   KEEP_VMS           Set to 1 to skip cleanup (for debugging)
#   SSH_PORT_START     Starting host port for SSH forwards (default: 22200)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────

BASE_URL="${BARKVISOR_URL:-http://127.0.0.1:7777}"
USERNAME="${BARKVISOR_USER:-admin}"
PASSWORD="${BARKVISOR_PASS:-}"
TEST_PASSWORD="${TEST_PASSWORD:-TestPassword123!}"
SSH_KEY="${TEST_SSH_KEY:-}"
SSH_PUBKEY="${TEST_SSH_PUBKEY:-}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-600}"
KEEP_VMS="${KEEP_VMS:-0}"
SSH_PORT_START="${SSH_PORT_START:-22200}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Track created VMs for cleanup
CREATED_VMS=()
RESULTS=()

# ── Helpers ────────────────────────────────────────────────────

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; }
die()  { fail "$@"; exit 1; }

api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "${BASE_URL}${path}" "$@"
}

api_raw() {
    local method="$1" path="$2"
    shift 2
    curl -s -w "\n%{http_code}" -X "$method" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "${BASE_URL}${path}" "$@"
}

cleanup() {
    if [[ "$KEEP_VMS" == "1" ]]; then
        if [[ ${#CREATED_VMS[@]} -gt 0 ]]; then
            warn "KEEP_VMS=1 — skipping cleanup. Created VMs:"
            for vm_id in "${CREATED_VMS[@]}"; do
                echo "  - $vm_id"
            done
        fi
        return
    fi

    if [[ ${#CREATED_VMS[@]} -gt 0 ]]; then
        log "Cleaning up ${#CREATED_VMS[@]} test VM(s)..."
        for vm_id in "${CREATED_VMS[@]}"; do
            api POST "/api/vms/${vm_id}/stop" -d '{"method":"force"}' 2>/dev/null || true
            sleep 2
            api DELETE "/api/vms/${vm_id}?keepDisk=false" 2>/dev/null || true
        done
        ok "Cleanup complete"
    fi
}

trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null   || die "jq is required"

if [[ -z "$PASSWORD" ]]; then
    die "BARKVISOR_PASS is required. Export it before running this script."
fi

# Auto-detect SSH key if not specified
if [[ -z "$SSH_KEY" ]]; then
    for key in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$key" ]]; then
            SSH_KEY="$key"
            SSH_PUBKEY="${key}.pub"
            break
        fi
    done
fi

SSH_PUBKEY_CONTENT=""
if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then
    SSH_PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
fi

# ── Authentication ─────────────────────────────────────────────

log "Authenticating to ${BASE_URL}..."
LOGIN_RESP=$(curl -sf -X POST "${BASE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}")

TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token')
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || die "Authentication failed"
ok "Authenticated as ${USERNAME}"

# ── Fetch templates ────────────────────────────────────────────

log "Fetching templates..."
TEMPLATES_JSON=$(api GET "/api/templates")
TEMPLATE_COUNT=$(echo "$TEMPLATES_JSON" | jq 'length')
ok "Found ${TEMPLATE_COUNT} template(s)"

# ── List mode ──────────────────────────────────────────────────

if [[ "${1:-}" == "--list" ]]; then
    echo ""
    echo -e "${BOLD}Available templates:${NC}"
    echo "$TEMPLATES_JSON" | jq -r '.[] | "  \(.slug)\t\(.name)\t[\(.category)]"' | column -t -s $'\t'
    exit 0
fi

# ── Filter templates ───────────────────────────────────────────

FILTER_SLUG="${1:-}"
if [[ -n "$FILTER_SLUG" ]]; then
    FILTERED=$(echo "$TEMPLATES_JSON" | jq --arg slug "$FILTER_SLUG" '[.[] | select(.slug == $slug)]')
    if [[ $(echo "$FILTERED" | jq 'length') -eq 0 ]]; then
        FILTERED=$(echo "$TEMPLATES_JSON" | jq --arg slug "$FILTER_SLUG" '[.[] | select(.slug | contains($slug))]')
    fi
    if [[ $(echo "$FILTERED" | jq 'length') -eq 0 ]]; then
        die "No template matching '${FILTER_SLUG}'. Use --list to see available templates."
    fi
    TEMPLATES_JSON="$FILTERED"
    TEMPLATE_COUNT=$(echo "$TEMPLATES_JSON" | jq 'length')
    log "Testing ${TEMPLATE_COUNT} matching template(s)"
fi

# ── Test functions ─────────────────────────────────────────────

wait_for_image() {
    local image_id="$1"
    local timeout=600
    local elapsed=0

    log "  Waiting for image download (${image_id})..."
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(api GET "/api/images/${image_id}" | jq -r '.status')
        case "$status" in
            ready)
                ok "  Image ready"
                return 0
                ;;
            error)
                fail "  Image download failed"
                return 1
                ;;
            *)
                sleep 10
                elapsed=$((elapsed + 10))
                printf "."
                ;;
        esac
    done
    echo ""
    fail "  Image download timed out after ${timeout}s"
    return 1
}

wait_for_boot() {
    local vm_id="$1"
    local elapsed=0

    log "  Waiting for VM to boot..."
    while [[ $elapsed -lt $BOOT_TIMEOUT ]]; do
        local state
        state=$(api GET "/api/vms/${vm_id}" | jq -r '.state')
        if [[ "$state" == "running" ]]; then
            ok "  VM is running"
            return 0
        elif [[ "$state" == "error" ]]; then
            fail "  VM entered error state"
            return 1
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    fail "  VM did not reach running state within ${BOOT_TIMEOUT}s"
    return 1
}

validate_ssh() {
    local vm_id="$1" ssh_port="$2"
    local ssh_user="$3"

    if [[ -z "$SSH_KEY" ]]; then
        warn "  No SSH key available — skipping SSH validation"
        return 0
    fi

    log "  Validating via SSH (port ${ssh_port}, user ${ssh_user})..."

    # Wait for SSH to become available
    local elapsed=0
    local ssh_timeout=60
    while [[ $elapsed -lt $ssh_timeout ]]; do
        if ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$SSH_KEY" -p "$ssh_port" "${ssh_user}@127.0.0.1" "echo ok" 2>/dev/null; then
            ok "  SSH connection successful"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ $elapsed -ge $ssh_timeout ]]; then
        fail "  SSH not reachable after ${ssh_timeout}s"
        return 1
    fi

    local errors=0
    local ssh_cmd="ssh -q -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $ssh_port ${ssh_user}@127.0.0.1"

    # Check cloud-init status
    log "  Checking cloud-init status..."
    local ci_result
    ci_result=$($ssh_cmd "cloud-init status 2>/dev/null || echo 'not-available'" 2>/dev/null)
    if echo "$ci_result" | grep -q "done\|disabled"; then
        ok "  cloud-init status: done"
    elif echo "$ci_result" | grep -q "not-available"; then
        warn "  cloud-init CLI not available (may be normal for some images)"
    elif echo "$ci_result" | grep -q "error\|recoverable"; then
        fail "  cloud-init reported errors"
        $ssh_cmd "cloud-init status --long 2>/dev/null" 2>/dev/null || true
        errors=$((errors + 1))
    else
        warn "  cloud-init status: ${ci_result}"
    fi

    # Check user account
    log "  Checking user account..."
    if $ssh_cmd "id" 2>/dev/null | grep -q "$ssh_user"; then
        ok "  User '${ssh_user}' exists"
    else
        fail "  User '${ssh_user}' not found"
        errors=$((errors + 1))
    fi

    # Check hostname
    log "  Checking hostname..."
    local hostname
    hostname=$($ssh_cmd "hostname" 2>/dev/null)
    if [[ -n "$hostname" ]]; then
        ok "  Hostname: ${hostname}"
    else
        warn "  Could not retrieve hostname"
    fi

    # Check SSH authorized keys
    log "  Checking SSH authorized_keys..."
    local auth_keys
    auth_keys=$($ssh_cmd "cat ~/.ssh/authorized_keys 2>/dev/null | wc -l" 2>/dev/null)
    if [[ "$auth_keys" -gt 0 ]]; then
        ok "  SSH authorized_keys has ${auth_keys} key(s)"
    else
        warn "  No SSH authorized_keys found"
    fi

    # Check cloud-init logs for critical errors
    log "  Checking cloud-init logs for errors..."
    local ci_errors
    ci_errors=$($ssh_cmd "grep -c 'CRITICAL\|FATAL\|EXCEPTION' /var/log/cloud-init.log 2>/dev/null || echo 0" 2>/dev/null)
    if [[ "$ci_errors" -eq 0 ]]; then
        ok "  No critical errors in cloud-init log"
    else
        fail "  Found ${ci_errors} critical error(s) in cloud-init log"
        $ssh_cmd "grep 'CRITICAL\|FATAL\|EXCEPTION' /var/log/cloud-init.log 2>/dev/null | tail -5" 2>/dev/null || true
        errors=$((errors + 1))
    fi

    return $errors
}

wait_for_guest_ip() {
    local vm_id="$1"
    local timeout="${HTTP_TIMEOUT}"
    local elapsed=0

    log "  Waiting for guest agent IP (timeout: ${timeout}s)..." >&2
    while [[ $elapsed -lt $timeout ]]; do
        local resp ip
        resp=$(curl -s -H "Authorization: Bearer $TOKEN" "${BASE_URL}/api/vms/${vm_id}/guest-info" 2>/dev/null)
        ip=$(echo "$resp" | jq -r '.ipAddresses[0] // empty' 2>/dev/null)
        if [[ -n "$ip" && "$ip" != "null" ]]; then
            ok "  Guest IP: ${ip}" >&2
            echo "$ip"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log "  ... still waiting for guest agent (${elapsed}s elapsed)" >&2
        fi
    done

    fail "  Guest agent did not report an IP within ${timeout}s" >&2
    return 1
}

wait_for_http() {
    local host="$1"
    local ports_json="$2"
    local port_key="${3:-guestPort}"  # guestPort for bridged, hostPort for NAT
    # Only check TCP ports (HTTP/HTTPS services)
    local tcp_ports
    tcp_ports=$(echo "$ports_json" | jq '[.[] | select(.protocol == "tcp")]')
    local port_count
    port_count=$(echo "$tcp_ports" | jq 'length')

    if [[ "$port_count" -eq 0 ]]; then
        return 0
    fi

    local all_ok=true
    for ((p=0; p<port_count; p++)); do
        local port
        port=$(echo "$tcp_ports" | jq -r ".[$p].${port_key}")
        # Use httpPath from template if set, otherwise "/"
        local path
        path=$(echo "$tcp_ports" | jq -r ".[$p].httpPath // \"/\"")

        log "  Waiting for HTTP on ${host}:${port}${path} (timeout: ${HTTP_TIMEOUT}s)..."
        local elapsed=0
        local reachable=false
        while [[ $elapsed -lt $HTTP_TIMEOUT ]]; do
            if curl -sf -o /dev/null --max-time 5 "http://${host}:${port}${path}" 2>/dev/null || \
               curl -skf -o /dev/null --max-time 5 "https://${host}:${port}${path}" 2>/dev/null; then
                reachable=true
                break
            fi
            sleep 10
            elapsed=$((elapsed + 10))
            if [[ $((elapsed % 60)) -eq 0 ]]; then
                log "  ... still waiting for ${host}:${port}${path} (${elapsed}s elapsed)"
            fi
        done

        if $reachable; then
            ok "  ${host}:${port}${path} is reachable"
        else
            fail "  ${host}:${port}${path} not reachable after ${HTTP_TIMEOUT}s"
            all_ok=false
        fi
    done

    $all_ok
}

# ── Build input values for a template ──────────────────────────

build_inputs() {
    local template_json="$1"
    local inputs
    inputs=$(echo "$template_json" | jq -r '.inputs')

    local result="{}"
    local input_count
    input_count=$(echo "$inputs" | jq 'length')

    for ((i=0; i<input_count; i++)); do
        local input_id input_type input_default
        input_id=$(echo "$inputs" | jq -r ".[$i].id")
        input_type=$(echo "$inputs" | jq -r ".[$i].type // \"text\"")
        input_default=$(echo "$inputs" | jq -r ".[$i].default // \"\"")

        local value=""
        case "$input_id" in
            password)
                value="$TEST_PASSWORD"
                ;;
            ssh_keys)
                value="$SSH_PUBKEY_CONTENT"
                ;;
            hostname|host_name)
                value="test-vm-$$"
                ;;
            username|user)
                value="testuser"
                ;;
            extra_packages)
                value="curl htop"
                ;;
            *)
                if [[ -n "$input_default" && "$input_default" != "null" ]]; then
                    value="$input_default"
                elif [[ "$input_type" == "password" ]]; then
                    value="$TEST_PASSWORD"
                else
                    value="test-value"
                fi
                ;;
        esac

        result=$(echo "$result" | jq --arg key "$input_id" --arg val "$value" '. + {($key): $val}')
    done

    echo "$result"
}

# ── Guess SSH user from template ───────────────────────────────

guess_ssh_user() {
    local template_json="$1"
    local user_data
    user_data=$(echo "$template_json" | jq -r '.userDataTemplate')
    local slug
    slug=$(echo "$template_json" | jq -r '.slug')

    # Check if template defines a user
    if echo "$user_data" | grep -q "name:.*{{username}}"; then
        echo "testuser"
        return
    fi

    # Check for hardcoded usernames in the template
    local user
    user=$(echo "$user_data" | grep -oP '^\s+name:\s*\K\S+' | head -1)
    if [[ -n "$user" && "$user" != "{{username}}" ]]; then
        echo "$user"
        return
    fi

    # Guess from slug
    case "$slug" in
        *ubuntu*)  echo "ubuntu" ;;
        *debian*)  echo "debian" ;;
        *fedora*)  echo "fedora" ;;
        *centos*)  echo "centos" ;;
        *rocky*)   echo "rocky"  ;;
        *alma*)    echo "almalinux" ;;
        *arch*)    echo "arch"   ;;
        *alpine*)  echo "alpine" ;;
        *)         echo "root"   ;;
    esac
}

# ── Main test loop ─────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BarkVisor Template Test Suite${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

PASS=0
FAIL=0
SKIP=0
ssh_port=$SSH_PORT_START

for ((idx=0; idx<TEMPLATE_COUNT; idx++)); do
    TEMPLATE=$(echo "$TEMPLATES_JSON" | jq ".[$idx]")
    T_ID=$(echo "$TEMPLATE" | jq -r '.id')
    T_SLUG=$(echo "$TEMPLATE" | jq -r '.slug')
    T_NAME=$(echo "$TEMPLATE" | jq -r '.name')
    T_CATEGORY=$(echo "$TEMPLATE" | jq -r '.category')

    echo ""
    echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  [$((idx+1))/${TEMPLATE_COUNT}] ${T_NAME} (${T_SLUG})${NC}"
    echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"

    # Skip Windows templates (no SSH-based validation)
    if echo "$T_SLUG" | grep -qi "windows"; then
        warn "Skipping Windows template (SSH validation not supported)"
        SKIP=$((SKIP + 1))
        RESULTS+=("SKIP  ${T_SLUG} (Windows)")
        continue
    fi

    VM_NAME="test-${T_SLUG}-$(date +%s)"
    SSH_USER=$(guess_ssh_user "$TEMPLATE")
    INPUTS=$(build_inputs "$TEMPLATE")

    log "VM name: ${VM_NAME}"
    log "SSH user: ${SSH_USER}"
    log "SSH port forward: 127.0.0.1:${ssh_port} → 22"

    # Build deploy request
    DEPLOY_BODY=$(jq -n \
        --arg tid "$T_ID" \
        --arg name "$VM_NAME" \
        --argjson inputs "$INPUTS" \
        '{
            templateId: $tid,
            vmName: $name,
            inputs: $inputs,
            cpuCount: 2,
            memoryMB: 2048,
            diskSizeGB: 10
        }')

    # Deploy template
    log "Deploying template..."
    DEPLOY_RESP=$(api_raw POST "/api/templates/deploy" -d "$DEPLOY_BODY")
    HTTP_CODE=$(echo "$DEPLOY_RESP" | tail -1)
    BODY=$(echo "$DEPLOY_RESP" | sed '$d')

    if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
        fail "Deploy failed (HTTP ${HTTP_CODE}): ${BODY}"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${T_SLUG} (deploy failed: HTTP ${HTTP_CODE})")
        continue
    fi

    DEPLOY_STATUS=$(echo "$BODY" | jq -r '.status')

    # Handle image download
    if [[ "$DEPLOY_STATUS" == "downloading" ]]; then
        IMAGE_ID=$(echo "$BODY" | jq -r '.imageId')
        if ! wait_for_image "$IMAGE_ID"; then
            FAIL=$((FAIL + 1))
            RESULTS+=("FAIL  ${T_SLUG} (image download failed)")
            continue
        fi

        # Retry deploy after image is ready
        log "  Retrying deploy with downloaded image..."
        DEPLOY_RESP=$(api_raw POST "/api/templates/deploy" -d "$DEPLOY_BODY")
        HTTP_CODE=$(echo "$DEPLOY_RESP" | tail -1)
        BODY=$(echo "$DEPLOY_RESP" | sed '$d')

        if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
            fail "  Deploy retry failed (HTTP ${HTTP_CODE})"
            FAIL=$((FAIL + 1))
            RESULTS+=("FAIL  ${T_SLUG} (deploy retry failed)")
            continue
        fi
        DEPLOY_STATUS=$(echo "$BODY" | jq -r '.status')
    fi

    if [[ "$DEPLOY_STATUS" != "created" ]]; then
        fail "  Unexpected deploy status: ${DEPLOY_STATUS}"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${T_SLUG} (status: ${DEPLOY_STATUS})")
        continue
    fi

    VM_ID=$(echo "$BODY" | jq -r '.vm.id')
    CREATED_VMS+=("$VM_ID")
    ok "VM created: ${VM_ID}"

    # Add SSH port forward to the VM
    log "  Adding SSH port forward..."
    VM_DATA=$(api GET "/api/vms/${VM_ID}")
    EXISTING_PF=$(echo "$VM_DATA" | jq '.portForwards // []')
    MERGED_PF=$(echo "$EXISTING_PF" | jq --argjson port "$ssh_port" \
        '. + [{"protocol":"tcp","hostPort":$port,"guestPort":22}]')

    # Stop VM to apply changes, then restart
    api POST "/api/vms/${VM_ID}/stop" -d '{"method":"force"}' >/dev/null 2>&1 || true
    sleep 3

    api PUT "/api/vms/${VM_ID}" -d "$(jq -n --argjson pf "$MERGED_PF" '{portForwards: $pf}')" >/dev/null 2>&1 || true
    api POST "/api/vms/${VM_ID}/start" >/dev/null 2>&1 || true

    # Wait for VM to boot
    if ! wait_for_boot "$VM_ID"; then
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${T_SLUG} (failed to boot)")
        continue
    fi

    # Validate via SSH
    ssh_errors=0
    if [[ -n "$SSH_KEY" ]]; then
        validate_ssh "$VM_ID" "$ssh_port" "$SSH_USER" || ssh_errors=$?
    fi

    # Wait for template HTTP ports to become reachable
    T_PORTS=$(echo "$TEMPLATE" | jq '.portForwards // []')
    T_NETWORK_MODE=$(echo "$TEMPLATE" | jq -r '.networkMode // "nat"')
    http_ok=true

    if [[ $(echo "$T_PORTS" | jq '[.[] | select(.protocol == "tcp")] | length') -gt 0 ]]; then
        if [[ "$T_NETWORK_MODE" == "bridged" ]]; then
            # Bridged: wait for guest agent to report IP, then check ports on that IP
            GUEST_IP=$(wait_for_guest_ip "$VM_ID") || { http_ok=false; GUEST_IP=""; }
            if [[ -n "$GUEST_IP" ]]; then
                wait_for_http "$GUEST_IP" "$T_PORTS" || http_ok=false
            fi
        else
            # NAT: check ports on localhost using hostPort
            wait_for_http "127.0.0.1" "$T_PORTS" "hostPort" || http_ok=false
        fi
    fi

    # Record result
    if [[ $ssh_errors -eq 0 && "$http_ok" == "true" ]]; then
        ok "PASSED: ${T_NAME}"
        PASS=$((PASS + 1))
        RESULTS+=("PASS  ${T_SLUG}")
    elif [[ "$http_ok" == "false" ]]; then
        fail "FAILED: ${T_NAME} (HTTP port(s) not reachable)"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${T_SLUG} (HTTP unreachable)")
    else
        fail "FAILED: ${T_NAME} (${ssh_errors} validation error(s))"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${T_SLUG} (${ssh_errors} errors)")
    fi

    ssh_port=$((ssh_port + 1))
done

# ── Summary ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Results${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

for result in "${RESULTS[@]}"; do
    case "$result" in
        PASS*) echo -e "  ${GREEN}${result}${NC}" ;;
        FAIL*) echo -e "  ${RED}${result}${NC}" ;;
        SKIP*) echo -e "  ${YELLOW}${result}${NC}" ;;
    esac
done

echo ""
echo -e "  ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}  ${YELLOW}Skipped: ${SKIP}${NC}  Total: ${TEMPLATE_COUNT}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
