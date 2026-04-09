# Code Review — BarkVisor (whole project)

## 1. Overview

BarkVisor is a native macOS menu-bar QEMU VM manager with a Swift/Vapor backend, GRDB/SQLite persistence, an NSXPC privileged helper for socket_vmnet bridges and software updates, and a Vue 3 + Vite frontend. The project is well-structured into five SPM targets (`BarkVisorHelperProtocol`, `BarkVisorHelper`, `BarkVisorCore`, `BarkVisor`, `BarkVisorApp`) with 104 Swift files across ~14k LoC, plus a 54-file frontend and ~4.7k LoC of Swift unit tests + 2.7k LoC of Cypress E2E tests.

Overall the architecture is thoughtful: domain logic lives in `BarkVisorCore` with no Vapor dependency, the Vapor-specific layer is cleanly separated, and the XPC helper keeps privileged operations out of the main process. Error handling, structured logging, and audit trails are consistent throughout. But there are several real issues — some of them significant — that I'd want fixed before treating this as production-ready.

---

## 2. Critical issues (fix before merging)

### 2.1 Test suite does not compile from a clean state
`swift test` produces multiple hard errors:

- `Tests/BarkVisorTests/DatabaseMigrationTests.swift:10`, `NetworkServiceTests.swift:16`, `ImageServiceTests.swift:16`, `ModelDBRoundTripTests.swift:13`, `VMLifecycleRecoveryTests.swift:16` — all reference `M002_AddUSBDevices` which was consolidated into `M001_CreateSchema` but never removed from the tests.
- `Tests/BarkVisorTests/HelperHandlerTests.swift:273` (`StrictTestHandler`), `:527` (`MinimalHandler`), and `HelperXPCTests.swift:5` (`TestHelperHandler`) fail protocol conformance because `installUpdate` was added to `HelperProtocol` (`Sources/BarkVisorHelperProtocol/HelperProtocol.swift:53-57`) but the test stubs weren't updated.
- `Tests/BarkVisorTests/LogServiceTests.swift:41,47,81` reference `LogCategory.api` which doesn't exist — actual cases are `app, server, vm, auth, images, metrics, audit, sync` (`BarkVisorCore/Services/LogService.swift:36`).

The PR description claims "all 4 new test suites should pass". When `swift test --skip-build` is run against a stale cached binary it prints "333 tests passed", which is misleading — a clean build fails. This must be fixed before the PR can be trusted.

### 2.2 Arbitrary PKG install via authenticated API
`Sources/BarkVisor/Server/Controllers/UpdateController.swift:65-91` accepts `pkgURL`, `checksumURL`, `version`, `changelog`, etc. directly from the request body and passes them straight to `updateService.downloadAndInstall`. Any authenticated user can point the server at any URL and trigger `HelperXPCClient.installUpdate` with the resulting file.

The privileged helper does verify the team ID (`Sources/BarkVisorHelper/HelperHandler.swift:356-370`) and notarization, so the attacker can't install arbitrary code — but they *can*:
- Downgrade to any older BarkVisor release signed by the same team ID (CVE replay).
- Install a specific vulnerable version of their choosing.
- Supply their own `checksumURL`, which means the checksum verification step provides **no** security (attacker controls both files).

The correct design is for the *server* to fetch release metadata from the canonical GitHub URL on install (using the version the client requested) — never trust URLs from the request body. At minimum, validate that `pkgURL.host` is `github.com` / `objects.githubusercontent.com` and that the version string matches a release actually listed by `checkForUpdates`.

### 2.3 XPC helper uses PID-based caller verification
`Sources/BarkVisorHelper/main.swift:25-37` verifies the XPC caller with:

```swift
let pid = connection.processIdentifier
let attrs = [kSecGuestAttributePid: pid] as CFDictionary
```

PID-based verification is vulnerable to PID reuse and process-substitution races. The well-known fix is to use the audit token via `kSecGuestAttributeAudit`:

```swift
var token = connection.auditToken  // private API accessed via KVC
let attrs = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)]
```

Since this helper runs as root and installs LaunchDaemon plists and system packages, a spoofed caller could escalate to root. Reference: "The Audit Token of Wonder" / Wojciech Regula's writeups on XPC hardening. Also, the `SecRequirement` only checks team ID — add the bundle identifier so an unrelated binary signed by the same team can't connect.

### 2.4 API-key verification runs bcrypt per request
`Sources/BarkVisor/Server/Middleware/JWTMiddleware.swift:69-77` does up to five bcrypt verifications on every authenticated request that uses an API key. Bcrypt is designed to be slow (~100–300 ms at cost factor 12), which was appropriate for the user passwords it was borrowed from — but API keys are already 256-bit random tokens, so bcrypt gives no marginal security over a fast KDF. Result:

