# BarkVisor Console

Native SwiftUI console for macOS 14+ and iOS 26+. It talks to an existing BarkVisor Device over the same HTTP API as `frontend/src` — there is no second protocol.

The UI is stock SwiftUI: `NavigationSplitView` on Mac, a three-tab `TabView` (Home / Devices / Settings) on iOS, grouped `Form` / `List`, system colors, and the system accent. It follows light and dark appearance. There is no custom BarkVisor theme.

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
4. Sign in with the same admin user as the web UI.

JWT is stored in the Keychain. The Device URL is stored in UserDefaults.

If the Device returns `503 setup_required`, the app tells you to finish first-run setup in the web UI (`/setup`). It does not reimplement SetupView.

## Screens

| Screen | What it does |
| --- | --- |
| Connect | Device URL |
| Sign in | `POST /api/auth/login` |
| Home (iOS) | Union of workloads on reachable Devices; a row pushes native Workload detail |
| Dashboard (Mac) | Counts, selected Device, recent workloads (each opens Workload detail) |
| Devices | `GET /api/home/devices/health` (reachable / unreachable) |
| Workloads (Mac) | List for the selected Device; a row pushes Workload detail |
| Workload detail | Name, Device, state/health, guest OS/IP when known, start / ACPI stop / force stop. Console and Display rows exist (placeholders this slice; member stays disabled until PAS-200) |
| Library / Disks / Networks / Logs | Read-only lists from the Device APIs |
| Settings | URL, logout, about (`/api/system/about`), Add Device pairing code |

Remote Device APIs go through `/api/home/devices/{id}/v1/...`. The connected Device (`role=self`) uses `/api/...` directly.

Home and Mac Workload rows push a SwiftUI Workload detail. They do not open Safari. Console and Display destinations exist as empty placeholders for the next slice. Member Console / Display stay disabled until PAS-200.

## Tests

`APIDecodingTests` covers Home device health JSON, workload `memoryMB` / health dual-read, the error envelope, and Device URL normalization.

`WorkloadDetailTests` covers guest-info OS/IP decode, vmType fallback, and member Console/Display staying closed.
