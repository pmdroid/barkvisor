# BarkVisor verification map

This directory is the maintained source for verifying the user-facing behavior of the BarkVisor web UI. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch an isolated daemon with `bun .agents/skills/verify-barkvisor/drive.ts launch` (`VERIFY_RUN` set).
- Doctor must report the expected `http://127.0.0.1:<port>`, data dir under `~/.cache/barkvisor/verify-barkvisor/runs/$VERIFY_RUN/`, and `healthOk`.
- Fresh data dirs start with setup incomplete. Run the first-run setup feature before login, dashboard, workloads, or settings.
- Admin after setup: `admin` / `verify-admin-10`.
- Never drive an instance that was not started by this verification run. Default port 17777; do not use 7777 unless `instance.json` says it is ours.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Prefer ARIA roles and accessible names over CSS selectors or DOM position. Login inputs are an exception (`input[type="text"]` / `input[type="password"]`).
- Treat every command as literal.
- Browser actions go through `drive.ts setup`, `drive.ts login`, `drive.ts open`, or `withBarkVisor`.
- Restore mutated settings (pairing offers, API keys) when the instance will be reused. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes an ARIA snapshot and a screenshot with BarkVisor identity visible (logo, heading, or sidebar).
- Mutation proof includes a second read (`/api/setup/status`, reload, or another page) of the stored value.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition (for example no ready Library image).
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with drive.ts` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [First-run setup](./first-run-setup.md) covers creating a Home on this Device, admin account, catalog skip/sync, and landing on the dashboard.
- [Login](./login.md) covers the sign-in form, failed password, session persistence, and logout.
- [Dashboard and navigation](./dashboard.md) covers the dashboard widgets and sidebar routes.
- [Workloads](./workloads.md) covers the VM list, empty state, and opening the create-VM wizard.
- [Settings and pairing](./settings.md) covers Settings tabs, issuing a pairing offer, and minting an API key.