- Every API request pays ~100s of ms of CPU.
- A handful of concurrent callers starve the server's event loop.
- The "limit to 5 candidates" mitigation acknowledges the DoS surface but doesn't solve it.

Switch to `HMAC-SHA256` (keyed on `Config.jwtSecret` or a dedicated secret) with constant-time compare. You can drop the `keyPrefix` lookup trick entirely and index on a deterministic hash column. SHA-256 per-request is microseconds instead of hundreds of milliseconds.

---

## 3. Significant issues

### 3.1 SSRF guard is purely string-based (DNS rebinding)
`Sources/BarkVisor/Server/Helpers/SSRFGuard.swift` checks the hostname **string** against known private ranges. It never resolves DNS, so:
- `http://evil.com/catalog.json` where `evil.com` resolves to `127.0.0.1` passes the check, then the HTTP client connects to loopback.
- Even without malicious DNS, a rebinding attack between the `create` validation and later `sync` calls will bypass the check entirely.

Additionally, `RepositorySyncService.sync` (`BarkVisorCore/Services/RepositorySyncService.swift:109`) doesn't re-check the URL at all — only the initial `RepositoryController.create` does. Built-in repos and any future programmatic path skip the guard.

For real SSRF protection you need to:
1. Resolve the hostname yourself and check every resolved IP against private ranges.
2. Connect to the IP directly (not the hostname) so DNS can't change between check and use, OR
3. Repeat the IP check after the HTTP client has connected (harder with URLSession).

For a single-user local tool the realistic threat is low, but if you ship this as a multi-tenant server, this is a real issue.

### 3.2 `SSRFProtectionTests` duplicates the implementation
`Tests/BarkVisorTests/SSRFProtectionTests.swift:10-40` copy-pastes the entire `isPrivateHost` function body into the test and asserts against the copy. The comment says "since `isPrivateHost` is a private instance method" — which is stale; it's now a `static` on `enum SSRFGuard` and directly callable. Tests are green even if a bug is introduced in the real function. Call `SSRFGuard.isPrivateHost(...)` directly.

The same anti-pattern appears in `HelperHandlerTests.swift` (`InterfaceValidationTests`, `VmnetPathValidationTests`, `BridgeStateCodableTests`, `StrictTestHandler`), which is partially unavoidable for cross-target testing but means the real `HelperHandler.installBridge` logic (plist generation, symlink guards, launchctl bootstrap) has **zero direct test coverage**. Consider making those helpers `internal` in a module the test target can `@testable import`, or factoring them into `BarkVisorCore`.

### 3.3 QEMU argument-injection surface
`Sources/BarkVisorCore/Services/QEMUBuilder.swift` validates `disk.path.contains(",")` on the boot disk (line 127) but does **not** check the same for:
- Cloud-init ISO path (`vm.cloudInitPath`, line 184).
- Additional disks (`extraDisk.path`, `extraDisk.format`, line 228).
- ISO paths (`isoPath`, line 168).
- The VM name passed to `-name` (`vm.name`, line 324). `validateVMName` allows spaces and dots but not commas, so this one is actually safe — but it's only safe by accident of `Validation.swift:9`.

A comma in any of those interpolated fields gets interpreted as a new QEMU key=value. For example, a cloud-init path ending in `,readonly=off` or a disk format of `qcow2,snapshot=on` would change the VM's semantics. Since paths are server-generated (based on UUIDs) this is mostly theoretical, but the `format` field comes from the database and could be set by any code path that writes to `disks` — defense-in-depth says every interpolated field should be validated at the builder boundary.

Fix: add a single `sanitizeQEMUArg(_:)` helper and call it on every interpolated value, or switch to QEMU's `-drive file=...,...` syntax using the `file.filename=` quoted form.

### 3.4 `validateSharedPath` prefix check
`QEMUBuilder.swift:76-77`:
```swift
let allowedPrefixes = [NSHomeDirectory(), "/Volumes"]
guard allowedPrefixes.contains(where: { resolved.hasPrefix($0) }) else { ... }
```
If `NSHomeDirectory()` is `/Users/foo`, then `/Users/foobar/evil` passes the `hasPrefix` check. Add a trailing slash (`root + "/"`) or compare path components. Note: `SystemController.swift:206-210` (directory browser) already got this right with the same code — just propagate the fix.

### 3.5 Cloud-init YAML is concatenated, not composed
`Sources/BarkVisorCore/Services/CloudInitService.swift:75-83` builds the final user-data by string concatenation:

