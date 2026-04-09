#!/bin/bash
set -euo pipefail

# BarkVisor Helper — Local Test Script
# Builds the helper, installs it as a launchd daemon, and exercises all XPC methods.

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
DIM="\033[2m"
RESET="\033[0m"

LABEL="dev.barkvisor.helper"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HELPER_BIN=""

info()  { echo -e "${GREEN}✓${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }
error() { echo -e "${RED}✗${RESET} $1"; }
step()  { echo -e "\n${BOLD}$1${RESET}"; }

cleanup() {
    if [ "${KEEP:-}" = "1" ]; then
        warn "Skipping cleanup (--keep). Helper daemon left running."
        warn "To clean up manually:"
        echo -e "  sudo launchctl bootout system/${LABEL}"
        echo -e "  sudo rm ${PLIST_PATH}"
        return
    fi
    step "Cleaning up"
    sudo launchctl bootout "system/${LABEL}" 2>/dev/null && info "Daemon stopped" || true
    if [ -f "$PLIST_PATH" ]; then
        sudo rm "$PLIST_PATH"
        info "Removed ${PLIST_PATH}"
    fi
}

usage() {
    echo -e "${BOLD}Usage:${RESET} $0 [options]"
    echo ""
    echo "Options:"
    echo "  --keep       Don't uninstall the helper after testing"
    echo "  --skip-build Skip building (use existing binary)"
    echo "  --install    Install only, don't run tests"
    echo "  --uninstall  Uninstall only"
    echo "  --status     Check if the helper is running"
    echo "  -h, --help   Show this help"
    exit 0
}

# ── Parse args ──
KEEP=0
SKIP_BUILD=0
INSTALL_ONLY=0
UNINSTALL_ONLY=0
STATUS_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --keep)       KEEP=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --install)    INSTALL_ONLY=1; KEEP=1 ;;
        --uninstall)  UNINSTALL_ONLY=1 ;;
        --status)     STATUS_ONLY=1 ;;
        -h|--help)    usage ;;
        *) error "Unknown option: $arg"; usage ;;
    esac
done

# ── Status check ──
if [ "$STATUS_ONLY" = "1" ]; then
    echo -e "${BOLD}Helper status${RESET}"
    if sudo launchctl print "system/${LABEL}" &>/dev/null; then
        info "Daemon is loaded"
        PID=$(sudo launchctl print "system/${LABEL}" 2>/dev/null | grep "pid =" | awk '{print $3}')
        if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            info "Running (PID ${PID})"
        else
            warn "Loaded but not running"
        fi
    else
        warn "Daemon is not loaded"
    fi
    [ -f "$PLIST_PATH" ] && info "Plist exists at ${PLIST_PATH}" || warn "No plist at ${PLIST_PATH}"
    exit 0
fi

# ── Uninstall ──
if [ "$UNINSTALL_ONLY" = "1" ]; then
    cleanup
    exit 0
fi

echo -e "\n${BOLD}BarkVisor Helper — Local Test${RESET}"
echo -e "${DIM}Builds, installs, and tests the privileged XPC helper.${RESET}\n"

# ── Build ──
if [ "$SKIP_BUILD" = "0" ]; then
    step "1. Building BarkVisorHelper"
    cd "$PROJECT_DIR"
    swift build --product BarkVisorHelper 2>&1 | tail -5
    HELPER_BIN=$(swift build --product BarkVisorHelper --show-bin-path)/BarkVisorHelper
    info "Built: ${HELPER_BIN}"
else
    step "1. Skipping build"
    HELPER_BIN=$(cd "$PROJECT_DIR" && swift build --product BarkVisorHelper --show-bin-path)/BarkVisorHelper
    if [ ! -f "$HELPER_BIN" ]; then
        error "Binary not found at ${HELPER_BIN}. Run without --skip-build first."
        exit 1
    fi
    info "Using: ${HELPER_BIN}"
fi

# ── Install as launchd daemon ──
step "2. Installing helper daemon"

# Stop existing daemon if loaded
if sudo launchctl print "system/${LABEL}" &>/dev/null; then
    warn "Existing daemon found, stopping..."
    sudo launchctl bootout "system/${LABEL}" 2>/dev/null || true
    sleep 0.5
fi

