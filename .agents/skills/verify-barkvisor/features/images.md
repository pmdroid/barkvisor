# Images

## Sub-features

- Capacity bar for the volume that contains the Library folder
- **Images** / **Apps** tabs. Images table: Name · Type · Arch · Size · Location · Status (Ready / Downloading) + Delete. Apps tab is the Home catalog with **Search apps** and category chips
- **Upload** (tus to `/api/images/tus`) and **Download** from a URL
- Delete (confirm)

## How to get to it (user POV)

Sidebar **Images** → `/images`. Empty copy: **No images yet**.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /images --out "evidence/run-images/images.png"
```

Assertions:

- `h1` is Images; toolbar **Upload** and **Download** (only when a non-default Library is saved)
- Seeded instance has no images unless a prior Create VM Windows flow pulled VirtIO drivers — empty copy **No images yet**
- Click **Upload** → heading **Upload Image**; **Download** → **Download Image** (Cancel to close; Escape leaves the overlay)
- Apps tab: **Search apps** + category chips; empty copy **No apps yet** if catalogs have not synced
- `GET /api/images` names match the Images table on a single Device

Do not start a real URL download unless you intend to wait for it.

## Gotchas

- Library folder must exist (setup already saved one). An unset default Library hides Upload/Download and the table — there is no pick-folder prompt on this page (folder pick is Setup / Settings → Library).
- Downloads are real network fetches into the Library folder on the machine running the daemon.