```swift
var ud = "#cloud-config\n"
if !sshKeys.isEmpty {
    ud += "ssh_authorized_keys:\n" + sshKeys.map { "  - \($0)" }.joined(...) + "\n"
}
if let extra = userData { ud += extra }
```

The validation in `validateUserData` checks the user's YAML in isolation for duplicate protected keys, which is correct — but the final concatenation is fragile. Any small change in indentation or newline handling can change what cloud-init sees. Prefer composing the two documents as an actual YAML tree with Yams, then serializing:

```swift
var root: [String: Any] = userParsed as? [String: Any] ?? [:]
root["ssh_authorized_keys"] = sshKeys
let yaml = try Yams.dump(object: root)
ud = "#cloud-config\n" + yaml
```

This eliminates the entire class of "what if the user's YAML starts with a list continuation that looks like an `ssh_authorized_keys` entry" bugs.

### 3.6 `VaporServer.start` recovery drops WAL on failure
`Sources/BarkVisor/Server/VaporServer.swift:76-97`: on DB open failure it unconditionally removes `-wal` and `-shm`, restores from backup, and if no backup exists it wipes the main db. Two concerns:
1. The `-wal` file may contain **committed-but-not-checkpointed transactions** — removing it silently drops data that SQLite would have recovered on the next open. Try a plain re-open of the existing files first; only remove WAL as a last resort.
2. The "no backup" branch destroys the db with only a `Log.critical` message. Consider surfacing this to the menu bar / onboarding UI so the user isn't silently cold-started with an empty database.

---

## 4. Smaller issues / inconsistencies

- **Package.swift warns about 68 unhandled files.** The build log shows "`vmui: found 68 file(s) which are unhandled; explicitly declare them as resources or exclude from the target`" for `Sources/BarkVisor/Resources/frontend/dist/**`. This means those hashed asset filenames aren't being copied into the built binary and the backend silently won't serve them in some configurations. Either add `.copy("Resources/frontend")` to the `BarkVisor` target or `exclude` them — don't leave them dangling.
- **`Config.version = "0.0.0-dev"`** with `INJECT_VERSION` marker and `isDevBuild = true` TODO in `UpdateController.swift:20`. Both need to be wired to the release script before any update ever goes out.
- **JWT secret race at first boot.** `Config.jwtSecret` (`BarkVisorCore/Config.swift:92-123`) reads-or-generates the secret with no lock. Two concurrent `.start()` callers (or a menu-bar app + a dev run) could each generate a different 32-byte secret. Use `O_CREAT|O_EXCL` when writing.
- **`StructuredErrorMiddleware` builds JSON by string concatenation** (`ErrorMiddleware.swift:49`). The `jsonEscape` helper already uses `JSONEncoder`, so use `JSONEncoder` on the whole struct too — the fallback path is dead code.
- **`RateLimitStore.check` computes `retryAfter` incorrectly** (`RateLimitMiddleware.swift:26-27`): `oldestRelevant.timeIntervalSince(cutoff)` gives "how long the oldest entry has been in the window", which is actually the window size minus the retry time. It returns roughly `window` whenever you hit the limit, regardless of how stale the oldest attempt is. The expected value is `(oldestRelevant + window) - now`. Off-by-one tests would have caught this.
- **`ImageDownloader.performDownload`** (`ImageDownloader.swift:135-141`) iterates `asyncBytes` byte-by-byte, appending to a `Data` buffer. For multi-GB cloud images this is a hot loop and wastes CPU. Use `URLSession.downloadTask` or read larger chunks via a `URLSessionStreamTask` / raw socket — or at minimum, accumulate into a pre-allocated `UnsafeMutableRawBufferPointer`.
- **`resolveAAVMFSecureBoot`** (`QEMUBuilder.swift:427-501`) downloads an Ubuntu `.deb` over HTTPS with no checksum/signature verification. A compromised Ubuntu mirror or a corporate MITM could inject malicious firmware. Since this runs the first time a Windows VM is booted, it's a one-time risk window. Ship the `AAVMF_CODE.secboot.fd` as a bundled resource or pin a SHA-256 — downloading firmware from a third-party mirror at runtime is not a pattern that should exist in a release build.
- **`BridgeMonitor.isProcessRunning`** (`BridgeMonitor.swift:100-113`) spawns `pgrep -f` every 5 seconds from a privileged daemon. `-f` matches the entire command line, so *any* arbitrary process with `socket_vmnet.*bridged\.en0` in its argv is counted as a running bridge. A non-privileged user can create phantom "running" bridges by naming a process cleverly. Use `launchctl print system/<label>` or parse `launchctl list` instead.
- **Token storage in `localStorage`** (`frontend/src/stores/auth.ts:8`). Any XSS turns into full account takeover. For a local-network tool this is pragmatic, but worth documenting in `docs/technical-security-model.md`.
- **`router/index.ts:22-29`** parses the JWT on the client without verification and trusts `exp`. Fine for UI routing but not a security check — just note it so future readers don't treat it as one.
- **`main.ts:33-41`** posts `reportError` payloads with `stack` unbounded. The server truncates to 4096/256/128 (`LogController.swift:72-75`), so this is OK, but the comment on the client side would make the contract explicit.
- **`APIKeyService.parseExpiry`** (`APIKeyService.swift:97-106`) uses `365.25` days for `y` — fine. But it silently throws for anything other than `d`, `y`, or `never`, so legitimate `90m`, `7w`, etc. are unsupported. Minor UX issue; the frontend should match the allowed set.
- **`HelperHandlerTests.testInterfaceWithUnicode`** (`HelperHandlerTests.swift:113-116`) asserts `validateInterface("ën0")` returns `true`. macOS `ifconfig` interface names are ASCII-only, so this test is codifying behavior the OS will reject downstream. Either tighten `validateInterface` to ASCII or document the gap.
- **`LogService.setDatabase`** (`LogService.swift:88-90`) has a pre-DB ordering concern: any log written between `LogService.shared` being first accessed and `setDatabase(...)` being called is sent to `os_log` only (no persistence) — which is fine, but the fire-and-forget `Task { ... }` in `DBLogger` (`Config.swift:22-40`) can race with shutdown. Not a bug today, but worth keeping in mind.