# Write launchd plist pointing at the built binary
sudo tee "$PLIST_PATH" > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>Program</key>
    <string>${HELPER_BIN}</string>
    <key>MachServices</key>
    <dict>
        <key>${LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/barkvisor-helper.stderr</string>
    <key>StandardOutPath</key>
    <string>/tmp/barkvisor-helper.stdout</string>
</dict>
</plist>
EOF
info "Wrote ${PLIST_PATH}"

sudo launchctl bootstrap system "$PLIST_PATH"
sleep 0.5

# Verify it's running
if sudo launchctl print "system/${LABEL}" &>/dev/null; then
    PID=$(sudo launchctl print "system/${LABEL}" 2>/dev/null | grep "pid =" | awk '{print $3}')
    if [ -n "$PID" ] && [ "$PID" != "0" ]; then
        info "Daemon running (PID ${PID})"
    else
        warn "Daemon loaded but PID not yet available"
    fi
else
    error "Failed to start daemon"
    echo -e "${DIM}Check: sudo cat /tmp/barkvisor-helper.stderr${RESET}"
    exit 1
fi

if [ "$INSTALL_ONLY" = "1" ]; then
    echo ""
    info "Helper installed and running. Use --uninstall to remove."
    exit 0
fi

# ── Run XPC tests ──
step "3. Running XPC unit tests"
cd "$PROJECT_DIR"
FAILURES=0

swift test --filter HelperXPCTests 2>&1 | while IFS= read -r line; do
    if echo "$line" | grep -q "passed"; then
        echo -e "  ${GREEN}${line}${RESET}"
    elif echo "$line" | grep -q "failed"; then
        echo -e "  ${RED}${line}${RESET}"
    elif echo "$line" | grep -q "Test Suite"; then
        echo -e "  ${DIM}${line}${RESET}"
    fi
done
TEST_EXIT=${PIPESTATUS[0]}

if [ "$TEST_EXIT" = "0" ]; then
    info "All XPC tests passed"
else
    error "Some XPC tests failed (exit code ${TEST_EXIT})"
    FAILURES=1
fi

# ── Integration smoke test (calls the real daemon) ──
step "4. Integration smoke test"

# We use a tiny Swift script to talk to the real helper over XPC
SMOKE_SCRIPT=$(mktemp /tmp/barkvisor-smoke-XXXXXX.swift)
cat > "$SMOKE_SCRIPT" << 'SWIFT'
import Foundation

let kHelperMachServiceName = "dev.barkvisor.helper"

@objc protocol HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func ping(reply: @escaping (String) -> Void)
    func installBridge(interface: String, vmnetBinPath: String,
                       reply: @escaping (Bool, String?) -> Void)
    func removeBridge(interface: String,
                      reply: @escaping (Bool, String?) -> Void)
    func bridgeStatus(interface: String,
                      reply: @escaping (Bool, String?) -> Void)
}

let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
conn.resume()

let group = DispatchGroup()
var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ✓ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        passed += 1
    } else {
        print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        failed += 1
    }
}

let proxy = conn.remoteObjectProxyWithErrorHandler { error in
    print("  ✗ XPC connection error: \(error)")
    exit(1)
} as! HelperProtocol

// Test 1: ping
group.enter()
proxy.ping { reply in
    check("ping", reply == "Hello from BarkVisorHelper!", reply)
    group.leave()
}

// Test 2: getVersion
group.enter()
proxy.getVersion { version in
    check("getVersion", !version.isEmpty, version)
    group.leave()
}

// Test 3: bridgeStatus for non-existent interface
group.enter()
proxy.bridgeStatus(interface: "test99") { _, status in
    check("bridgeStatus(test99)", status == "not_installed", status ?? "nil")
    group.leave()
}

// Test 4: installBridge with invalid interface (injection attempt)
group.enter()
proxy.installBridge(interface: "en0;rm", vmnetBinPath: "/opt/homebrew/bin/socket_vmnet") { ok, err in
    check("installBridge(invalid iface rejected)", !ok, err ?? "nil")
    group.leave()
}

// Test 5: installBridge with invalid path
group.enter()
proxy.installBridge(interface: "en0", vmnetBinPath: "/tmp/evil") { ok, err in
    check("installBridge(invalid path rejected)", !ok, err ?? "nil")
    group.leave()
}

// Test 6: removeBridge with invalid interface
group.enter()
proxy.removeBridge(interface: "../etc") { ok, err in
    check("removeBridge(invalid iface rejected)", !ok, err ?? "nil")
    group.leave()
}

let result = group.wait(timeout: .now() + 10)
if result == .timedOut {
    print("  ✗ Timed out waiting for XPC replies")
    failed += 1
}

conn.invalidate()

print("")
print("  \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
SWIFT

info "Running smoke test against live daemon..."
if swift "$SMOKE_SCRIPT" 2>/dev/null; then
    info "Smoke tests passed"
else
    error "Smoke tests failed"
    FAILURES=1
fi
rm -f "$SMOKE_SCRIPT"

# ── Helper logs ──
step "5. Helper logs"
if [ -f /tmp/barkvisor-helper.stderr ]; then
    LINES=$(wc -l < /tmp/barkvisor-helper.stderr | tr -d ' ')
    if [ "$LINES" -gt 0 ]; then
        echo -e "${DIM}"
        tail -10 /tmp/barkvisor-helper.stderr
        echo -e "${RESET}"
    else
        info "No stderr output (clean)"
    fi
else
    info "No stderr log file"
fi

# ── Cleanup ──
trap - EXIT
cleanup

# ── Summary ──
echo ""
if [ "${FAILURES:-0}" = "0" ]; then
    echo -e "${GREEN}${BOLD}All tests passed.${RESET}"
else
    echo -e "${RED}${BOLD}Some tests failed.${RESET}"
    exit 1
fi
