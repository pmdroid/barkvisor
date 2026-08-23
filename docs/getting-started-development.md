# Development Environment Setup

This guide covers building and running BarkVisor from source for local
development on **macOS**. For **Linux**, see
**[Installation (Linux)](getting-started-linux.md#building-from-source-optional)**
and run `./scripts/linux-dev.sh` for packages + Swift and smoke setup.

**Website (landing + docs):** unified Astro app in `website/` syncs these Markdown
files into `/docs/*` (`cd website && bun install && bun run dev`).

## Prerequisites (macOS)

| Requirement      | Minimum version | Notes                                   |
|------------------|-----------------|-----------------------------------------|
| macOS            | 26              | Apple Silicon required (HVF acceleration requires arm64 host for arm64 VMs) |
| Xcode / Swift    | Swift 6.x       | Local pin: `.swift-version` / `mise.toml` (currently 6.3). Linux CI/Docker package builds use **6.2.3** Ubuntu toolchains — keep that in mind for release binaries. |
| Bun              | Latest           | JavaScript runtime for the frontend     |
| Homebrew         | Latest           | For installing build and runtime deps   |
| mise (optional)  | Latest           | Toolchain + tasks (`mise run build|test|lint`) |

## Installing Build Dependencies

```sh
brew install swiftlint swiftformat
```

- **SwiftLint** -- enforces code style rules (see `.swiftlint.yml`).
- **SwiftFormat** -- auto-formats Swift source (see `.swiftformat`).

## Installing Runtime Dependencies

```sh
brew install qemu swtpm socket_vmnet
```

- **qemu** -- `qemu-system-aarch64` and associated firmware/resources.
- **swtpm** -- Software TPM emulator (required for Windows VMs with TPM
  enabled).
- **socket_vmnet** -- Bridged / vmnet-based networking (optional; NAT works
  without it).

### How BundleResolver Finds Binaries

macOS (PAS-287): Homebrew first. The pkg does not bundle QEMU or `socket_vmnet`.

1. `/opt/homebrew/bin/<name>` (Apple Silicon Homebrew)
2. `/usr/local/bin/<name>` (Intel Homebrew)
3. Leftover `{prefix}/libexec/barkvisor/<name>` if an old pkg left one
4. `$PATH` via `which`

For Homebrew opt-prefix packages (e.g. `socket_vmnet`):

1. `/opt/homebrew/opt/<package>/bin/<name>`
2. `/usr/local/opt/<package>/bin/<name>`
3. Leftover `{prefix}/libexec/barkvisor/<name>`

QEMU resources (`-L` data dir, firmware, keymaps):

1. `/opt/homebrew/share/qemu/<name>`
2. `/usr/local/share/qemu/<name>`
3. Leftover `{prefix}/share/barkvisor/qemu/<name>`

The privileged XPC helper is still installed by the pkg. Linux still uses distro QEMU.

## Project Structure

The project is organized as 5 Swift Package Manager targets:

```
Package.swift
Sources/
  BarkVisorHelperProtocol/   # Shared XPC protocol between app and helper
  BarkVisorHelper/           # Privileged helper (bridge/vmnet management)
  BarkVisorCore/             # Core library: models, services, helpers (no Vapor)
  BarkVisor/                 # Vapor HTTP layer: controllers, middleware, routes
  BarkVisorApp/              # Executable entry point (headless daemon)
Tests/
  BarkVisorTests/            # Unit and integration tests
frontend/                    # Vue 3 + TypeScript SPA (Vite)
```

### Target Dependency Graph

```
BarkVisorHelperProtocol
    |
    +-- BarkVisorHelper  (executable -- privileged helper daemon)
    |
    +-- BarkVisorCore    (depends on: GRDB, JWTKit, Yams, NIO)
            |
            +-- BarkVisor  (depends on: Vapor)
                    |
                    +-- BarkVisorApp  (executable -- headless daemon)
```

### Key Dependencies

| Package         | Purpose                                |
|-----------------|----------------------------------------|
| Vapor 4.99+     | HTTP server, WebSocket, routing        |
| GRDB 7.0+       | SQLite database (via `DatabasePool`)   |
| JWTKit 5.0+     | JWT authentication                     |
| Yams 5.0+       | YAML parsing (cloud-init user data)    |
| swift-nio 2.65+ | Async networking (VNC/console proxy)   |

## Building

### Swift Backend

```sh
swift build
# or: mise run build   # release mode, see mise.toml
```

### Frontend

```sh
cd frontend
bun install
bun run build    # production build (runs vue-tsc then vite build)
```

The production build output goes into `frontend/dist/` and is served by the
Vapor backend as a static SPA (with `SPAFallbackMiddleware`).

## Running

### Backend

```sh
swift run BarkVisorApp
```

This starts the headless server daemon, which launches the Vapor HTTP server on
`0.0.0.0:7777`. Open `http://localhost:7777` in a browser.

On first run the web UI presents a setup screen where you create the admin
account. The data directory is at:

```
~/Library/Application Support/BarkVisor/
```

This contains the SQLite database (`db.sqlite`), disk images, firmware state,
logs, and cloud-init data.

### Frontend Dev Server

For frontend development with hot-reload:

```sh
cd frontend
bun install
bun run dev
```

Vite starts on `http://localhost:5173` and proxies all `/api` requests
(including WebSocket upgrades) to the backend at `http://localhost:7777`:

```ts
// vite.config.ts
server: {
  port: 5173,
  proxy: {
    '/api': {
      target: 'http://localhost:7777',
      changeOrigin: true,
      ws: true,
    },
  },
}
```

## Environment Variables

| Variable              | Effect                                                      |
|-----------------------|-------------------------------------------------------------|
| `BARKVISOR_LOG_DIR`   | Override the log output directory (default: `<dataDir>/logs`) |
| `BARKVISOR_LOG_LEVEL` | Minimum log level: `debug`, `info`, `warn`, `error`, `fatal` (default: `info`) |
| `BARKVISOR_JOIN_CODE` | Pairing offer on first boot only (console-local join; ignored after setup) |
| `DISABLE_RATE_LIMIT`  | Set to `1` to disable login rate limiting (useful for testing) |

## Code Quality

### Linting

```sh
mise run lint       # SwiftLint + SwiftFormat --lint
# or: swiftlint lint
```

SwiftLint is configured in `.swiftlint.yml`. Key settings:

- Line length warning at 150, error at 200.
- Function body length warning at 80 lines, error at 150.
- Force unwrapping and implicitly unwrapped optionals are flagged.
- `VM` is excluded from type name length rules. `id`, `db`, `vm`, `ip`, `ci`, `fd`, `n`, `i`, `s` are excluded from identifier name length rules.

### Formatting

```sh
swiftformat Sources/ Tests/              # apply formatting
swiftformat --lint Sources/ Tests/       # check only (also in mise run lint)
```

SwiftFormat is configured in `.swiftformat`. Key settings:

- 4-space indentation, max line width 150.
- Arguments and parameters wrap before-first.
- Trailing commas are always added.
- File headers are stripped.

### Combined Check

```sh
mise run lint       # suitable for CI (lint + format check)
```

## Testing

### Unit Tests

```sh
swift test
# or: mise run test
```

The test suite includes unit tests for services, models, helpers, middleware,
and controller logic. Tests are in `Tests/BarkVisorTests/`.

### Cypress E2E Tests

End-to-end tests use Cypress against a running BarkVisor instance:

```sh
cd frontend
bun run cy:open     # Interactive Cypress runner
bun run cy:run      # Headless Cypress run
bun run test:e2e    # Alias for cy:run
```

E2E specs cover authentication, dashboard, VM lifecycle, disks, images,
networks, registry, settings, navigation, and logs.

### Guest-boot BDD (opt-in, not prepush)

Gherkin in `features/guest-boot.feature` maps onto the existing smoke
scripts. A Device still boots a local Workload from SQLite if other Devices
in the Home are unreachable.

```sh
mise run api-bdd            # every documented API operation (fast; no QEMU)
mise run guest-smoke        # blank disk → running (fast; no guest OS)
mise run guest-smoke-real   # Ubuntu cloud image + cloud-init + SSH
mise run prepush-full       # prepush + api-bdd + guest-smoke (operators who opt in)
```

`mise run prepush` stays lint + Swift tests + frontend tests. **Never** add
guest-boot to the default push gate.

| Scenario | Mapper | Runtime |
|----------|--------|---------|
| a blank-disk Workload reaches running | `scripts/linux-guest-smoke.sh` | seconds–minutes |
| a Linux Workload boots from a cloud image and answers SSH | `scripts/linux-real-guest-smoke.sh` (`REAL_GUEST=1`) | **KVM/HVF: minutes; TCG: up to ~15 min** (`SSH_WAIT_SECS=900`) |

If `qemu-system-aarch64` and `qemu-system-x86_64` are both missing, the
mapper prints `SKIP: qemu-system-* is not on PATH` and exits 0. Set
`ALLOW_NO_QEMU=1` to exercise API create-only instead of skipping.

```sh
DRY_RUN=1 ./scripts/guest-boot-bdd.sh   # syntax + scenario inventory, no server
```

Optional CI lanes (never a required check) are documented in
[Guest-boot CI and the self-hosted KVM runner](ci-kvm-runner.md).

Out of scope here: Windows boot, Cypress.

### Cross-Device Home proxy smoke (opt-in, not prepush)

Gherkin in `features/cross-device.feature` maps onto
`scripts/cross-device-smoke.sh`. Two daemons on one host (two data dirs,
two HTTP ports, two agent ports) pair with a real `/api/pairing/codes` +
`/api/pairing/join` offer. Create + start a Workload on the member through
`/api/home/devices/:id/v1` and assert running from the Home proxy and on
the member locally. Each Device still owns runtime in local SQLite if the
peer is later unreachable.

```sh
mise run cross-device-smoke
DRY_RUN=1 ./scripts/cross-device-smoke.sh   # syntax + endpoint inventory, no server
```

`mise run prepush` stays lint + Swift tests + frontend tests. **Never** add
this smoke to the default push gate.

Pairing redeem is LAN-only (not loopback). The host needs an RFC1918
address. After join the member daemon restarts so the agent plane presents
the Home-issued Device certificate. Missing `qemu-system-*` SKIPs start
after pair + create (exit 0). Set `ALLOW_NO_QEMU=1` to treat create-only
as the intended path.

Out of scope here: more than two Devices, auto-placement, template deploy
via proxy, UI/Cypress, first-time join only. Guest-boot CI does not run
this smoke; see [ci-kvm-runner.md](ci-kvm-runner.md).

## Privileged Helper in Debug Builds

The XPC privileged helper (`BarkVisorHelper`) is used for operations that
require root, such as configuring bridged networking via `socket_vmnet`.

In debug builds, `kHelperTeamID` is set to `"DEVELOPMENT"` (defined in
`Sources/BarkVisorHelperProtocol/HelperProtocol.swift`). The helper skips
code-signing verification in this mode, so you do not need a real Apple
Developer Team ID during development.

For release builds, `scripts/build-release.sh` injects the real
`APPLE_TEAM_ID` via sed before compiling:

```sh
sed -e 's/kHelperTeamID = "DEVELOPMENT"/kHelperTeamID = "<TEAM_ID>"/' ...
```
