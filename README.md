<p align="center">
  <img src="website/public/hero.png" alt="BarkVisor" width="256">
</p>

<h1 align="center">BarkVisor</h1>

BarkVisor runs virtual machines and Docker Compose apps on your computers. Manage them from a web browser, with an optional Ollama integration for local models.

Each computer is a **Device**. Your Devices make up a **Home**, with one login and a console for managing them. Workloads stay on the Device you choose, even when another Device goes offline.

> Alpha software. APIs, configuration, and behavior can change between releases.

## Install BarkVisor

Use a prebuilt package from [Releases](https://github.com/pmdroid/barkvisor/releases). You do not need to build BarkVisor or install developer tools.

| Your computer | Package and instructions |
|---------------|--------------------------|
| macOS 26+, Apple Silicon | [macOS installation](docs/getting-started-installation.md), `.pkg` |
| Ubuntu or Debian, amd64 or arm64 | [Linux installation](docs/getting-started-linux.md), `.deb` |
| Other Linux distributions | [Portable tarball](docs/getting-started-linux.md#other-distros-portable-tarball-no-root) |
| Windows, amd64 or arm64 | [Windows installation](docs/getting-started-windows.md), zip |

QEMU is installed separately. Each guide explains which runtime packages you need.

After installation:

1. Open `http://localhost:7777` on the Device.
2. Complete [first-run setup](docs/getting-started-first-launch.md).
3. [Create your first VM](docs/getting-started-quickstart.md) or [install an App](docs/using-apps.md).

Passkeys need `localhost` or an HTTPS hostname. For a computer you access over the network, follow [remote setup](docs/getting-started-first-launch.md#set-up-a-remote-device).

## What you can do

- Create VMs from catalog templates, cloud images, or installer ISOs.
- Choose CPU, memory, disks, and networking for each VM.
- Open graphical and serial consoles, inspect metrics, and read logs in the browser.
- Install Docker Compose apps from the catalog on Devices with Docker installed.
- Pair Devices and manage their workloads from one console.
- Run Ollama models and connect compatible inference clients.
- Attach USB peripherals on macOS and Linux, or pass through GPUs and PCI devices on Linux.

See [Using BarkVisor](docs/using-overview.md) for a guide to each page.

## Guides

- [Home and pairing](docs/home-and-pairing.md)
- [Apps](docs/using-apps.md)
- [Ollama](docs/ollama.md)
- [Disks](docs/using-disks.md) and [Networks](docs/using-networks.md)
- [Settings](docs/using-settings.md) and [Updates](docs/settings-updates.md)
- [Troubleshooting](docs/getting-started-troubleshooting.md)
- [Changelog](docs/changelog.md) and [Roadmap](docs/roadmap.md)

## Contributing

Building from source is optional. Contributor instructions are in [Development](docs/getting-started-development.md), [Building releases](docs/getting-started-building-releases.md), and the [website guide](website/README.md).

## License

[MIT](LICENSE).