---

## 5. Architecture & design strengths

Plenty worth keeping as-is:

- **Module boundaries are crisp.** `BarkVisorCore` having no Vapor dependency means the domain is testable in isolation and could power a CLI or menu-bar variant without HTTP.
- **Actor-based concurrency is used correctly** in `VMManager`, `ImageDownloader`, `WebSocketTicketStore`, `LogService`, `RateLimitStore`, `RepositorySyncService` — state is protected and there are no obvious races once inside an actor.
- **`VMManager.start` handles the swtpm-before-QEMU ordering carefully**, with cleanup on QEMU failure (`VMManager.swift:318-342`), poll-for-socket readiness (lines 226-234, 266-275) instead of fixed sleeps, and owner-only sockets (lines 284-289).
- **WebSocket ticket store** is the right pattern — exchange JWT for a 30-second single-use ticket via authenticated POST, pass only the ticket in the URL query string. Prevents token leakage to proxy logs / browser history. Also scopes tickets to a specific VM.
- **Audit logging and structured errors** are consistent and propagate user context (userId, username, authMethod, apiKeyId) via a neat `AuditService+Request` extension.
- **`StructuredErrorMiddleware` sanitizes paths out of error responses** via `BarkVisorError.sanitizedDescription` — good defense against path disclosure.
- **HTTP-layer response body is capped at 1 MB by default** with explicit per-route overrides for tus uploads. Good.
- **User enumeration protection in `AuthService.login`** uses a valid dummy bcrypt hash to equalize timing. The dummy `$2b$12$000...` is a valid bcrypt format, so `verify` won't short-circuit — good.
- **Directory browser** (`SystemController.browseDirectory`) gets path containment right (trailing-slash check, resolved symlinks).
- **Cypress E2E coverage** is substantial (~2.7k LoC across 11 specs) and exercises real flows end-to-end.

---

## 6. Recommended follow-ups (in priority order)

1. **Fix the test build errors** (§2.1). Remove `M002_AddUSBDevices` references, add `installUpdate` to the test stub handlers, and fix `LogCategory.api`.
2. **Lock down the update flow** (§2.2). Stop trusting `pkgURL` from the request body.
3. **Switch XPC caller verification to audit tokens + bundle ID** (§2.3).
4. **Replace bcrypt for API-key verification** with HMAC-SHA256 or a dedicated fast KDF (§2.4).
5. **Actually resolve DNS in `SSRFGuard`, or document explicitly that SSRF protection is a best-effort host-string filter** (§3.1).
6. **Add comma-sanitization to every interpolated QEMU argument** (§3.3).
7. **Compose cloud-init YAML through Yams instead of concatenating** (§3.5).
8. **Fix `RateLimitStore.check` retry-after math** (§4).
9. **Ship AAVMF firmware as a bundled resource** instead of runtime-downloading from an Ubuntu mirror (§4).
10. **Declare or exclude the frontend dist files in `Package.swift`** to silence the 68-file warning (§4).

Nothing here is fatal to the design — the foundations are solid and the module split pays dividends. But I'd want §2 cleaned up before treating the PR as merge-ready, and §3 addressed before shipping outside a controlled audience.
