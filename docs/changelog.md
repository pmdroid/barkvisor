# Changelog

Product notes for operators. Words: **Home**, **Device**, **Workload**, **Library**. Not a cluster.

Unreleased items live on stacked draft PRs and may change before they land on `main`.

## Unreleased

- Settings: pairing offer and phone sign-in QR live on **Settings → Pairing** (`?tab=pairing`). Home keeps remote access, advertise URL, and Library depot.
- Networks **Bridge setup** is install guides only: Linux keeps the qemu-bridge-helper / host-bridge checklist; macOS shows copyable `socket_vmnet` Homebrew commands. Setup / Start / Stop / Remove no longer change the host. Daemon endpoints stay; VM-on-bridge wiring is unchanged.
- Logs: SQLITE_FULL no longer tight-loops Device stderr. Prune logs (and extra DB backups) on disk-full writes, skip the insert, and warn once. Homebrew/pkg postinstall boots out leftover privileged helper files so they cannot reconnect every 15s.
- Template **Onyx** (Lite) in `repos/templates.json`: Ubuntu 24.04, NAT `:80`, cloud-init installs Onyx Lite. Ollama URL is a deploy input (default `http://10.0.2.2:11434`). After deploy on This Device, **Open Onyx** is `http://127.0.0.1/`. SSH key picker only when the recipe declares `ssh_keys` (Pi-hole now does). In-app Chat tab is gone; completions stay on `/v1/chat/completions`.
- Settings Remote access: pick hostname / LAN / Tailscale DNS (or Other) as the advertise URL. The same host drives pairing QR `host=` and Models inference how-to (`OPENAI_BASE_URL` is saved advertise, then MagicDNS/tailnet IP, then LAN). HTTPS Tailscale Serve origins contribute hostname only; LAN stays `http://<host>:7777`. Cage URL is still `http://10.0.2.2:11434/v1`.
- Device detail (web and Console) shows that Device's version, platform, arch, accelerator, uptime, and GPU passthrough readiness. Self uses `/api/system/about` and capabilities; members go through the Home proxy. Unreachable members keep the unknown copy, with no invented numbers. Console Settings keeps Connection and the phone sign-in QR; About is no longer origin-global.
- Home hop errors no longer all say **Device is unreachable**. A connect timeout, cancel, or TLS failure is **Home cannot hop**; a member HTTP 5xx is the Device answering badly (Ollama down on that hop); HTTP 4xx on that hop is the Device rejecting the request, not Ollama down. Only a failed health probe is offline. Web and Console Device pills use those `reachability` codes (`memberHTTP` is **HTTP error**, not Unreachable). The same codes land on `/api/home/devices/health` `reachability` / `reachabilityError`.
- Ollama Models: **Export JSON** (web download and Console share sheet) is a point-in-time snapshot of `/api/ps` fields already on the catalog — `name`, `size`, `sizeVRAM`, `running`, `host`. No history table.
- Inference how-to: web and Console Models always show a **Use this API** card. LAN is Home or Device `:7777/v1/chat/completions` with `Authorization: Bearer` and an inference key (not Device `:11434`). Copy curl and `OPENAI_BASE_URL` / `OPENAI_API_KEY`. From inside a Workload the cage URL is `http://10.0.2.2:11434/v1` (slirp guestfwd). Coding Agent cloud-init writes a real inference key when a grant is supplied.
- In-app software updates are removed. Upgrade with Homebrew (`brew upgrade barkvisor`) on macOS, or your distro package on Linux. The Settings Updates tab, `/api/system/updates`, and the helper PKG installer are gone.
- macOS no longer ships a privileged XPC helper. Bridged/vmnet attaches to Homebrew `socket_vmnet` (`brew install socket_vmnet && sudo brew services start socket_vmnet`). BarkVisor does not install, start, or stop that daemon.
- Bridged start on Linux denies when `/etc/qemu/bridge.conf` is missing or unreadable (same as the Networks UI).
- GPU attach (PAS-275): Linux Devices list GPUs with their IOMMU group and attach/detach them like USB (`GET /api/system/gpu-devices`, `POST/DELETE /api/vms/{id}/gpu`). Fail closed if IOMMU/vfio/KVM is not ready. Occupancy is the host GPU driver, not an Ollama TCP probe. Detach, stop, and delete unbind vfio-pci so the host can reclaim the card. Attaching a GPU to a Coding Agent Workload rewrites cloud-init for guest Ollama at `http://127.0.0.1:11434/v1`. Vue and the native console offer attach when the Device is ready.
- GPU passthrough (PAS-274): Linux Devices probe IOMMU groups, vfio-pci, and KVM and report `gpuPassthrough` / `vfio` on capabilities. macOS always explains that GPU passthrough is unavailable.
- Coding session (PAS-273): Agent Workloads expire with a stop, not a destroy. Web and Console show a 15-minute warning, then a receipt (stopped at, last git push or **NO PUSH**) after the guest exits. Resume, Reset to Library image, and Burn. Kill and TTL stop unload the local-model grant when no other Agent session is running. Graceful Stop keeps the grant so Resume can keep using already-loaded models.
- Coding Agent (PAS-272): Agent-class Workloads on the Coding Agent image talk through Chat or Terminal in the web UI and the native console. `OPENAI_BASE_URL` is the Home Ollama grant (`http://10.0.2.2:11434/v1`). ttyd stays loopback-only.
- Chat (PAS-270): web and native console simple chat when the Home catalog has at least one Ollama model. Pick a model, POST `/v1/chat/completions` with `stream: true`, tokens append as they arrive. Hidden when Ollama is down or no model is pulled.
- RBAC (PAS-286): two Home roles, admin and inference. First user is admin. Console sessions and API tokens inherit the user role. Admin can mint an inference-only token for an Agent Workload. Inference may list models that are already there and call chat completions through the BarkVisor proxy; pull, keys, USB attach, pairing, and Device changes return 403.
- Ollama (PAS-269): if Ollama is reachable on a Device, Home shows **Ollama** for pull/start/stop and a merged catalog. Chat completions (`/v1/chat/completions`) route by model name — already-running, then the healthier Device. Inference API keys can list models and complete; they cannot pull or see the upstream Ollama key. BarkVisor does not require Ollama to install.
- Remote access (PAS-89): detect Tailscale if installed (`tailscale ip -4` / MagicDNS), advertise it on inventory and pairing/sign-in QRs, optional “require tailnet for remote Home API”, WireGuard detection only. BarkVisor does not bundle Tailscale.
- SPA inventory: Workloads, disks, networks, and logs share one Home-by-Device fetch helper (last-known when a Device is unreachable).

