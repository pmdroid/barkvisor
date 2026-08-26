# Logs

## Sub-features

- Search box, All Devices filter, All Workloads filter
- Time range: Last 24 Hours / Last Hour / Last 7 Days
- **Live Tail** toggle (SSE stream), **Diagnostics** bundle download
- Terminal-style stream with level coloring and Pause / Resume / Clear

## How to get to it (user POV)

Sidebar **Logs** → `/logs`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /logs --wait-ms 2500 --out "evidence/run-logs/logs.png"
```

Assertions:

- Stream renders lines with level classes (seeded daemon activity produces info/warn lines quickly)
- Toggling **Live Tail** off freezes the feed; Clear empties the view without affecting server-side history (`GET /api/logs` still returns entries)

Side-effect proof: count entries via `curl -sf -H "Authorization: Bearer $TOKEN" "$URL/api/logs?limit=5"` before and after generating activity (e.g. create an API key through the UI) — the new action appears in the stream.

## Gotchas

- Live Tail uses ticketed SSE (`/api/logs/stream?ticket=…`); tickets are single-use and short-lived — the app re-mints automatically, but raw curl replays need a fresh ticket per attempt.
- Diagnostics downloads a blob; verify via network response status rather than trying to read the browser download UI headlessly.
