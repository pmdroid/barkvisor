---
title: "Settings: Home"
description: "Device facts and Device URL."
---
The **Home** tab is identity and reachability for this Device. It is not where pairing happens — the QR lives on [Pairing](/docs/using/settings/pairing/).

![Settings Home tab: facts and Device URL](/docs-img/settings-home.png)

## Facts sheet

- **Device name** — how this Device appears across the Home
- **Device URL** — saved host, shown as `https://<magicdns>` with no port when Tailscale MagicDNS is in use, otherwise `http://<host>:7777`
- **Advertised hosts** — addresses other Devices use to reach this one
- **Add a {Device}** — shortcut into [Pairing](/docs/using/settings/pairing/)

## Device URL

Pick a detected hostname, LAN IP, Tailscale IP, or MagicDNS name, or **Other / DNS name…**. With Tailscale up and nothing saved, the picker defaults to MagicDNS. That host is stamped on a new pairing or sign-in QR as `host=` when you do not pick another address, and Models inference how-to uses it for `OPENAI_BASE_URL`. You can paste `https://box.ts.net`; only the host is stored. The shown Device URL for MagicDNS is `https://<magicdns>` with no port. LAN stays `http://<host>:7777`.

The picker still lists detected LAN / Tailscale / hostname entries. Access is open; Device URL is which host we stamp and show.

## Save changes

The header button saves Device URL.

## Related

- [Settings: Pairing](/docs/using/settings/pairing/)
- [Settings: Library](/docs/using/settings/library/)
- [Home and pairing](/docs/guides/home-and-pairing/)
