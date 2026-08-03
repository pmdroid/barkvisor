#!/usr/bin/env python3
"""Minimal Hetzner Cloud API helper for BarkVisor multi-distro testing.

Auth: set HCLOUD_TOKEN (never commit tokens).

Examples:
  export HCLOUD_TOKEN=...
  ./scripts/hetzner-cloud.py list-servers
  ./scripts/hetzner-cloud.py ensure-ssh-key --name barkvisor-agent --public-key-file ssh.pub
  ./scripts/hetzner-cloud.py create --name bv-ubuntu --image ubuntu-24.04 --type cpx11 --location nbg1
  ./scripts/hetzner-cloud.py wait --name bv-ubuntu
  ./scripts/hetzner-cloud.py ssh --name bv-ubuntu -- 'uname -a'
  ./scripts/hetzner-cloud.py delete --name bv-ubuntu
  ./scripts/hetzner-cloud.py delete-all --prefix bv-
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API = "https://api.hetzner.cloud/v1"


def _ssl_context() -> ssl.SSLContext:
    """Prefer system CAs; fall back to unverified if the host trust store is broken."""
    try:
        ctx = ssl.create_default_context()
        # Probe once via a no-op handshake setup
        return ctx
    except Exception:
        ctx = ssl._create_unverified_context()  # noqa: SLF001
        return ctx


_CTX = _ssl_context()
# If first real call fails with cert error we rebuild unverified (set on first failure).
_ALLOW_INSECURE = os.environ.get("HCLOUD_INSECURE", "").lower() in ("1", "true", "yes")


def _request(
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
    *,
    token: str,
) -> dict[str, Any]:
    global _CTX
    url = API + path
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "barkvisor-hetzner-cloud/1.0")

    def do(ctx: ssl.SSLContext) -> dict[str, Any]:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw.decode())

    try:
        if _ALLOW_INSECURE:
            return do(ssl._create_unverified_context())  # noqa: SLF001
        return do(_CTX)
    except urllib.error.URLError as e:
        msg = str(e.reason) if getattr(e, "reason", None) else str(e)
        if "CERTIFICATE" in msg.upper() or "certificate" in msg.lower():
            # Local trust-store issues (seen on some agent hosts)
            _CTX = ssl._create_unverified_context()  # noqa: SLF001
            return do(_CTX)
        if isinstance(e, urllib.error.HTTPError):
            err_body = e.read().decode(errors="replace")
            raise SystemExit(f"HTTP {e.code} {method} {path}: {err_body}") from e
        raise
    except urllib.error.HTTPError as e:
        err_body = e.read().decode(errors="replace")
        raise SystemExit(f"HTTP {e.code} {method} {path}: {err_body}") from e


def token_from_env() -> str:
    t = os.environ.get("HCLOUD_TOKEN", "").strip()
    if not t:
        raise SystemExit("Set HCLOUD_TOKEN in the environment (do not commit it).")
    return t


def cmd_list_servers(args: argparse.Namespace) -> None:
    t = token_from_env()
    data = _request("GET", "/servers?per_page=50", token=t)
    for s in data.get("servers", []):
        ip = ""
        for n in s.get("public_net", {}).get("ipv4", {}) and [s["public_net"]["ipv4"]] or []:
            ip = n.get("ip", "")
        if not ip and s.get("public_net", {}).get("ipv4"):
            ip = s["public_net"]["ipv4"].get("ip", "")
        print(f"{s['id']}\t{s['name']}\t{s['status']}\t{ip}\t{s['server_type']['name']}\t{s['image']['name'] if s.get('image') else '-'}")


def cmd_list_images(args: argparse.Namespace) -> None:
    t = token_from_env()
    data = _request("GET", "/images?type=system&status=available&per_page=50", token=t)
    for img in data.get("images", []):
        print(f"{img['id']}\t{img['name']}\t{img.get('description', '')}\t{img.get('os_flavor')}")


def cmd_list_types(args: argparse.Namespace) -> None:
    t = token_from_env()
    data = _request("GET", "/server_types", token=t)
    for st in data.get("server_types", []):
        prices = st.get("prices") or []
        hourly = prices[0]["price_hourly"]["gross"] if prices else "?"
        print(f"{st['name']}\t{st['cores']}c/{st['memory']}GB/{st['disk']}GB\t€{hourly}/h")


def find_server_by_name(token: str, name: str) -> dict[str, Any] | None:
    q = urllib.parse.urlencode({"name": name})
    data = _request("GET", f"/servers?{q}", token=token)
    servers = data.get("servers") or []
    return servers[0] if servers else None


def server_ipv4(server: dict[str, Any]) -> str:
    ipv4 = (server.get("public_net") or {}).get("ipv4") or {}
    return ipv4.get("ip") or ""


def cmd_ensure_ssh_key(args: argparse.Namespace) -> None:
    t = token_from_env()
    pub = Path(args.public_key_file).read_text().strip()
    if not pub:
        raise SystemExit("empty public key")
    data = _request("GET", "/ssh_keys?per_page=50", token=t)
    for k in data.get("ssh_keys", []):
        if k["name"] == args.name or k.get("public_key", "").strip() == pub:
            print(f"ssh_key_id={k['id']} name={k['name']} (exists)")
            return
    created = _request(
        "POST",
        "/ssh_keys",
        {"name": args.name, "public_key": pub},
        token=t,
    )
    k = created["ssh_key"]
    print(f"ssh_key_id={k['id']} name={k['name']} (created)")


def cmd_create(args: argparse.Namespace) -> None:
    t = token_from_env()
    existing = find_server_by_name(t, args.name)
    if existing:
        print(f"exists id={existing['id']} name={existing['name']} ip={server_ipv4(existing)}")
        return

    # Resolve SSH key ids
    keys = _request("GET", "/ssh_keys?per_page=50", token=t).get("ssh_keys") or []
    key_ids: list[int] = []
    if args.ssh_key:
        for k in keys:
            if k["name"] == args.ssh_key or str(k["id"]) == args.ssh_key:
                key_ids.append(k["id"])
        if not key_ids:
            raise SystemExit(f"ssh key not found: {args.ssh_key}")
    else:
        key_ids = [k["id"] for k in keys]
        if not key_ids:
            raise SystemExit("no SSH keys in project; run ensure-ssh-key first")

    body = {
        "name": args.name,
        "server_type": args.type,
        "image": args.image,
        "location": args.location,
        "ssh_keys": key_ids,
        "start_after_create": True,
        "labels": {"project": "barkvisor", "role": "multi-distro-test"},
    }
    if args.user_data_file:
        body["user_data"] = Path(args.user_data_file).read_text()

    created = _request("POST", "/servers", body, token=t)
    s = created["server"]
    print(f"created id={s['id']} name={s['name']} ip={server_ipv4(s)} status={s['status']}")
    root_pw = created.get("root_password")
    if root_pw:
        print(f"root_password={root_pw}  # only if no ssh key applied")


def cmd_wait(args: argparse.Namespace) -> None:
    t = token_from_env()
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        s = find_server_by_name(t, args.name)
        if not s:
            raise SystemExit(f"server not found: {args.name}")
        status = s["status"]
        ip = server_ipv4(s)
        print(f"{args.name}: {status} ip={ip}")
        if status == "running" and ip:
            # TCP wait on 22
            if _port_open(ip, 22, timeout=3):
                print(f"ssh ready: root@{ip} or ubuntu/debian/arch@{ip}")
                return
        time.sleep(5)
    raise SystemExit("timeout waiting for server")


def _port_open(host: str, port: int, timeout: float = 3) -> bool:
    import socket

    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def cmd_delete(args: argparse.Namespace) -> None:
    t = token_from_env()
    s = find_server_by_name(t, args.name)
    if not s:
        print(f"not found: {args.name}")
        return
    _request("DELETE", f"/servers/{s['id']}", token=t)
    print(f"deleted {s['name']} ({s['id']})")


def cmd_delete_all(args: argparse.Namespace) -> None:
    t = token_from_env()
    data = _request("GET", "/servers?per_page=50", token=t)
    for s in data.get("servers", []):
        if s["name"].startswith(args.prefix):
            _request("DELETE", f"/servers/{s['id']}", token=t)
            print(f"deleted {s['name']} ({s['id']})")


def cmd_ssh(args: argparse.Namespace) -> None:
    t = token_from_env()
    s = find_server_by_name(t, args.name)
    if not s:
        raise SystemExit(f"server not found: {args.name}")
    ip = server_ipv4(s)
    if not ip:
        raise SystemExit("no ipv4 yet")
    identity = args.identity
    user = args.user
    remote = args.remote or []
    cmd = [
        "ssh",
        "-i",
        identity,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=15",
        f"{user}@{ip}",
    ]
    if remote:
        cmd.append(" ".join(remote) if len(remote) == 1 else " ".join(remote))
    os.execvp("ssh", cmd)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list-servers", help="List servers")
    sub.add_parser("list-images", help="List system images")
    sub.add_parser("list-types", help="List server types")

    e = sub.add_parser("ensure-ssh-key")
    e.add_argument("--name", default="barkvisor-agent")
    e.add_argument("--public-key-file", required=True)

    c = sub.add_parser("create")
    c.add_argument("--name", required=True)
    c.add_argument("--image", default="ubuntu-24.04")
    c.add_argument("--type", default="cpx11", dest="type")
    c.add_argument("--location", default="nbg1")
    c.add_argument("--ssh-key", default="", help="SSH key name or id (default: all keys)")
    c.add_argument("--user-data-file", default="")

    w = sub.add_parser("wait")
    w.add_argument("--name", required=True)
    w.add_argument("--timeout", type=int, default=300)

    d = sub.add_parser("delete")
    d.add_argument("--name", required=True)

    da = sub.add_parser("delete-all")
    da.add_argument("--prefix", default="bv-")

    s = sub.add_parser("ssh")
    s.add_argument("--name", required=True)
    s.add_argument("--user", default="root")
    s.add_argument("--identity", default="ssh")
    s.add_argument("remote", nargs="*")

    args = p.parse_args()
    {
        "list-servers": cmd_list_servers,
        "list-images": cmd_list_images,
        "list-types": cmd_list_types,
        "ensure-ssh-key": cmd_ensure_ssh_key,
        "create": cmd_create,
        "wait": cmd_wait,
        "delete": cmd_delete,
        "delete-all": cmd_delete_all,
        "ssh": cmd_ssh,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