### Workloads list

- Running Workloads show SSH and HTTP chips from guest-info listeners. Links match Overview: bridged guest IP, This Device NAT through hostfwd, never localhost on a member, never loopback. The IP column is copyable only on bridged.

### Home of more than one Device

- Pair another Device from **Settings → Home → Add a Device**. Pick a LAN IPv4, IPv6 unique-local, or DNS name for `host=` in the offer, then scan the QR or paste the full `barkvisor://pair/v1?…` in setup, or run `barkvisor join --code` on an API-only host. Changing the address re-issues the URI and the QR. A rejected address (localhost, public, metadata) returns 400 and drops the previous pairing code.
- Join allow-list now includes CGNAT `100.64.0.0/10` (still blocks `100.100.100.200`, loopback, link-local, public, and metadata). An older joiner still rejects those offers — upgrade it or pick a LAN IP.
- Optional `BARKVISOR_JOIN_CODE` on first boot. Join is always console-local on that Device.
- Devices share one Home login. The dashboard lists every Device and health.
- Create, start, and stop Workloads on a picked Device through the Home proxy (`:7777`). The browser or phone does not open member IPs. Agent traffic uses mTLS on `:7778`.
- Recommended Device is a suggestion. You can place a Workload on any reachable Device.
- A Device still runs if peers are down. Local SQLite owns runtime.

### Library

