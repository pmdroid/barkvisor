# BarkVisor improvement plan (phased)

**Last updated:** 2026-07-28  
**Baseline:** `main` @ `69e4812` (through PR #13)  
**Open product stack (merge first):** PRs **#14–#23**  
**Sources:** Claude simplification audit + OpenCode GPT-5.6-sol audit  
**Process:** Orca worktrees → stacked draft PRs → review → merge with main CI green after each → Linux host smoke for Linux-touching PRs  

This plan is **what to improve next**, ordered so each phase is independently shippable and low-regret. It deliberately does **not** rewrite `VMManager`, QMP, reconnect/adoption, HVF linger workarounds, or release signing.

---

## Status snapshot

| Layer | State |
|-------|--------|
| Platform foundation + Linux NAT MVP | Merged (#7–#13) |
| Simplification stack (CreateVM split, privilege/HMP, QEMU tables, SystemController split) | Open #14–#18 |
| Phase A product (guest smoke, SPA, ops docs) | Open #19–#22 |
| Linux bridge (QEMU `-netdev bridge`) + USB (`lsusb` / `usb-host`) | Open #23 |
| Post-stack cleanup | **This document** |

---

## Phase 0 — Land the open stack

**Goal:** One green `main` that already includes guest proof, SPA path, bridge, and USB — before any structural cleanup.

| Order | PR | Theme |
|------:|----|--------|
| 1 | #14 | Post-merge docs / multi-platform README |
| 2 | #15 | CreateVMDrawer step split |
| 3 | #16 | Drop HMP monitor; privilege boundary |
| 4 | #17 | Platform QEMU firmware/accel tables |
| 5 | #18 | SystemController split |
| 6 | #19 | Linux NAT guest-boot smoke + SPA serve path |
| 7 | #20 | Real cloud-image guest smoke (cloud-init + SSH) |
| 8 | #21 | SPA first-class Linux serve (`--verify`, `--install-dev`) |
| 9 | #22 | Phase A Linux ops docs |
| 10 | #23 | Linux QEMU bridge + USB |

**Rules**

- Merge bottom → top; restack only if needed; wait for CI green after each merge.
- Re-verify Linux on Orb after #19–#23 (guest SSH, SPA serve, optional bridge/USB).
- **Do not** start Phase 1–4 refactors that re-touch the same files until this stack is on `main` (exception: Phase 1a bridge-name fix if #23 is still open and blocked by validation).

**Exit criteria**

- `main` includes #14–#23.
- `linux-smoke` / real-guest smoke / SPA path documented and runnable on Orb.
- macOS HVF + socket_vmnet still green in CI.

---

## Phase 1 — Correctness & cheap deletes (1–2 days)

**Goal:** Fix live defects and delete pure noise. No architecture changes.

### 1a. Bridge name validation (correctness — ship first)

| | |
|---|---|
| **Why** | `validateBridgeName` is alphanumeric-only; real Linux names (`br-lan`, Docker `br-<hash>`, `ovs-br0`) fail before QEMU runs. Blocks usable bridge parity. |
| **Do** | Allow `[A-Za-z0-9._-]`, max 15 bytes (`IFNAMSIZ-1`); reject `/`, whitespace, NUL. Dedupe `validateMAC` / IPv4 helpers into `Validation.swift`. |
| **Tests** | Accept `br-lan`, `br-0`, `br_0`, `virbr0`, `ovs-br0`; reject spaces, shell metacharacters, 16+ char names. |
| **Size / risk** | S / low |
| **Depends** | With or immediately after #23 |

### 1b. Frontend deterministic operations

| | |
|---|---|
| **Why** | Artificial `setTimeout(..., 400)` on delete/detach/resize/update adds latency and hides real server state. |
| **Do** | Remove delays; loading UI follows API/task completion. Add `apiErrorMessage(error, fallback)` next to the API client; replace repeated `e.response?.data?.reason \|\| e.message`. Switch `scripts/build-frontend.sh` to Bun (one toolchain). |
| **Tests** | Frontend typecheck/build + Cypress; buttons still prevent double-submit. |
| **Size / risk** | S / low |
| **Depends** | After #15 / frontend stack to avoid conflicts |

### 1c. Dead code sweep

| | |
|---|---|
| **Why** | ~120 lines of unreferenced public symbols; free clarity. |
| **Do** | Delete verified-dead symbols (e.g. unused `QEMUBuilder.isARM64` / `.isX86`, `VMManager.vmList()`, `QMPClient.waitForEvent`, dead template TPM branch, etc.). Keep intentional compatibility shims. |
| **Size / risk** | S / near zero |
| **Depends** | After #16 (HMP already gone) |

### 1d. Linux CI: run tests

| | |
|---|---|
| **Why** | `linux-build` only `swift build`s. Linux-only paths (`LinuxPrivilegeService`, `parseLsusbLine`, `LinuxHostNetwork`, …) never execute in CI. |
| **Do** | Add `swift test` to the Linux job. Fix or `@Suite(.disabled("reason"))` failures with an explicit reason — no silent skips. Optionally wire cheap `linux-smoke.sh`; leave hardware-dependent scripts under `scripts/manual/`. |
| **Size / risk** | S / low (may surface real failures — desired) |
| **Depends** | Best after #23 so new Linux tests run |

**Phase 1 exit criteria**

- Real bridge names accepted on Linux path.
- No artificial UI delays; one API error helper; Bun frontend build script.
- Dead symbols removed.
- Linux CI runs unit tests (green or deliberately disabled with reason).

---

## Phase 2 — Platform & host feature boundaries (3–5 days)

**Goal:** One honest answer per host question after Linux bridge/USB exist.

### 2a. Capability vs managed-daemon split

| | |
|---|---|
| **Why** | After #23, “bridged networking supported” is true on Linux, but XPC install/start/stop/sync is macOS-only. One boolean must not gate both. |
| **Do** | Keep product flag `PlatformCapabilities.supportsBridgedNetworking`. Add explicit managed lifecycle (e.g. `supportsManagedBridgeDaemon`) or macOS-only service methods. Network create/start → product capability; setup/bridge daemon routes → managed only. Same pattern for USB listing vs any privileged helper path. Rename misleading locals (e.g. `useBridged` → `needsSocketVmnetWrap`). |
| **Acceptance** | Linux reaches `-netdev bridge` without XPC; Linux management routes do not claim daemon lifecycle; macOS socket_vmnet unchanged; NAT unchanged. |
| **Size / risk** | M / medium |
| **Depends** | Hard on #23 |

### 2b. Single platform-capability table

| | |
|---|---|
| **Why** | Four mechanisms answer “what can this host do”: `PlatformCapabilities`, PrivilegeService aliases, `QEMUBuilder.accelerator` vs capabilities accelerator, `uname` vs `#if arch`. Plus scattered “not supported on Linux” strings. |
| **Do** | Call `PlatformCapabilities` directly (drop aliases). One accelerator definition including **TCG** fallback. One `unsupported(.feature)` error factory with platform-correct remediation. One `hostArchitecture()` implementation. |
| **Risk** | Keep three-way `hvf` / `kvm` / `tcg`; capabilities API must not lie without KVM. |
| **Size / risk** | M / low–medium |
| **Depends** | After #17, #20, #23 |

### 2c. Setup / System host & bridge endpoints

| | |
|---|---|
| **Why** | `listInterfaces` / install-bridge paths are duplicated between Setup and System; DTOs differ by name only. |
| **Do** | Shared Core query + provisioning helpers; Setup keeps only setup-complete guard and swallow-already-exists. Improve Linux interface display labels (`lo`, `br0`, `docker0`, …). |
| **Size / risk** | S / low |
| **Depends** | After #18 |

### 2d. Interface-exists consistency (Linux)

| | |
|---|---|
| **Why** | sysfs vs `getifaddrs` disagree on down/unaddressed interfaces — bridge install can pass one check and fail the other. |
| **Do** | One definition of “interface exists” used by validation and privilege paths; document whether down-without-IP counts. |
| **Size / risk** | S / medium (behavior) |
| **Depends** | After #23 |

**Phase 2 exit criteria**

- UI and API never claim Linux has a managed bridge daemon.
- No remaining “not supported on Linux” lies for bridge/USB when supported.
- Bridge/USB create and list work with one capability model on Orb.

---

## Phase 3 — Runtime & data-model consolidation (1–2 weeks)

**Goal:** Single owners for paths, sockets, guest identity, and JSON config — without schema migrations.

### 3a. `VMSockets` owns all VM socket paths

| | |
|---|---|
| **Why** | Paths built in ~6 places; string surgery for `-evt` / `-ga`; event + guest-agent sockets skip chmod and stale cleanup while cleanup lists know them. Highest structural ROI in Core. |
| **Do** | Extend `VMSockets` with `event` + `guestAgent` + `all`. Thread through QEMU context, process monitor, metrics. Delete `replacingOccurrences` derivations. |
| **Tests** | Exact filenames for a fixed UUID (protects reconnect/adoption). |
| **Size / risk** | S–M / low if suffixes stay byte-identical |
| **Depends** | After #16 |

### 3b. Typed accessors for VM JSON columns

| | |
|---|---|
| **Why** | `isoIds`, disks, shared paths, port forwards, USB decoded ad hoc with silent empty-on-error. |
| **Do** | Narrow typed get/set on `VM` via `JSONColumnCoding`; one error policy (log+empty vs throw). No column/schema change. |
| **Size / risk** | M / low–medium |
| **Depends** | After #23 (USB shape stable) |

### 3c. Canonical guest profile table

| | |
|---|---|
| **Why** | Guest kinds/arches are stringly typed across QEMU, lifecycle, controllers, and TypeScript; API/UI can disagree with backend aliases. |
| **Do** | One `GuestProfile` / type map: persisted ID → arch, QEMU binary, machine, firmware, OS family. Backend validates from it; expose supported types via capabilities or small endpoint. **Stable persisted IDs.** |
| **Size / risk** | M / medium |
| **Depends** | After #17, #20; recheck after #23 |

### 3d. Template deploy → real create path

| | |
|---|---|
| **Why** | Second VM-create implementation: sync disk clone in the HTTP request, drops USB/display/shared paths, dead TPM branch, third copy of bridge auto-create. |
| **Do** | Template service builds params → `VMLifecycleService.createVM` (async task). Frontend already knows `taskID` polling. **Server + SPA together** (200 → 202). |
| **Size / risk** | M–L / medium |
| **Depends** | After stack merge; own PR |

### 3e. Short-lived process helper

| | |
|---|---|
| **Why** | `Process` + pipes + exit handling repeated (disk, cloud-init, diagnostics, lsusb, …). |
| **Do** | `PlatformProcess.run(...) -> CommandResult` for bounded sync commands only. **Not** for QEMU, swtpm, streaming, QMP. |
| **Size / risk** | M / medium (pipe deadlock risk) |
| **Depends** | After #23 for final lsusb shape |

**Phase 3 exit criteria**

- One socket path owner; reconnect still adopts running VMs.
- JSON columns read through accessors in new code paths.
- Template deploy uses the same create pipeline as the wizard.
- Guest type support is table-driven end-to-end for supported arches.

---

## Phase 4 — Frontend & script maintainability (parallel-friendly)

**Goal:** Less duplicated realtime and smoke glue; no Pinia rewrite.

### 4a. Ticketed EventSource composable

| | |
|---|---|
| **Why** | ~8 EventSource sites; ticket reuse bug on native retry; duplicated backoff. |
| **Do** | `useTicketedEventSource` / `useEventStream` + thin `useImageProgress`. Migrate one stream first, then the rest. Leave WebSocket console/VNC alone. |
| **Size / risk** | M / medium (timing/teardown) |
| **Depends** | After #15 / SPA PRs |

### 4b. Shared network/disk ownership (narrow)

| | |
|---|---|
| **Why** | Networks/disks fetched independently in many views → stale copies. |
| **Do** | Small network + disk stores (or typed API modules); reuse image store. No generic CRUD factory. |
| **Size / risk** | M / low–medium |
| **Depends** | After #15, #23 UI |

### 4c. SSE / JSON response helpers (backend)

| | |
|---|---|
| **Why** | `VMController.stateStream` hand-rolls SSE; 202 JSON responses manual in several controllers. |
| **Do** | Keepalive option on `SSEResponse.stream`; one `Response.json(_:status:)`. |
| **Size / risk** | S / very low |
| **Depends** | Soft |

### 4d. Linux smoke common library

| | |
|---|---|
| **Why** | Guest/SPA/server smokes repeat start, wait, auth, cleanup, failure logs. |
| **Do** | `scripts/lib/linux-smoke-common.sh`; keep separate entry points (fast server vs real guest). Optional bridge/USB probes stay explicit. SPA verify uses canonical Bun build. |
| **Size / risk** | S–M / low |
| **Depends** | After #19–#22 merged |

**Phase 4 exit criteria**

- Image progress + logs/metrics streams share one ticketed helper.
- Smoke scripts share lib; entry points still clear about depth of proof.

---

## Phase 5 — Packaging & product polish

**Goal:** Linux install/run feels finished; not required for simplification ROI.

| Item | Notes | Status |
|------|--------|--------|
| Dockerfile multi-stage reliability | Bun SPA + Swift build + `/usr/local` layout | **This phase** |
| `install-linux.sh` + systemd dry-run on Orb | `DRY_RUN=1`, SPA → share, `EnvironmentFile` | **This phase** |
| Bridge-sync interval | macOS managed daemon **15s**; Linux does not schedule sysfs poll | **This phase** |
| In-app Linux updates | **Out of scope** until packaging is stable | — |
| Building QEMU from source for Linux | **Out of scope** | — |
| Splitting `build-release.sh` for line count | Only if a step has a real reuse/test boundary | — |

---

## Explicit non-goals (all phases)

| Do not | Why |
|--------|-----|
| Rewrite `VMManager` / actor DI graph | Tightly coupled lifecycle; high regression risk |
| Merge Core + HTTP targets | Load-bearing for Linux `BarkVisorApp` |
| Collapse QMP command + event sockets | Different lifetimes |
| Share one command path for Linux bridge + macOS socket_vmnet | Different lifecycle/permissions |
| Route Linux USB through XPC | Platform-specific backends behind one DTO is enough |
| Migrate JSON columns or rename persisted type/state strings “for cleanliness” | Compatibility cost |
| Generic repository/CRUD/framework swaps | Complexity moves, does not leave |
| Weaken signing / notarization / helper validation | Security surface |
| Second rewrite of `CreateVMDrawer` / `VMDetailView` while stack lands | Conflict tax |

---

## Suggested PR sequence (after Phase 0)

Ship as stacked draft PRs; each independently revertible.

| # | PR title (draft) | Phase | Size |
|--:|------------------|-------|------|
| 1 | `fix: allow realistic Linux bridge names + validator dedup` | 1a | S |
| 2 | `chore(frontend): drop artificial delays; apiErrorMessage; Bun build script` | 1b | S |
| 3 | `chore: remove unused Core/API symbols` | 1c | S |
| 4 | `ci: run swift test on Linux` | 1d | S |
| 5 | `refactor: split bridged capability from managed bridge daemon` | 2a | M |
| 6 | `refactor: single PlatformCapabilities surface (+ TCG, unsupported errors)` | 2b | M |
| 7 | `refactor: shared host interface + bridge provisioning helpers` | 2c–2d | S–M |
| 8 | `refactor: VMSockets owns all VM socket paths` | 3a | S–M |
| 9 | `refactor: typed VM JSON column accessors` | 3b | M |
| 10 | `refactor: ticketed EventSource composable` | 4a | M |
| 11 | `refactor: template deploy via VMLifecycleService` | 3d | M |
| 12 | `refactor: guest profile table + capabilities exposure` | 3c | M |
| 13 | `chore: linux smoke common lib + process run helper` | 3e + 4d | M |

Order within the table is preferred; 3b/3c/3d/4a can swap based on product pressure (e.g. multi-arch → guest profile sooner).

---

## Working agreements

1. **Worktrees** under Orca (`/Users/pascal/orca/workspaces/barkvisor/…`); no drive-by edits on unrelated branches.
2. **Draft PRs for review** — do not auto-merge.
3. **Main green after every merge.**
4. **Linux-touching PRs** → Linux host proof (`linux-smoke.sh` / guest smoke as relevant).
5. **macOS-touching PRs** → preserve HVF, socket_vmnet, helper/XPC behavior.
6. Prefer **deletes and single owners** over new frameworks.
7. Re-read the dual audit reports if prioritization is contested:
   - `…/simplify-audit-claude/docs/simplification-audit-claude.md`
   - `…/simplify-audit-opencode-kimi/docs/simplification-audit-opencode-gpt56-sol.md`

---

## One-page phase map

```
Phase 0  Merge #14–#23 (product stack)
    │
Phase 1  Correctness + deletes
    │    bridge names · UI delays · dead code · Linux swift test
    │
Phase 2  Host truth
    │    capability vs daemon · one capability table · shared host/bridge helpers
    │
Phase 3  Runtime truth
    │    VMSockets · JSON accessors · guest profiles · template→lifecycle · Process helper
    │
Phase 4  UI/script glue
    │    EventSource · network/disk stores · SSE helpers · smoke common
    │
Phase 5  Packaging polish (later)
```

**Start here after Phase 0:** Phase **1a** (bridge names), then **1b–1d**, then **2a**.
