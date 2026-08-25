# Login

Login lets a user sign in to a Device that already has an admin, keep the session across reload, see a failed password, and sign out from the sidebar.

## Sub-features

- `login-form` shows username, password, and `Sign In` on `/login`.
- `login-success` stores a JWT and lands on `/vms`.
- `login-fail` shows an error and stores no token.
- `login-unauth` sends protected routes to `/login`.
- `login-persist` keeps `/vms` after reload.
- `login-logout` clears the token via the sidebar logout control.

## How to get to it (user POV)

- Open `/login` after setup is complete.
- Open any protected route (`/dashboard`, `/vms`, `/settings`, …) with no token or an expired token.
- Choose the sidebar button with accessible title `Logout`.

## Driving it with drive.ts

Preconditions:

- Setup is complete on this instance (`doctor` shows `setupComplete: true`).
- Admin is `admin` / `verify-admin-10`.

- **Form.** Run `bun .agents/skills/verify-barkvisor/drive.ts login` or `page.goto("/login")` after clearing `localStorage.token`. Heading `BarkVisor` and subtitle `Sign in to manage your virtual machines` are visible. Button `Sign In` is visible. Capture `login-form`.
- **Success.** Fill `input[type="text"]` with `admin` and `input[type="password"]` with `verify-admin-10`. Choose `Sign In`. URL includes `/vms`. Heading `Virtual Machines` is visible. `localStorage.token` is non-empty. Capture `login-vms`.
- **Fail.** Repeat the form with password `wrongpassword123`. An error region is visible (`.login-error` or the form error). `localStorage.token` is null. URL stays on `/login`.
- **Guard.** With no token, `page.goto("/dashboard")` (and `/vms`, `/images`, `/settings`) ends on `/login`.
- **Persist.** After a successful login, `page.reload()`. URL still includes `/vms` and heading `Virtual Machines` remains.
- **Logout.** From `/dashboard`, choose `button[title="Logout"]`. URL includes `/login` and `localStorage.token` is null.

## Gotchas

- Username/password `<label>`s are not associated with the inputs. `getByLabel("Username")` fails; use `input[type="text"]` and `input[type="password"]`.
- Injecting a token via `POST /api/auth/login` is not proof of `login-success`. Use the form.
- Login after a failed setup (`complete: false`) never appears; the router sends everything to `/setup`.
- Rate limiting is on by default (10 attempts / 300s on a fresh data dir). Rapid fail loops can 429; use a new `VERIFY_RUN` if that happens.
- Cypress `env.password` is `password` (too short for setup). This skill's password is `verify-admin-10`.
