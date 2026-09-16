# BarkVisor website

The Astro site contains the landing page at `/` and Starlight documentation at `/docs/`.

## Edit documentation

Edit the source Markdown in the repository's `docs/` directory. The build copies published pages into `website/src/content/docs/docs/` and adjusts their links. Do not edit those generated copies.

The docs home page, `src/content/docs/docs/index.mdx`, is maintained directly. To publish a new page, add it to `scripts/sync-content.mjs` and the sidebar in `astro.config.mjs`.

Keep the main docs focused on installing packages and using BarkVisor. Put build commands and internal details in contributor guides.

## Preview

From this directory:

```sh
bun install --frozen-lockfile
bun run dev
```

Open `http://localhost:4321/docs/`. The dev command syncs the docs before starting. Run `bun run sync` again after editing source files in `docs/` while the dev server is running.

## Build

```sh
bun run build
bun run preview
```

The build runs the sync step and writes the landing page and docs to `dist/`.

## Deploy

`bun run deploy` builds the site and deploys `dist/` to the Cloudflare Pages project `barkvisor`. It requires Cloudflare credentials.

For a Git-connected Pages project:

| Setting | Value |
|---------|-------|
| Root directory | `website` |
| Build command | `bun install --frozen-lockfile && bun run build` |
| Build output directory | `dist` |

Configure custom domains in the Pages project.
