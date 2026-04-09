# Development Environment Setup

This guide covers building and running BarkVisor from source for local
development.

## Prerequisites

| Requirement      | Minimum version | Notes                                   |
|------------------|-----------------|-----------------------------------------|
| macOS            | 26              | Apple Silicon required (HVF acceleration requires arm64 host for arm64 VMs) |
| Xcode / Swift    | Swift 6.x       | Project pins Swift 6.2.3 via `.swift-version` |
| Bun              | Latest           | JavaScript runtime for the frontend     |
| Homebrew         | Latest           | For installing build and runtime deps   |

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

In a release install, binaries live in `/usr/local/libexec/barkvisor/` and
QEMU resources in `/usr/local/share/barkvisor/qemu/`. During development these
do not exist, so `BundleResolver` falls back through the following search order:

1. Installed prefix: `{prefix}/libexec/barkvisor/<name>`
2. `/opt/homebrew/bin/<name>` (Apple Silicon Homebrew)
3. `/usr/local/bin/<name>` (Intel Homebrew)
4. `$PATH` lookup via `which`

For Homebrew opt-prefix packages (e.g. `socket_vmnet`):

1. Installed prefix: `{prefix}/libexec/barkvisor/<name>`
2. `/opt/homebrew/opt/<package>/bin/<name>`
3. `/usr/local/opt/<package>/bin/<name>`

QEMU resources (`-L` data dir, firmware, keymaps) follow a similar pattern:

1. Installed prefix: `{prefix}/share/barkvisor/qemu/<name>`
2. `/opt/homebrew/share/qemu/<name>`
3. `/usr/local/share/qemu/<name>`

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
```

Or using the Makefile:

```sh
make build
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
| `DISABLE_RATE_LIMIT`  | Set to `1` to disable login rate limiting (useful for testing) |

## Code Quality

### Linting

```sh
make lint           # Run SwiftLint
```

SwiftLint is configured in `.swiftlint.yml`. Key settings:

- Line length warning at 150, error at 200.
- Function body length warning at 80 lines, error at 150.
- Force unwrapping and implicitly unwrapped optionals are flagged.
- `VM` is excluded from type name length rules. `id`, `db`, `vm`, `ip`, `ci`, `fd`, `n`, `i`, `s` are excluded from identifier name length rules.

### Formatting

```sh
make format         # Auto-format with SwiftFormat
make format-check   # Check formatting without modifying files
```

SwiftFormat is configured in `.swiftformat`. Key settings:

- 4-space indentation, max line width 150.
- Arguments and parameters wrap before-first.
- Trailing commas are always added.
- File headers are stripped.

### Combined Check

```sh
make check          # Runs lint + format-check (suitable for CI)
```

## Testing

### Unit Tests

```sh
swift test
```

Or:

```sh
make test
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
