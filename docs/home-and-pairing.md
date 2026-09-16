# Home and pairing

A **Home** is your set of BarkVisor computers. Each computer is a **Device**. You can start with one Device and add more later.

Pairing gives Devices a shared Home login and lets you manage them from one console. Each Device keeps its own workloads, disks, and image Library. Pairing does not move or back up those files.

## Add a Device

Install BarkVisor on the new Device first. Leave its background service running.

On a Device already in your Home:

1. Open **Settings → Pairing → Add a Device**.
2. Choose an address the new Device can reach. Use a listed LAN or Tailscale address, or **Other / DNS name…**.
3. Copy the full pairing offer beginning with `barkvisor://pair/v1?`. The short code alone is not enough.

On the new Device, open a terminal and run:

```sh
barkvisor join --code 'barkvisor://pair/v1?…'
```

Replace the example URI with the full offer you copied. For an API-only install, use `barkvisor-agent join --code` instead. Run this command on the Device being added, not on the Device that issued the offer. The web setup wizard creates a new Home; joining an existing Home uses this command.

The pairing offer expires. Issue a new one if necessary, or revoke an unused offer in Settings. Changing the selected address creates a new offer too.

Once paired, open **Devices** in your existing console to see the new Device. You can choose it when creating a VM or App.

## What pairing changes

Your browser connects to one Device's console. That Device forwards requests to the other Devices in the Home, so you do not need to open a separate browser session for each one.

Workloads continue running on their own Devices if another Device goes offline. An unreachable Device appears as unavailable in the console. Pairing does not provide automatic failover or shared storage.

Use the sidebar's Device selector to show **All** Devices or filter to one. Create VM and Create App have their own Device pickers.

## Phone sign-in

**Settings → Pairing** also has **Phone sign-in**. This QR signs the native Console app into your Home. It is a login offer, not an offer to add another Device.

Allow Local Network access when the app asks. The phone must be able to reach the console Device.

## Device URL

Under **Settings → Home**, choose the hostname or address that other Devices and your phone should use. You can select a detected address or enter one under **Other / DNS name…**.

BarkVisor uses this address in new pairing and sign-in offers and in the Ollama connection instructions. Saving a Device URL does not configure HTTPS or change who can access the Device. Sign-in options are under [Settings → Security](settings-security.md).

### Remote access with Tailscale

Install Tailscale separately on the Device and on the computer or phone you use remotely. BarkVisor can detect its address and MagicDNS name.

For browser passkeys, the MagicDNS name needs HTTPS. An HTTP MagicDNS URL is not enough. See [First launch](getting-started-first-launch.md#set-up-a-remote-device) and [Passkeys](settings-passkeys.md).

Devices can pair over private LAN addresses, IPv6 unique-local addresses, or Tailscale's `100.64.0.0/10` range. Public, loopback, link-local, and metadata addresses are rejected. If an older Device rejects a Tailscale pairing offer, update it or use a LAN address both Devices can reach.

Do not expose port `7777` directly to the public internet.

## API-only Devices

An API-only Device runs workloads without serving the web console. Manage it through another paired Device. Packages provide `barkvisor-agent` for this role.

On Linux, switch an installed package to API-only mode with:

```sh
sudo systemctl disable --now barkvisor.service
sudo systemctl enable --now barkvisor-agent.service
barkvisor-agent join --code 'barkvisor://pair/v1?…'
```

Run only one BarkVisor service per Device. See the [Linux guide](getting-started-linux.md#api-only-device-no-spa) for more options.

For unattended setup, `BARKVISOR_JOIN_CODE` accepts the full pairing offer in the daemon environment before first boot. It is ignored after setup or an existing pairing.

## Recovery

A wiped Device has a new identity. Pair it again with a fresh offer. Pairing does not restore workloads from the wiped Device; workloads on other Devices are unaffected.

## Related

- [First launch](getting-started-first-launch.md)
- [Devices](using-devices.md)
- [Create a Workload](create-workload.md)
- [Settings: Pairing](settings-pairing.md)
