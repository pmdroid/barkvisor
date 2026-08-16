#!/usr/bin/env python3
"""Probe every OpenAPI operation against a running BarkVisor Device (PAS-188)."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

OPENAPI = os.environ.get("API_CONTRACT_OPENAPI", "")
BASE = os.environ.get("BASE", "http://127.0.0.1:7777").rstrip("/")
TOKEN = os.environ.get("TOKEN", "")
VM_ID = os.environ.get("SEED_VM_ID", "")
DISK_ID = os.environ.get("SEED_DISK_ID", "")
NETWORK_ID = os.environ.get("SEED_NETWORK_ID", "")
IMAGE_ID = os.environ.get("SEED_IMAGE_ID", "")
HOST_ID = os.environ.get("SEED_HOST_ID", "")

SKIP = {
    ("GET", "/api/vms/{id}/console"): "WebSocket upgrade",
    ("GET", "/api/vms/{id}/vnc"): "WebSocket / noVNC upgrade",
    ("GET", "/api/agent/library/images/{id}/content"): "mTLS agent-plane bytes",
    ("POST", "/api/home/devices/{id}/v1/{path}"): "needs a second Device",
    ("PUT", "/api/home/devices/{id}/v1/{path}"): "needs a second Device",
    ("PATCH", "/api/home/devices/{id}/v1/{path}"): "needs a second Device",
    ("DELETE", "/api/home/devices/{id}/v1/{path}"): "needs a second Device",
}

# start/stop/restart spawn QEMU — only HIT when the operator opted in.
if os.environ.get("API_BDD_QEMU", "0") != "1":
    SKIP[("POST", "/api/vms/{id}/start")] = "QEMU start is PAS-183; set API_BDD_QEMU=1"
    SKIP[("POST", "/api/vms/{id}/stop")] = "QEMU stop is PAS-183; set API_BDD_QEMU=1"
    SKIP[("POST", "/api/vms/{id}/restart")] = "QEMU restart is PAS-183; set API_BDD_QEMU=1"


def parse_openapi(path: str) -> list[tuple[str, str]]:
    text = open(path, encoding="utf-8").read()
    current = None
    ops: list[tuple[str, str]] = []
    for line in text.splitlines():
        m = re.match(r"^  (/[^:]+):", line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"^    (get|post|put|patch|delete):", line)
        if m and current:
            ops.append((m.group(1).upper(), current))
    return ops


def fill(path: str) -> str | None:
    out = path
    if "{deviceId}" in out:
        out = out.replace("{deviceId}", "0000:0000")
    if "{path}" in out:
        out = out.replace("{path}", "vms")
    if "{id}" not in out:
        return out
    if "/workloads/{id}" in path or re.search(r"/vms/\{id\}", path):
        if not VM_ID:
            return None
        return out.replace("{id}", VM_ID)
    if "/disks/{id}" in path:
        if not DISK_ID:
            return None
        return out.replace("{id}", DISK_ID)
    if "/networks/{id}" in path:
        if not NETWORK_ID:
            return None
        return out.replace("{id}", NETWORK_ID)
    if "/images/{id}" in path:
        if not IMAGE_ID:
            return None
        return out.replace("{id}", IMAGE_ID)
    if "/home/devices/{id}" in path:
        if not HOST_ID:
            return None
        return out.replace("{id}", HOST_ID)
    return None


def body_for(method: str, path: str) -> bytes | None:
    if method == "GET" or method == "DELETE":
        if method == "DELETE":
            return None
        return None
    if path == "/api/auth/login":
        user = os.environ.get("BARKVISOR_ADMIN_USER", "admin")
        pw = os.environ.get("BARKVISOR_ADMIN_PASSWORD", "barkvisor-smoke-pass")
        return json.dumps({"username": user, "password": pw}).encode()
    if path == "/api/home/placement/score":
        return b"{}"
    if path == "/api/system/library/settings":
        return b"{}"
    if path.endswith("/health"):
        return b"{}"
    if path.endswith("/health/probe"):
        return b"{}"
    if path == "/api/vms" and method == "POST":
        return None  # seeded already; POST again would create another
    if path == "/api/disks" and method == "POST":
        return None
    if path == "/api/networks" and method == "POST":
        return json.dumps({"name": "bdd-nat", "mode": "nat"}).encode()
    if path == "/api/images/download":
        return json.dumps({"url": "http://127.0.0.1:9/missing.iso", "name": "bdd-skip"}).encode()
    if path == "/api/pairing/codes":
        return b"{}"
    if path == "/api/pairing/redeem":
        return json.dumps({"code": "invalid", "hostId": "bdd", "csrPEM": "x"}).encode()
    if path == "/api/pairing/join":
        return json.dumps({"offer": "invalid"}).encode()
    if path == "/api/auth/ws-ticket":
        return b"{}"
    if path == "/api/workloads/apply":
        return json.dumps({"apiVersion": "barkvisor.dev/v1", "kind": "Workload"}).encode()
    if "/spec" in path and method in ("PUT",):
        return None
    if "/attach-iso" in path or "/detach-iso" in path:
        return b"{}"
    if path.endswith("/usb") and method == "POST":
        return json.dumps({"deviceId": "0000:0000"}).encode()
    if "/resize" in path:
        return json.dumps({"sizeGB": 3}).encode()
    if method == "PATCH":
        return b"{}"
    return b"{}"


def request(method: str, path: str) -> int:
    url = BASE + path
    data = body_for(method, path)
    headers = {}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if data is not None and method not in ("GET", "DELETE"):
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as err:
        return int(err.code)
    except Exception:
        return 0


def main() -> int:
    if not OPENAPI or not os.path.isfile(OPENAPI):
        print("error: API_CONTRACT_OPENAPI missing", file=sys.stderr)
        return 2
    ops = parse_openapi(OPENAPI)
    hits = skips = fails = 0
    print(f"==> probing {len(ops)} OpenAPI operations against {BASE}")
    for method, spec_path in ops:
        if (method, spec_path) in SKIP:
            print(f"SKIP {method:6} {spec_path}  ({SKIP[(method, spec_path)]})")
            skips += 1
            continue
        # Do not DELETE seed resources as part of the baseline (would race later GETs).
        if method == "DELETE" and "{id}" in spec_path:
            print(f"SKIP {method:6} {spec_path}  (destructive; seed kept for GET coverage)")
            skips += 1
            continue
        if method == "POST" and spec_path in ("/api/vms", "/api/disks"):
            print(f"SKIP {method:6} {spec_path}  (seeded once in the runner)")
            skips += 1
            continue
        real = fill(spec_path)
        if real is None:
            print(f"SKIP {method:6} {spec_path}  (no seed id for this path)")
            skips += 1
            continue
        status = request(method, real)
        if status == 404 or status >= 500 or status == 0:
            print(f"FAIL {method:6} {spec_path}  -> {status or 'network'}  ({real})")
            fails += 1
            continue
        print(f"HIT  {method:6} {spec_path}  -> {status}")
        hits += 1
    print(f"==> api-bdd HIT={hits} SKIP={skips} FAIL={fails} TOTAL={len(ops)}")
    if hits + skips != len(ops) or fails:
        return 1
    if hits == 0:
        print("error: no operations HIT", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
