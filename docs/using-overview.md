# Using the web UI

Install BarkVisor on a computer using the [macOS](getting-started-installation.md), [Linux](getting-started-linux.md), or [Windows](getting-started-windows.md) package guide. Then open `http://localhost:7777` on that computer.

That computer is a **Device**. Your **Home** contains one or more Devices, and each **Workload** is a VM or App running on one of them.

## Setup and sign-in

On first launch, follow the setup wizard to name the Device, register a passkey, and choose an image Library folder. See [First launch](getting-started-first-launch.md), including instructions for a remote computer.

![The BarkVisor sign-in screen](img/login.png)

After setup, use **Sign in with passkey**. Passkeys need `localhost` or an HTTPS hostname. A raw IP address does not work.

[Settings → Security](settings-security.md) controls whether local or network connections can skip sign-in. To add another computer to this Home, follow [Home and pairing](home-and-pairing.md).

## Navigation

The sidebar lists the pages below. On small screens, use the menu button to open it.

The Device selector switches between **All** Devices and one Device. List pages follow that choice. Create VM and Create App have their own Device pickers.

| Page | What you can do |
|------|-----------------|
| [Dashboard](using-dashboard.md) | See running workloads and problems that need attention |
| [Devices](using-devices.md) | Check your computers, resources, and workload placement |
| [Workloads](using-vms.md) | Create and manage [VMs](using-vm-details.md) and [Apps](using-apps.md) |
| [Ollama](using-ollama.md) | Manage local models and find the completions endpoint |
| [Images](using-images.md) | Upload, download, and remove OS images |
| [Disks](using-disks.md) | Create and resize VM disks |
| [Networks](using-networks.md) | Configure Device interfaces and VM networks |
| [Logs](using-logs.md) | Search events and download diagnostics |
| [Settings](using-settings.md) | Manage pairing, sign-in, keys, catalogs, and updates |

The status strip above the page shows counts of running, failed, and stopped workloads, plus unreachable Devices. The bottom of the sidebar has appearance and sign-out controls.

## Access roles

An **Admin** can manage the Home. An **Inference** user lands on Ollama and can use models, but cannot administer Devices or workloads.

## Related

- [Create your first VM](getting-started-quickstart.md)
- [Home and pairing](home-and-pairing.md)
- [Troubleshooting](getting-started-troubleshooting.md)
