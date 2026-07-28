# Agent handoff: BarkVisor Linux port + simplification

**Last updated:** 2026-07-27  
**Repo:** `github.com/pmdroid/barkvisor`  
**Primary host:** macOS (dev) + OrbStack Ubuntu 24.04 `barkvisor-u24` for Linux proof  
**Goal:** Linux NAT-only MVP usable on a VM; reduce macOS-only complexity; merge stack when green.

Use this file as the source of truth for the next agent. Do **not** restart the port from main without reading the stack below.

---

## 1. Current PR stack (merge bottom → top)

| Order | PR | Branch | Base | Role |
|------:|----|--------|------|------|
| 1 | [#7](https://github.com/pmdroid/barkvisor/pull/7) | `pmdroid/bv-platform-foundation-2` | `main` | Platform paths/random/host/capabilities helpers |
| 2 | [#8](https://github.com/pmdroid/barkvisor/pull/8) | `pmdroid/bv-qemu-privilege` | #7 | HVF/KVM, PrivilegeService, NAT-only Linux, no socket_vmnet on Linux |
| 3 | [#6](https://github.com/pmdroid/barkvisor/pull/6) | `pmdroid/bv-capabilities-ui` | #8 | `GET /api/system/capabilities` + Vue gating |
| 4 | [#9](https://github.com/pmdroid/barkvisor/pull/9) | `pmdroid/linux-build-fixes` | #6 | Linux compile (Crypto, FoundationNetworking, sockets, process watch) |
| 5 | [#10](https://github.com/pmdroid/barkvisor/pull/10) | `pmdroid/linux-docker-docs` | #9 | `docs/getting-started-linux.md`, Dockerfile |
| 6 | [#11](https://github.com/pmdroid/barkvisor/pull/11) | `pmdroid/linux-systemd` | #10 | `Resources/barkvisor.service`, `scripts/install-linux.sh` |
| 7 | [#12](https://github.com/pmdroid/barkvisor/pull/12) | `pmdroid/linux-product` | #11 | Firmware AAVMF/OVMF, env vars, `linux-smoke.sh` / `linux-dev.sh` |
| 8 | [#13](https://github.com/pmdroid/barkvisor/pull/13) | `pmdroid/simplify-complexity` | #12 | Delete QEMUMonitor, skip bridge-sync on Linux, remove fake QEMU preview, capabilities single source |

### Restack rule

When a lower PR changes:

```bash
git fetch origin
git checkout pmdroid/<branch>
git rebase origin/<parent-branch>
git push --force-with-lease
# Keep PR base = parent branch name (not always main)
```

Use HTTPS remote if SSH agent fails:

```bash
git remote set-url origin https://github.com/pmdroid/barkvisor.git
gh auth setup-git
```

### Local worktrees (typical paths)

Under `/Users/pascal/orca/workspaces/barkvisor/`:

- `bv-platform-foundation-2`, `bv-qemu-privilege`, `bv-capabilities-ui`
- `linux-build-fixes`, `linux-docker-docs`, `linux-systemd`, `linux-product`
- `simplify-complexity` ← **current tip**

Main clone: `/Volumes/Data/workspace-mac/barkvisor` (often still on `main` only).

---

## 2. CI status (as of last full poll)

| PRs | Expected checks | Status |
|-----|-----------------|--------|
| **#7, #8, #6** | Lint, Build, Test | **All green** |
| **#9–#12** | Lint, Build, Test, **Linux Build** | **All green** (after fixes below) |
| **#13** | Same as #9–#12 | Lint green; Build/Linux may still be running after open |

### Fixes that made Linux CI green

1. **SwiftFormat** on `SetupMiddleware` public-route allowlist.  
2. **Swift tarball URL** on x86_64 GitHub runners must be:

   `https://download.swift.org/swift-6.2.3-release/ubuntu2404/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE-ubuntu24.04.tar.gz`  

   (**not** `…-ubuntu24.04-x86_64.tar.gz` — that 404s).

3. CI runs on **all PR bases** (not only `main`) so stacked PRs get checks.  
4. Linux job installs official Swift tarball (not `swift-actions/setup-swift` for 6.2.3).

Before merging, re-run:

```bash
for n in 7 8 6 9 10 11 12 13; do echo "PR $n"; gh pr checks $n --repo pmdroid/barkvisor; done
```

---

## 3. What already works (do not redo)

### Linux (OrbStack `barkvisor-u24` = Ubuntu 24.04 arm64)

- `swift build --product BarkVisorApp` succeeds  
- Server starts; `GET /api/health` → 200  
- `GET /api/system/capabilities` → 200 **before** setup (middleware allowlist):

  ```json
  {
    "platform": "Linux",
    "accelerator": "kvm",
    "hostArch": "arm64",
    "supportsBridgedNetworking": false,
    "supportsUSBPassthrough": false,
    "supportsInAppUpdate": false
  }
  ```

- Distro firmware present: `/usr/share/AAVMF/AAVMF_CODE.fd` (`qemu-efi-aarch64`)  
- Prefer **Ubuntu 24.04** for Swift toolchains; **26.04** breaks on `libxml2.so.16` vs Swift’s `libxml2.so.2`

### Architecture decisions already made

- **NAT only** on Linux; no socket_vmnet / XPC helper  
- **PrivilegeService** wraps helper; Linux is no-op with clear errors  
- **PlatformCapabilities** is the single feature-flag source  
- **PlatformPaths** for data/socket dirs + env overrides  
- Env: `BARKVISOR_PORT`, `BARKVISOR_DATA_DIR`, `BARKVISOR_FRONTEND_DIR`

### Simplification already in #13

- Deleted unused `QEMUMonitor.swift`  
- `bridge-sync` periodic task only if `PrivilegeService.isBridgedNetworkingSupported`  
- Removed CreateVMDrawer fake QEMU cmdline (hardcoded aarch64/hvf)  
- Capabilities API + Privilege flags + USB list empty when unsupported  

---

## 4. Product milestones

| Milestone | Meaning | Status |
|-----------|---------|--------|
| **M1 Alpha Linux** | Build + run + capabilities + setup possible | ~Done once stack merges |
| **M2 Usable Linux** | M1 + SPA UI + **one NAT guest boot** + console | **Next** |
| **M3 Installable** | M2 + systemd/tarball/docker proven | Scripts exist; not E2E-proven |
| **M4 Multi-arch** | x86_64 host/guest | Partial code paths only |
| **M5 Network parity** | Linux bridge model | Explicitly later |

---

## 5. Next steps for the continuing agent (priority order)

### P0 — Before more features

1. **Confirm #13 CI fully green** (Build, Test, Linux Build).  
2. **Optionally merge stack** #7→#13 bottom-up (user decision). If merging, restack is no longer needed.

### P0 — Highest product value next (M2)

3. **First NAT guest boot on Orb** (new PR on tip, e.g. `#14`):
   - Ensure `qemu-system-aarch64` + AAVMF resolve via `QEMUBuilder`  
   - Download a known-good arm64 cloud image (or document exact image URL)  
   - API or UI: create VM `linux-arm64`, NAT network, start  
   - Verify process running, serial/VNC sockets, optional guest SSH via port-forward  
   - Prefer a small script `scripts/linux-guest-smoke.sh` using curl + JWT after setup  

4. **Frontend SPA on Linux**:
   - `cd frontend && bun install && bun run build`  
   - Serve via existing `findFrontendDist()` / `BARKVISOR_FRONTEND_DIR`  
   - Document in `docs/getting-started-linux.md`  

5. **Setup wizard E2E** on Linux (create admin, login, create VM).

### P1 — Install / ops proof

6. Dry-run `scripts/install-linux.sh` + systemd on Orb (may need root).  
7. Make Dockerfile actually build (multi-stage with correct Swift image).  
8. Keep `scripts/linux-smoke.sh` green; extend it after guest boot exists.

### P1 — Further simplification (from complexity audit)

Do these after or in parallel with M2, as small stacked PRs:

| Priority | Task | Why |
|----------|------|-----|
| High | **CreateVMDrawer step split** | Largest remaining frontend complexity |
| High | **Controllers never touch HelperXPCClient** (already mostly PrivilegeService—audit any leftovers) | Single privilege boundary |
| Medium | **SystemController split** (host / bridge / about) | Kitchen sink |
| Medium | **BundleResolver path-list consolidation** | Fewer duplicate search paths |
| Medium | QEMUBuilder accel/binary **only** from PlatformCapabilities tables | Fewer literals |
| Low | Split `scripts/build-release.sh` | macOS ops only |
| **Defer** | VMManager DI / actor graph rewrite | High risk, low urgency |
| **Defer** | Linux bridge / USB / in-app updates | Not MVP |

### P2 — Explicit non-goals for now

- Bridged networking on Linux (TAP/polkit redesign)  
- USB passthrough on Linux  
- In-app Linux updates  
- Building QEMU from source for Linux releases  
- Weakening macOS signing/notarization for “simplicity”

---

## 6. Complexity audit (summary for next agent)

Full analysis was done by a plan agent. Core message:

1. **Capability-gate** optional macOS features (mostly done).  
2. **Privilege + paths single boundary** (mostly done; keep enforcing).  
3. **Frontend wizard slimdown** (preview removed; full step split still open).  
4. **Do not rewrite** auth, QMP, reconnect, cloud-init, HVF linger workarounds.

Quick wins still available:

- Audit/remove unused HMP `-monitor` socket if nothing uses it  
- README multi-platform blurb on main after merge  
- Any remaining direct `HelperXPCClient` call sites outside PrivilegeService  

---

## 7. Orb / Linux recipes

### Machine

```bash
orb list
# barkvisor-u24 = Ubuntu 24.04 arm64 (preferred)
# barkvisor-linux = Ubuntu 26.04 — avoid for Swift tarball ABI
```

### Build + run

```bash
orb -m barkvisor-u24
export PATH="$HOME/swift/usr/bin:$PATH"
cd /Users/pascal/orca/workspaces/barkvisor/simplify-complexity   # or stack tip
swift build --product BarkVisorApp
export BARKVISOR_PORT=7777
export BARKVISOR_DATA_DIR=/tmp/barkvisor-dev
./.build/debug/BarkVisorApp
# curl http://127.0.0.1:7777/api/health
# curl http://127.0.0.1:7777/api/system/capabilities
```

### Smoke script (from #12+)

```bash
./scripts/linux-smoke.sh
```

### Free port 7777 if bind fails

Old process may linger:

```bash
# On Orb VM:
ss -lptn 'sport = :7777'
# kill by PID from ss (avoid pkill -f patterns that match the agent wrapper)
kill -9 <pid>
```

---

## 8. Key files

| Area | Paths |
|------|--------|
| Platform | `Sources/BarkVisorCore/Platform/*` |
| Privilege | `Sources/BarkVisorCore/Services/PrivilegeService.swift`, `HelperXPCClient.swift` |
| QEMU | `Sources/BarkVisorCore/Services/QEMUBuilder.swift` |
| Setup gate | `Sources/BarkVisor/Server/Middleware/SetupMiddleware.swift` |
| Capabilities API | `SystemController.getCapabilities` / `registerPublicRoutes` |
| Frontend caps | `frontend/src/stores/capabilities.ts` |
| Linux docs | `docs/getting-started-linux.md` |
| CI | `.github/workflows/ci.yml` |
| Scripts | `scripts/linux-smoke.sh`, `linux-dev.sh`, `install-linux.sh` |

---

## 9. Suggested first actions for the next agent session

```text
1. gh pr checks for #7–#13; fix any red on #13 first
2. Confirm tip branch: pmdroid/simplify-complexity
3. Implement PR #14: first NAT guest boot + optional linux-guest-smoke.sh
4. Implement PR #15: frontend build path verified on Orb
5. Update this handoff when milestones move
```

---

## 10. User preferences (from this project)

- Work in **worktrees**, **stacked PRs**, easy rebase  
- Prefer **Grok/parallel agents** for independent chunks  
- **Linux NAT MVP first**, not full macOS parity  
- Use **Orb** for real Linux verification  
- Keep **draft PRs** for review before merge  
- Avoid expanding scope into bridge/USB/updates until M2 is done  

---

*End of handoff. Prefer extending this file over scattering status in chat.*
