# Agent handoff: BarkVisor Linux port + simplification

> **Product docs supersede this file.** Current multi-distro Linux support (what works, distro matrix, smokes, limits) is in **[getting-started-linux.md](getting-started-linux.md)** and the root **README**. Keep this handoff for **historical PR/merge context** only.

**Last updated:** 2026-07-30 (banner only; historical sections below unchanged)  
**Repo:** `github.com/pmdroid/barkvisor`  
**Primary host:** macOS packaging + multi-distro Linux headless hosts  
**Goal (historical):** Linux NAT MVP → multi-distro first-class support (NAT, bridge, USB, arm64/x86_64).

The Linux foundation stack (#7–#13) is **already on main** — do **not** re-land those PRs or restart the port from scratch.

---

## 1. Merged stack (historical — all on `main`)

| Order | PR | Branch | Role | Status |
|------:|----|--------|------|--------|
| 1 | [#7](https://github.com/pmdroid/barkvisor/pull/7) | `pmdroid/bv-platform-foundation-2` | Platform paths/random/host/capabilities helpers | **MERGED** |
| 2 | [#8](https://github.com/pmdroid/barkvisor/pull/8) | `pmdroid/bv-qemu-privilege` | HVF/KVM, PrivilegeService, NAT-only Linux | **MERGED** |
| 3 | [#6](https://github.com/pmdroid/barkvisor/pull/6) | `pmdroid/bv-capabilities-ui` | `GET /api/system/capabilities` + Vue gating | **MERGED** |
| 4 | [#9](https://github.com/pmdroid/barkvisor/pull/9) | `pmdroid/linux-build-fixes` | Linux compile (Crypto, sockets, process watch) | **MERGED** |
| 5 | [#10](https://github.com/pmdroid/barkvisor/pull/10) | `pmdroid/linux-docker-docs` | `docs/getting-started-linux.md`, Dockerfile | **MERGED** |
| 6 | [#11](https://github.com/pmdroid/barkvisor/pull/11) | `pmdroid/linux-systemd` | `Resources/barkvisor.service`, `scripts/install-linux.sh` | **MERGED** |
| 7 | [#12](https://github.com/pmdroid/barkvisor/pull/12) | `pmdroid/linux-product` | Firmware AAVMF/OVMF, env vars, `linux-smoke.sh` / `linux-dev.sh` | **MERGED** |
| 8 | [#13](https://github.com/pmdroid/barkvisor/pull/13) | `pmdroid/simplify-complexity` | Delete QEMUMonitor, skip bridge-sync on Linux, capabilities single source | **MERGED** |

Merge tip on `main`: `Merge pull request #13` (and parents #12…#7 / #6).

### Workflow now (post-merge)

Primary workflow is **branch from `main`**, small focused PRs (still fine as independent stacks if needed). Restacking the old #7–#13 chain is **not** the default.

```bash
git fetch origin
git checkout main
git pull origin main
git checkout -b pmdroid/<feature>
# … implement, push, open PR against main …
```

Use HTTPS remote if SSH agent fails:

```bash
git remote set-url origin https://github.com/pmdroid/barkvisor.git
gh auth setup-git
```

### Local worktrees (typical paths)

Under `/Users/pascal/orca/workspaces/barkvisor/`:

- `docs-post-merge` — this handoff / README update  
- Follow-up theme worktrees (branch from main):  
  `linux-guest-boot`, `createvm-step-split`, `privilege-monitor-cleanup`,  
  `system-controller-split`, `platform-path-tables`  
- Historical stack worktrees may still exist; treat them as archived once merged

Main clone: `/Volumes/Data/workspace-mac/barkvisor` (often on `main`).

---

## 2. CI notes (merged stack)

Linux CI path that stayed green:

1. **SwiftFormat** on `SetupMiddleware` public-route allowlist.  
2. **Swift tarball URL** on x86_64 GitHub runners:

   `https://download.swift.org/swift-6.2.3-release/ubuntu2404/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE-ubuntu24.04.tar.gz`  

   (**not** `…-ubuntu24.04-x86_64.tar.gz` — that 404s).

3. Linux job installs official Swift tarball (not `swift-actions/setup-swift` for 6.2.3).  
4. CI runs on PR bases so stacked branches still get checks when used.

After opening a new PR:

```bash
gh pr checks <n> --repo pmdroid/barkvisor
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
- Any current Ubuntu works: use `./scripts/install-swift-linux.sh` (LTS toolchain + SONAME shims via `scripts/lib/linux-swift-compat.sh` for 26.04+ `libxml2.so.16` vs `libxml2.so.2`)  
- `./scripts/linux-smoke.sh` — build + brief start + health + capabilities

### Architecture decisions already made

- **NAT only** on Linux; no socket_vmnet / XPC helper  
- **PrivilegeService** wraps helper; Linux is no-op with clear errors  
- **PlatformCapabilities** is the single feature-flag source  
- **PlatformPaths** for data/socket dirs + env overrides  
- Env: `BARKVISOR_PORT`, `BARKVISOR_DATA_DIR`, `BARKVISOR_FRONTEND_DIR`

### Simplification already on main (from #13)

- Deleted unused `QEMUMonitor.swift`  
- `bridge-sync` periodic task only if `PrivilegeService.isBridgedNetworkingSupported`  
- Removed CreateVMDrawer fake QEMU cmdline (hardcoded aarch64/hvf)  
- Capabilities API + Privilege flags + USB list empty when unsupported  

---

## 4. Product milestones

| Milestone | Meaning | Status |
|-----------|---------|--------|
| **M1 Alpha Linux** | Build + run + capabilities + setup possible | **Done** (stack #7–#13 on `main`) |
| **M2 Usable Linux** | M1 + SPA UI + **one NAT guest boot** + console | **Next** — guest boot PRs |
| **M3 Installable** | M2 + systemd/tarball/docker proven | Scripts exist; not E2E-proven |
| **M4 Multi-arch** | x86_64 host/guest | Partial code paths only |
| **M5 Network parity** | Linux bridge model | Explicitly later |

---

## 5. Next steps for the continuing agent (priority order)

### P0 — Highest product value (M2)

1. **First NAT guest boot on Orb** (new PR from `main`, e.g. `pmdroid/linux-guest-boot`):
   - Ensure `qemu-system-aarch64` + AAVMF resolve via `QEMUBuilder`  
   - Download a known-good arm64 cloud image (or document exact image URL)  
   - API or UI: create VM `linux-arm64`, NAT network, start  
   - Verify process running, serial/VNC sockets, optional guest SSH via port-forward  
   - Prefer a small script `scripts/linux-guest-smoke.sh` using curl + JWT after setup  
   - Keep `./scripts/linux-smoke.sh` green (health/capabilities only today)

2. **Frontend SPA on Linux**:
   - `cd frontend && bun install && bun run build`  
   - Serve via existing `findFrontendDist()` / `BARKVISOR_FRONTEND_DIR`  
   - Document in `docs/getting-started-linux.md` if gaps remain  

3. **Setup wizard E2E** on Linux (create admin, login, create VM).

### P1 — Install / ops proof

4. Dry-run `scripts/install-linux.sh` + systemd on Orb (may need root).  
5. Make Dockerfile actually build (multi-stage with correct Swift image).  
6. Extend smoke after guest boot exists (do not claim guest-smoke files until they land).

### P1 — Follow-up PR themes (open / planned on main)

Independent cleanups; prefer small PRs from `main`. Local worktrees may already exist under `/Users/pascal/orca/workspaces/barkvisor/`.

| Theme | Suggested branch / focus | Why |
|-------|--------------------------|-----|
| **Guest smoke / boot** | `pmdroid/linux-guest-boot` | Unlocks M2 — one NAT guest + optional guest-smoke script |
| **CreateVM step split** | `pmdroid/createvm-step-split` | Largest remaining frontend complexity |
| **Privilege / monitor cleanup** | `pmdroid/privilege-monitor-cleanup` | Controllers never touch `HelperXPCClient`; audit leftover HMP `-monitor` if unused |
| **SystemController split** | `pmdroid/system-controller-split` | Host / bridge / about kitchen sink |
| **Platform path tables** | `pmdroid/platform-path-tables` | QEMUBuilder accel/binary + BundleResolver paths only from PlatformCapabilities / consolidated tables |

Other still useful:

| Priority | Task |
|----------|------|
| Medium | BundleResolver path-list consolidation |
| Low | Split `scripts/build-release.sh` (macOS ops only) |
| **Defer** | VMManager DI / actor graph rewrite |
| **Defer** | Linux bridge / USB / in-app updates |

### P2 — Explicit non-goals for now

- Bridged networking on Linux (TAP/polkit redesign)  
- USB passthrough on Linux  
- In-app Linux updates  
- Building QEMU from source for Linux releases  
- Weakening macOS signing/notarization for “simplicity”  
- Claiming full Linux feature parity with macOS  

---

## 6. Complexity audit (summary for next agent)

Full analysis was done by a plan agent. Core message:

1. **Capability-gate** optional macOS features (mostly done).  
2. **Privilege + paths single boundary** (mostly done; keep enforcing).  
3. **Frontend wizard slimdown** (preview removed; full step split still open).  
4. **Do not rewrite** auth, QMP, reconnect, cloud-init, HVF linger workarounds.

Quick wins still available:

- Audit/remove unused HMP `-monitor` socket if nothing uses it  
- Any remaining direct `HelperXPCClient` call sites outside PrivilegeService  
- README multi-platform blurb (done on post-merge docs PR)  

---

## 7. Orb / Linux recipes

### Machine

```bash
orb list
# barkvisor-u24 = Ubuntu 24.04 arm64; bare metal may be Ubuntu 26.04+
# Any Ubuntu: ./scripts/install-swift-linux.sh + SONAME compat
```

### Build + run

```bash
orb -m barkvisor-u24
./scripts/install-swift-linux.sh
# shellcheck source=scripts/lib/linux-swift-compat.sh
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
cd /Users/pascal/orca/workspaces/barkvisor/<worktree>   # or main clone
swift build --product BarkVisorApp
export BARKVISOR_PORT=7777
export BARKVISOR_DATA_DIR=/tmp/barkvisor-dev
./.build/debug/BarkVisorApp
# curl http://127.0.0.1:7777/api/health
# curl http://127.0.0.1:7777/api/system/capabilities
```

### Smoke script (on main)

```bash
./scripts/linux-smoke.sh
```

Builds BarkVisorApp, starts briefly, checks `/api/health` and `/api/system/capabilities`.  
Guest boot smoke is a separate follow-up (not on main until a guest-boot PR lands).

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
1. Start from origin/main (stack #7–#13 is merged)
2. Implement guest boot / NAT smoke (M2) — highest product value
3. Or pick a follow-up theme PR: createvm split, privilege/monitor,
   system split, platform path tables
4. Update this handoff when milestones move
```

---

## 10. User preferences (from this project)

- Work in **worktrees**, small PRs (stacked only when dependent)  
- Prefer **Grok/parallel agents** for independent chunks  
- **Linux NAT MVP first**, not full macOS parity  
- Use **Orb** for real Linux verification  
- Keep **draft PRs** for review before merge when useful  
- Avoid expanding scope into bridge/USB/updates until M2 is done  

---

*End of handoff. Prefer extending this file over scattering status in chat.*

---

## Phase A (post-merge stack)

Open / merged follow-ups for **usable Linux**:

- Real guest: `scripts/linux-real-guest-smoke.sh` (Ubuntu 24.04 arm64 cloud image + cloud-init + SSH)
- SPA: `scripts/linux-frontend-serve.sh --verify` / `--install-dev`
- Always verify on Orb `barkvisor-u24` (TCG) and KVM hosts when available
- Default cloud image: Ubuntu noble minimal arm64 (see getting-started-linux.md)
