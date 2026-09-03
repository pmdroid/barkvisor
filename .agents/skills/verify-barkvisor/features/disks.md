# Disks

## Sub-features

- Per-Device usage cards (volume used / BarkVisor disks provisioned)
- Table: Name · Device · Path · Format · Size · Used · VM · Resize · Delete
- **Create Disk**; resize (grow only); delete
- Link **Device disk directory** → Device detail (not Settings)

## How to get to it (user POV)

Sidebar **Disks** → `/disks`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /disks --out "evidence/run-disks/disks.png"
```

Assertions:

- `h1` is Disks; toolbar **Create Disk**
- Seeded instance has `demo-data` and `demo-scratch` rows
- `GET /api/disks` names match the table
- Empty copy **No disks. Disks are created automatically when you create a VM.** only when the list is empty

## Gotchas

- `/settings?tab=disks` redirects to Devices. Disk inventory is this page.
- Resize cannot shrink.
