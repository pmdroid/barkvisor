# Ollama

## Sub-features

- Per-Device picker (runtime status) + inspect pane
- Pull-by-name, catalog table, Start/Stop (admin), Home completions URL, **More → Export JSON**
- Inference-role users are locked to this page (`/models`); `/chat` redirects to Dashboard (then inference bounces back to `/models`)

## How to get to it (user POV)

Sidebar **Ollama** → `/models`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /models --out "evidence/run-ollama/ollama.png"
```

Assertions:

- `h1` is Ollama
- Device picker lists this Device; inspect chip **Ollama up** / **No Ollama**
- Completions URL is this origin + `/v1/chat/completions` (Home router, not a per-Device URL)
- Seeded instance typically has no pulled models — empty copy **No Ollama models yet**
- Do not click Start/Pull unless you want a real Ollama pull/load on the host

## Gotchas

- Pull downloads weights; Start loads an already-pulled model; Recheck is the install probe. Screenshots + `GET /api/home/ollama/models` (same payload as `/api/home/ollama/status`) are enough for a map proof. `GET /api/ollama/status` is this Device only, not the page catalog.
- Completions routing to a Device that already has the model is server-side.
