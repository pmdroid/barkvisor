# Changelog

Release notes for BarkVisor. The [user guides](using-overview.md) describe current behavior. Older notes about intermediate implementations are preserved in the [development archive](archive/earlier-development-notes.md).

## Unreleased

- The Linux `.deb` installs on Ubuntu 26.04, where the distro renamed `libxml2` to `libxml2-16`.

## 1.0.0-alpha.9 — 2026-09-16

- Devices and other Home pages load when sign-in is off, even if a paired Device is unreachable. Alpha.8 could sit on an empty Devices list because health waited on that Device until the browser gave up.

## 1.0.0-alpha.8 — 2026-09-16

- VM status events arrive promptly, and QEMU and guest-agent command errors are reported instead of being treated as success.
- Home consoles can reach paired Devices when sign-in is disabled on the console Device.
- The Updates page treats a disappearing update task during a daemon restart as a reconnect, rather than immediately reporting failure.

## 1.0.0-alpha.7 — 2026-09-15

- Linux **Settings → Updates** can apply a `.deb` on a Device whose unit uses `ProtectSystem=strict`. VFIO udev rules ship under `/usr/local` and are copied into udev when the unit starts. Alpha.6 `.deb` unpack failed on `/usr/lib/udev/rules.d`.
- Workload class (House / Agent) is gone from Create VM and the API.

## 1.0.0-alpha.6 — 2026-09-15

- Built-in App Catalogs use `barkvisor://builtin/bigbear` and `barkvisor://builtin/linuxserver`. Settings → Repositories shows those URLs. You cannot add `barkvisor://` by hand. Existing Big Bear rows on the GitHub URL move over on upgrade.
- App Workloads have an admin exec terminal. Member hops stay connected, live output follows the active session, and docker exec gets a PTY size before the shell starts.
- Apps gallery has search and category filters. Volume and published-port editors match the Device page. App detail keeps its tab across reloads.
- Home Devices stay on the list when offline, keep their names, and can be removed.
- Sign-in can be secure, loopback-only, or disabled. The SPA boots without a login wall when auth is off. Security settings live under Settings.
- Linux packages build amd64 and arm64. The binary finds its bundled Swift runtime without `LD_LIBRARY_PATH` and ships the SwiftPM resource bundle next to it.
- macOS `.pkg` is Developer ID signed and notarized. `--skip-notarize` is for local signed builds only.

## 1.0.0-alpha.5 — 2026-09-10

- Application Workload Overview is two columns (Application / Volumes / Access | Runtime / Usage / Environment). Title row has an APP badge, Open UI, and ingress On/Off plus Prefix/Direct (`/go/<id>/`).
- Environment tab edits non-secret variables. Secrets stay redacted and are not rewritten from the form. Restart the app to apply.
- Usage panel and Dashboard Usage show Docker CPU, memory, and network I/O for running Application Workloads.
- macOS LaunchDaemon finds OrbStack `docker` and `docker compose` without the user PATH.

## 1.0.0-alpha.4 — 2026-09-09

- Windows Device: zip (arm64 and amd64), optional MSI and Windows Service, WHPX, live browser VNC. Windows guests run on a Windows Device. Apple Silicon can start Windows ARM64 guests on QEMU 11 / HVF.
- Images lists every Device in the Home, including skipped members (HTTP error, unreachable). Empty state only when every queried Device returned no images. Delete runs on the owning Device.
- Doctor checks qemu-img, ISO tooling, and QEMU device modules. 4m firmware pairing is fixed.
- Cloned boot disks must have a partition table. qcow2 clones no longer run sgdisk.
- After a pairing join, the agent reloads its mTLS identity without a restart.
- Create VM guest arch follows the pinned image. A mismatch is a blocking reason, not a silent wrong binary.
- Ollama completions through a member loopback hop keep the stream timeout.
- VFIO GPU passthrough raises systemd memlock so QEMU can pin guest RAM.
- Non-Debian hosts: portable tarball and user-prefix agent install. Guide: [Installation (Linux)](getting-started-linux.md).
- Site `og:image` URLs are absolute so X previews work.

## 0.x — single Device

The first public line is a **Home of one**: one daemon, Vue SPA on port 7777, QEMU Workloads, Library images and templates, NAT and optional bridge, console and VNC, cloud-init, SSH keys.

See [First launch](getting-started-first-launch.md), [Quickstart](getting-started-quickstart.md), and the [roadmap](roadmap.md).
