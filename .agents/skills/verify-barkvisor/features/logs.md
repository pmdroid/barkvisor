# Logs

## Sub-features

- Search box, All Devices filter, All Workloads filter
- Time range: Last 24 Hours / Last Hour / Last 7 Days
- **Live Tail** toggle (SSE stream), **Diagnostics** bundle download
- Terminal-style stream with level coloring and Pause / Resume / Clear
- Application workloads also have compose logs on `/vms/:id` (`ComposeLogsPanel`), separate from this Home-wide stream

## How to get to it (user POV)

Sidebar **Logs** → `/logs`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /logs --wait-ms 2500 --out "evidence/run-logs/logs.png"
```

Assertions:

- Stream renders lines with level classes (`.line` / `.lv`; seeded daemon activity produces info/warn lines quickly)
- Toolbar **Live Tail** and the stream-header **Pause** / **Resume** are the same toggle. Off disconnects SSE and re-fetches `GET /api/logs` (it does not freeze a buffer). Default is History, so the header says **Resume**
- **Clear** only hides older lines in the UI; `GET /api/logs` is unchanged

Side-effect proof: `curl -sf -H "Authorization: Bearer $TOKEN" "$URL/api/logs?limit=5"`. API-key creates go to the **audit** table, not this stream — use daemon `Log.*` lines (or `POST /api/logs/client-error`) as proof.

## Gotchas

- Live Tail uses ticketed SSE (`/api/logs/stream?ticket=…`) on this Device; member Devices poll `GET …/logs` every 4s. Tickets are single-use and short-lived — the app re-mints automatically, but raw curl replays need a fresh ticket per attempt.
- Diagnostics downloads a blob; verify via network response status rather than trying to read the browser download UI headlessly.
