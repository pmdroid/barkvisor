# Development Environment Setup

This guide is for contributors building BarkVisor from source. To use BarkVisor,
install a package using the [macOS](getting-started-installation.md),
[Linux](getting-started-linux.md), or [Windows](getting-started-windows.md) guide.

The main workflow below is for macOS. Linux and Windows commands are at the end.

**Website (landing + docs):** unified Astro app in `website/` syncs these Markdown
files into `/docs/*`. Run `bun install`, `bun run sync`, and `bun run dev` in
`website/`. Repeat the sync after editing source Markdown.

## Prerequisites (macOS)

| Requirement      | Minimum version | Notes                                   |
|------------------|-----------------|-----------------------------------------|
| macOS            | 26              | Apple Silicon required (HVF acceleration requires arm64 host for arm64 VMs) |
| Xcode / Swift    | Swift 6.3       | Local pin: `.swift-version` / `mise.toml` (currently 6.3.3). Linux CI/Docker package builds use the same **6.3.3** Ubuntu toolchains. |
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

The pkg does not ship a privileged helper. Linux still uses distro QEMU.

## Project Structure

The three main Swift targets are:

```
Package.swift
Sources/
  BarkVisorCore/             # Core library: models, services, helpers (no Vapor)
  BarkVisor/                 # Vapor HTTP layer: controllers, middleware, routes
  BarkVisorApp/              # Executable entry point (headless daemon)
Tests/
  BarkVisorTests/            # Unit and integration tests
frontend/                    # Vue 3 + TypeScript SPA (Vite)
```

### Target Dependency Graph

```
BarkVisorCore    (depends on: GRDB, JWTKit, Yams, NIO)
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
(including WebSocket upgrades) to the backend at `http://localhost:7777`.
Set `VITE_API_TARGET` to proxy to a different daemon port:

```sh
VITE_API_TARGET=http://127.0.0.1:50123 bun run dev
```

## Throwaway instances (agent-friendly)

`scripts/dev-instance.sh` boots a detached BarkVisor daemon with a fresh,
empty data directory on random free ports, provisions the admin account
headlessly, and prints one JSON line an agent can consume directly
(`mise run instance-start` works too):

```sh
scripts/dev-instance.sh start --seed
```

```json
{"name":"default","url":"http://127.0.0.1:50190","port":50190,"pid":1234,
 "dataDir":"/var/folders/…/barkvisor-dev-default.XXXX","adminUser":"admin",
 "adminPass":"dev-instance-pass","seeded":true}
```

- `--data-dir PATH` keeps state at a path you choose instead of a temp dir;
  custom paths are never deleted by `stop`.
- `--seed` fills networks, disks, an API key, and an SSH key through the real
  API so pages have content (no QEMU involved).
- Logs go to stderr; stdout stays pure JSON.

Drive the instance with the returned URL + admin credentials or the cached
token (`scripts/dev-instance.sh token`), then clean up:

```sh
scripts/dev-instance.sh stop              # kills daemon, removes temp data dir
scripts/dev-instance.sh list              # list instances
scripts/dev-instance.sh clean             # stop all registered throwaway instances
scripts/dev-instance.sh self-test         # start → provision → seed → assert → stop
```

## Environment Variables

| Variable              | Effect                                                      |
|-----------------------|-------------------------------------------------------------|
| `BARKVISOR_PORT` | HTTP port, default `7777` |
| `BARKVISOR_DATA_DIR` | Absolute path to an isolated data directory |
| `BARKVISOR_FRONTEND_DIR` | Absolute path to the built frontend directory |
| `BARKVISOR_LOG_DIR`   | Override the log output directory (default: `<dataDir>/logs`) |
| `BARKVISOR_LOG_LEVEL` | Minimum log level: `debug`, `info`, `warn`, `error`, `fatal` (default: `info`) |
| `BARKVISOR_JOIN_CODE` | Pairing offer on first boot only (console-local join; ignored after setup) |
| `BARKVISOR_AUTH_MODE` | Front-door auth: `secure` (default), `loopback` (this computer), or `disabled` (whole network). Wins over Settings. `loopback` trusts direct local connections only — never put a reverse proxy in front of a `loopback` instance; use `secure` there. |
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

`features/` only contains Gherkin that a mapper script runs
(`guest-boot`, `api-contract`, `cross-device`). Other behavior is covered
by Swift tests or `bun test`.

### Unit Tests

```sh
swift test
# or: mise run test        # full suite, same as CI Test
mise run linux-ci          # Glibc compile in Docker (CI Linux Build)
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
networks, settings, navigation, and logs.

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

`mise run prepush` runs lint, Swift tests, the Linux compile check, and frontend tests. **Never** add
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

`mise run prepush` runs lint, Swift tests, the Linux compile check, and frontend tests. **Never** add
this smoke to the default push gate.

Pairing redeem is LAN-only (not loopback). The host needs an RFC1918
address. After join the member daemon restarts so the agent plane presents
the Home-issued Device certificate. Missing `qemu-system-*` SKIPs start
after pair + create (exit 0). Set `ALLOW_NO_QEMU=1` to treat create-only
as the intended path.

Out of scope here: more than two Devices, auto-placement, template deploy
via proxy, UI/Cypress, first-time join only.

## Bridged networking in development

Run `mise run host-network-extra-ip` for the opt-in Linux extra-IP add/remove check. On macOS, this uses Docker. It is not part of the default push gate.

BarkVisor does not ship a privileged helper. For bridged/vmnet on macOS:

```sh
brew install socket_vmnet
```

Do not `sudo brew install`. A root Device starts socket_vmnet via launchctl.
Dev instances that are not root still need a running socket. NAT Workloads
do not need that service. `APPLE_TEAM_ID` is still required when notarizing
a release pkg, not for a helper.

## Linux development

From a source checkout:

```sh
./scripts/linux-dev.sh
source scripts/lib/linux-swift-compat.sh
barkvisor_export_swift_env
swift run BarkVisorApp
```

For an API-only source installation, `sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh`
skips copying the frontend and enables the agent service.

To run the development container:

```sh
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
```

Omit `--device /dev/kvm` to use software emulation.

## Windows packages

Build and stage the Windows payload from the repository root:

```powershell
cd frontend
bun install --frozen-lockfile
bun run build
cd ..
.\scripts\windows-swift.ps1 --% build -c release --product BarkVisorApp
.\scripts\stage-windows-payload.ps1 `
  -SourceDir .build\release `
  -FrontendDir frontend\dist `
  -OutDir build\windows-payload
```

Install it using `packaging\windows\install.ps1 -Source build\windows-payload`
from an administrator shell. See [Building releases](getting-started-building-releases.md)
for the package workflows.
