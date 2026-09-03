# Images

## Sub-features

- Capacity bar for the Library folder
- Table of ISOs / cloud images: Name · Type · Arch · Size · Location · Status (Ready / Downloading)
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

- `h1` is Images; toolbar **Upload** and **Download**
- Seeded instance has no images — empty state is expected
- Click **Upload** → heading **Upload Image**; **Download** → **Download Image**
- `GET /api/images` matches the table

Do not start a real URL download unless you intend to wait for it.

## Gotchas

- Library folder must exist (setup already saved one). An unset Library shows a pick-folder prompt instead of the table.
- Downloads are real network fetches into the Library folder on the machine running the daemon.
