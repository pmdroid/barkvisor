# Product

## Platform

adaptive

This record covers the browser console in `frontend/`, the native macOS and iOS
consoles in `Apps/BarkVisorConsole/`, and the public website and documentation
in `website/` and `docs/`. The browser and native consoles use the same Device
API. The native consoles follow their platform's interaction conventions.

## Users

Home users who want self-hosting without becoming infrastructure experts. They
use their own computers to run apps, virtual machines, and local AI, and need to
understand what is running, where it runs, and what needs attention.

## Product Purpose

BarkVisor is one control center for managing workloads and servers. It brings
the person's computers and the things running on them into one place.

Success means a person can set up a computer, create or install a Workload on a
chosen Device, and manage it from the console. During everyday use, they can
understand status, act on problems, and reach the relevant controls without
juggling separate management interfaces.

## Positioning

The central promise is unified control of workloads and servers. BarkVisor
combines QEMU virtual machines, Docker Compose apps, and an optional Ollama
integration with management across paired Devices.

The person connects to one Device's API, which proxies management requests to
other Devices. Each Workload runs on the Device the person chooses; its storage
belongs to that Device. Other Devices keep running their own Workloads when one
becomes unreachable.

## Operating Context

- BarkVisor runs on macOS, Linux, and Windows computers. A single Device is a
  complete starting point; additional Devices join through pairing.
- First-run setup happens in the web console. It names the Device, registers a
  passkey, selects the image Library folder, and offers a catalog sync.
- The local web console is available at `http://localhost:7777`. Passkey access
  uses `localhost` or an HTTPS hostname.
- A Home shares its login across paired Devices. Pairing joins a Device; a login
  offer signs a browser or phone in.
- The console can show all Devices or one Device. Workload creation has its own
  placement choice.
- Everyday work includes creating and starting Workloads, opening consoles,
  checking health and resource use, and inspecting logs.

## Capabilities and Constraints

- Virtual Machines can start from templates, cloud images, or installer ISOs,
  with CPU, memory, disk, and network configuration.
- Apps are Docker Compose projects on Devices with Docker installed. Their
  management includes configuration, lifecycle controls, logs, and volumes.
- The optional Ollama integration manages models and exposes inference access
  through BarkVisor.
- Device capabilities determine available hardware and networking controls.
- Admin access manages the Home. Inference access is restricted to model use.

Current domain terminology is defined in [CONTEXT.md](CONTEXT.md), with UI
wording and API mappings in
[docs/product-terminology.md](docs/product-terminology.md). Those files own the
meanings of Home, Device, Workload, Library, and related terms. Product
explanations lead with what the person can manage and accomplish.

## Evidence on Hand

- [README.md](README.md): installation entry points and implemented
  capabilities.
- [docs/using-overview.md](docs/using-overview.md): browser workflows,
  navigation, and access roles.
- [docs/getting-started-first-launch.md](docs/getting-started-first-launch.md):
  setup and sign-in behavior.
- [docs/home-and-pairing.md](docs/home-and-pairing.md): management across
  Devices.
- `docs/img/`: screenshots of implemented workflows; compare them with current
  source before reuse.
- `website/public/hero.png`, `website/public/app-icon.png`, and
  `frontend/public/app-icon.png`: existing BarkVisor identity assets.

## Product Principles

1. Make workloads and servers manageable from one place.
2. Explain tasks in language a home user can act on without infrastructure
   expertise.
3. Make status, Device ownership, and placement choices clear.
4. Preserve each Device's ability to run its own Workloads independently.
5. Keep product concepts consistent while respecting each interface's platform
   conventions.