- Images are no longer filtered to this Device’s arch only. Download ARM64 or x86_64 as needed.
- Library fetch keeps the HTTP body when headers and bytes arrive together (Linux hop client).
- Configurable Library directory (new downloads; existing files are not migrated).
- Optional depot Device: on a local miss, fetch image bytes over the agent plane, verify checksum, then store locally. Depot down falls back to the internet.
- Catalog pins use dated Ubuntu snapshot URLs so checksums stay stable.

### Worker-only Device

- `SKIP_FRONTEND=1` install skips the SPA. Same daemon, no extra process role.
- `barkvisor` always has a `serve` command so systemd does not exit 64.

### VNC

- Copy and paste text between this computer and a desktop guest (Paste / Copy on the VNC toolbar, or ⌘V / Ctrl+V). Linux guests need `spice-vdagent`; Windows guests need Spice guest tools. Restart the Workload after upgrade so QEMU adds the vdagent channel.
- If this Device's QEMU was built without `qemu-vdagent` (packaged BarkVisor QEMU 10.2), start omits that chardev so Workloads such as HAOS still boot. Clipboard paste is then unavailable until a QEMU with SPICE ships.
- Display to a member Device no longer drops after the first framebuffer. The Home hop buffer is 8 MiB so QEMU RFB updates are not treated as overflow.
- Member Display hops the agent plane straight to the QEMU VNC socket. The extra loopback through this Device's `:7777` WebSocket was dropping the RFB banner.
- Member Display no longer dies after the first picture. Tight framebuffer reads were sent as 16 KiB+ WebSocket frames; the Home hop (NIO client max 16 KiB) closed mid-update. The hop now chunks at 12 KiB.

### Create VM

- Place on This Device or any reachable member. Incompatibility is a warning, not a lock.
- Guest default follows This Device’s arch so a recommended ARM64 member does not grey out an x86 Home.

### Guest ports

- Workload detail shows TCP listening ports from the guest addon (SSH, HTTP, and common dev servers). Loopback stays internal and is never a URL. Members use the same guest-info hop as This Device.
- Listening ports are the common set only (SSH, HTTP/S, typical self-host UIs such as Home Assistant 8123, Plex, OpenClaw, Jellyfin, Ollama, *arr, DBs, RDP, VNC) — rpcbind and the rest stay hidden. HTTP that actually answers `HEAD /` (or a well-known HTTP port when the probe cannot run) is an Open link.
- This Device NAT Overview offers **Publish this port** when a common TCP listener has no matching hostfwd. The host port is the guest port if free, otherwise the next free NAT claim (PAS-64). One click opens the existing port-forwards editor. Restart is still required if QEMU is already started. Loopback listeners stay hidden. Member NAT is not a click: localhost would be the wrong machine.
- A failed collect clears the snapshot (`null`, hidden in the web UI) instead of keeping stale ports. Collection shares a ~3s budget and caps guest-exec output. Unchanged snapshots skip rewriting port columns. Labeled common ports sort first.
- A Windows Workload with the VirtIO guest addon reports the same TCP listen set (`netstat -ano` or PowerShell). Missing bash/python skips the HTTP probe and uses the well-known scheme. Denied exec stays `null` and backs off like Linux.

### Platform

- Restarting the Device daemon no longer stops Workloads. systemd signals only BarkVisor; QEMU stays up and is reattached. Use Workload Stop to shut a guest down.

- Linux packages (`.deb` / `.rpm` / tarball), systemd, NAT and bridged networking, USB passthrough.
- Native console app talks to the dashboard Device only (Local Network permission is for `:7777`).
- Phone and Mac Console / Display open a Workload on a reachable member the same way the Home web UI does (Home WebSocket tunnel). Create VM stays web-only.

## 0.x — single Device

The first public line is a **Home of one**: one daemon, Vue SPA on port 7777, QEMU Workloads, Library images and templates, NAT and optional bridge, console and VNC, cloud-init, SSH keys.

See [First launch](getting-started-first-launch.md), [Quickstart](getting-started-quickstart.md), and the [roadmap](roadmap.md).
