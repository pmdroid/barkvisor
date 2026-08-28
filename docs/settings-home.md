# Settings: Home

The **Home** tab is identity and reachability for this Device. It is not where pairing happens — the QR lives on [Pairing](settings-pairing.md).

![Settings Home tab: facts and Device URL](img/settings-home.png)

## Facts sheet

- **Device name** — how this Device appears across the Home
- **Device URL** — the saved host, shown as `http://<host>:7777` when one is set
- **Advertised hosts** — addresses other Devices use to reach this one
- **Role** — what your account can do on this Home
- **Add a {Device}** — shortcut into [Pairing](settings-pairing.md)

## Device URL

Pick a detected hostname, LAN IP, Tailscale IP, or MagicDNS name, or **Other / DNS name…**. That host is stamped on a new pairing or sign-in QR as `host=` when you do not pick another address, and Models inference how-to uses it for `OPENAI_BASE_URL`. You can paste `https://box.ts.net`; only the host is stored. LAN inference stays `http://<host>:7777`.

The picker still lists detected LAN / Tailscale / hostname entries. Access is open; Device URL is which host we stamp and show.

## Save changes

The header button saves Device name and Device URL.

## Related

- [Settings: Pairing](settings-pairing.md)
- [Settings: Library](settings-library.md)
- [Home and pairing](home-and-pairing.md)
