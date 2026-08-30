# BarkVisor Console

Native SwiftUI console for macOS 14+ and iOS 26+. It talks to an existing BarkVisor Device over the same HTTP API as `frontend/src` — there is no second protocol.

The UI is stock SwiftUI: `NavigationSplitView` on Mac, a five-tab `TabView` (Home / Library / Ollama / Devices / Settings) on iOS, grouped `Form` / `List`, system colors, and the system accent. It follows light and dark appearance. There is no custom BarkVisor theme.

Product words in the UI: **Home**, **Device**, **Workload**, **Library**.

## Open

1. Open `Apps/BarkVisorConsole/BarkVisorConsole.xcodeproj` in Xcode 26 or later.
2. Choose the **BarkVisorConsole** scheme.
3. Destination: **My Mac**, or an **iOS Simulator** (iPhone / iPad).

From the repo root:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project Apps/BarkVisorConsole/BarkVisorConsole.xcodeproj \
  -scheme BarkVisorConsole \
  -destination 'platform=macOS' \
  build

xcodebuild -project Apps/BarkVisorConsole/BarkVisorConsole.xcodeproj \
  -scheme BarkVisorConsole \
  -destination 'platform=macOS' \
  test
```

## Point it at a Device

1. Run BarkVisor so the HTTP API is on port **7777**.
2. Launch the console.
3. Enter the Device URL (default `http://192.168.30.1:7777`). A web `/login` URL is accepted and stripped to the origin.
4. Sign in with the same admin user as the web UI (**password** or **passkey** when the URL uses a hostname — not a raw IP), or scan a sign-in QR from Settings on that Device (`barkvisor://login/v1?…`). That URI is not a pairing offer.

JWT and the refresh token are stored in the Keychain. The Device URL is stored in UserDefaults. An expired JWT is refreshed on launch; changing the Device origin drops both tokens.

If the Device returns `503 setup_required`, the app tells you to finish first-run setup in the web UI (`/setup`). It does not reimplement SetupView.

## Screens

| Screen | What it does |
| --- | --- |
| Connect | Device URL |
| Sign in | `POST /api/auth/login` or scan `barkvisor://login/v1` (`POST /api/auth/login-offers/redeem`) |
| Home (iOS) | Union of workloads on reachable Devices; a row pushes native Workload detail. Swipe and context menu Start / ACPI Stop use the same Device or Home-proxy APIs as detail. Force Stop stays on detail. Library is its own tab. |
| Dashboard (Mac) | Counts, selected Device, recent workloads (each opens Workload detail) |
| Devices | `GET /api/home/devices/health` (reachable / unreachable) |
| Workloads (Mac) | List for the selected Device; a row pushes Workload detail. Same Start / ACPI Stop swipe and context menu as Home. |
| Workload detail | Name, Device, state/health, guest OS/IP when known, start / ACPI stop / force stop / ACPI restart. Console and Display open on This Device or a reachable member while the Workload is running or stopping |
| Console | Serial via SwiftTerm + `URLSessionWebSocketTask`. This Device: `POST /api/auth/ws-ticket` then `/api/vms/{id}/console?ticket=`. Member: mint ticket on the Device, then Home tunnel `/api/home/devices/{id}/v1/vms/{id}/console?ticket=&session=`. |
| Display | VNC via bundled noVNC 1.6.0 in `WKWebView`. Same ticket + path mapping as Console (`/vnc`). Pinch/pan, pointer, on-screen keyboard, Ctrl+Alt+Del. |
| Library / Disks / Networks / Logs | Library lists images on the Device, downloads from the image catalog (`POST /api/repositories/images/{id}/download`), and can create a Workload from a ready image. Disks, Networks, and Logs stay read-only. Depot path stays in the web UI. On iOS they are not tabs: Device detail pushes them onto the navigation stack. |
| Device detail | Version, platform, arch, accelerator, uptime, and GPU passthrough readiness for that Device. Self uses `/api/system/about` and capabilities; members use `/api/home/devices/{id}/v1/system/...`. Unreachable members keep the unknown copy. |
| Settings | URL, logout, Add Device pairing code, API keys (`GET/POST/DELETE /api/auth/keys`: list, mint inference-by-default, show-once secret, revoke). Admin-only; 403 is an inline banner. On Mac, issue a phone sign-in QR (`POST /api/auth/login-offers`). Changing origin signs you out. |

Remote Device APIs go through `/api/home/devices/{id}/v1/...`. The connected Device (`role=self`) uses `/api/...` directly.

Home and Mac Workload rows push a SwiftUI Workload detail. They do not open Safari. Start and ACPI Stop from the list (and Console / Display from detail) match the Home web UI on This Device and on a reachable member. Force Stop stays on detail with a confirm. **Create on iOS** opens the same three-step magazine wizard as the web UI (Gallery → Configure → Disk): Home templates via `POST /templates/deploy`, Windows/custom/coding-agent via `POST /vms`, SSH keys for cloud-init, size presets, NAT/bridged network, guest static IP, new or existing disk. Mac keeps the compact sheet. Hardware extras stay in the web UI. The session JWT is never placed in a stream URL, log, or the VNC web view — only the one-use ticket (and Home `session=` on a member tunnel) enters the web view.

## Tests

`CreateWorkloadTests` covers ready-image gating, guest type from the image arch, default CPU/RAM/disk (clamped to a provided host CPU count, never this Mac’s `cpuCount`), ISO vs cloud-image POST bodies, 202 `{ taskID, vm }` decode, and member create via the Home proxy.

`APIDecodingTests` covers Home device health JSON, workload `memoryMB` / health dual-read, the error envelope, Device URL normalization, API key list/create DTOs (no list secret, `/api/auth/keys`), and a Keychain round-trip of a minted secret that does not touch the session JWT.

`WorkloadDetailTests` covers guest-info OS/IP decode, vmType fallback, and Console/Display opening on a reachable member the same as This Device.

`LocalStreamTests` covers live-state gating, member-stream lockout, reconnect backoff (≤10), VNC control scripts, and ticket-only WebSocket URLs (JWT never in the URL).

`ChatTests` covers Home catalog decode, hiding Chat with no Ollama models, OpenAI SSE token drain, `stream: true` on `/v1/chat/completions`, and a one-shot 401 retry on the chat stream.
