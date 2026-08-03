# BarkVisor website

One Astro app: **marketing landing** (`/`) + **Starlight docs** (`/docs/*`).

Markdown for docs lives in the repo `docs/` folder and is synced into
`src/content/docs/docs/` at build time.

## Commands

```sh
bun install
bun run dev      # http://localhost:4321/  and  /docs/
bun run build    # → dist/  (landing + docs)
bun run preview
bun run deploy   # build + wrangler pages deploy dist
```

## Cloudflare Pages

### CLI (one shot)

```sh
cd website
bun install
bun run deploy
# or: bun run build && npx wrangler pages deploy dist --project-name=barkvisor
```

### Git-connected project

| Setting | Value |
|---------|--------|
| **Root directory** | `website` |
| **Build command** | `bun install && bun run build` |
| **Build output directory** | `dist` |
| **Framework preset** | None |

Optional env: `NODE_VERSION=22`. If Bun is not available on Pages, use
`npm install && npm run build` (after generating a package-lock, or keep using
Bun via the [Bun install step](https://bun.sh/guides/install/cf-pages)).

Custom domain: Pages → **Custom domains**.

## Layout

```
website/
  src/pages/index.astro          # landing
  src/content/docs/docs/         # Starlight routes under /docs/
  src/styles/landing.css
  src/styles/starlight.css       # theme tokens matching landing
  public/                        # favicons, hero, og-image
  scripts/sync-content.mjs       # docs/*.md → content
  dist/                          # build output (gitignored)
```
