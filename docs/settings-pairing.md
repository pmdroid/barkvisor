# Settings: Pairing

Use this tab to add another Device to your Home or sign the native Console app in on a phone.

![Settings Pairing tab](img/settings-pairing.png)

## Add a Device

1. Click **Add a Device**.
2. Choose an address the new Device can reach.
3. Copy the full offer beginning with `barkvisor://pair/v1?`.
4. On the new Device, run `barkvisor join --code '…'` with that full offer. API-only installs use `barkvisor-agent join --code '…'`.

The short code alone is not enough. An offer expires and can be revoked before use. See [Home and pairing](home-and-pairing.md) for the complete flow.

## Phone sign-in

Click **Show sign-in QR** and scan it with the native Console app. This grants a login session. It does not pair the phone as a Device.

## Re-pair this Device

Use **Re-pair this Device** with a fresh offer when this Device needs to join a Home again. Re-pairing does not restore lost workload data.

## Related

- [Home and pairing](home-and-pairing.md)
- [Settings: Home](settings-home.md)
