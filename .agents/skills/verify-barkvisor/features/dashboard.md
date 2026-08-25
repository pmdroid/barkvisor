# Dashboard and navigation

The dashboard is the signed-in home: Device/workload summary, widget cards, a Create VM shortcut, and a sidebar that reaches the rest of the app.

## Sub-features

- `dash-load` shows heading `Dashboard` after setup launch or sidebar navigation.
- `dash-widgets` shows Devices, Health, CPU, Memory, Storage, Temperature, and Recent Machines.
- `dash-create` opens the workload list create flow via `Create VM`.
- `nav-sidebar` reaches Dashboard, Devices, Virtual Machines, Images, Disks, Networks, Repositories, Logs, and Settings.
- `nav-root` sends `/` to `/dashboard` and unknown paths to `/dashboard`.

## How to get to it (user POV)

- Finish first-run setup with `Launch Dashboard`.
- Choose `Dashboard` in the sidebar.
- Open `/` or `/dashboard` while signed in.
- Choose other sidebar labels to leave and return.

## Driving it with drive.ts

Preconditions:

- Setup complete; storage state or a real login session exists.
- `doctor` is green.

- **Open.** Run `bun .agents/skills/verify-barkvisor/drive.ts open /dashboard --label dashboard`. Heading `Dashboard` is visible. Sidebar link to `/dashboard` is present. Capture `dashboard`.
- **Widgets.** The page includes the labels `Devices`, `Health`, `CPU`, `Memory`, `Storage`, `Temperature`, and `Recent Machines` (Customize can hide them; a fresh profile shows all). Capture `dashboard-widgets` if you toggled Customize.
- **Create shortcut.** Choose `Create VM` on the dashboard. URL includes `/vms` (query `create=1` may be present) and the create wizard heading `Create Virtual Machine` or the VM list is visible. Close with `Cancel` if the wizard opened.
- **Sidebar.** From `/dashboard`, choose each of `Devices`, `Virtual Machines`, `Images`, `Disks`, `Networks`, `Repositories`, `Logs`, `Settings`. URLs are `/devices`, `/vms`, `/images`, `/disks`, `/networks`, `/registry`, `/logs`, `/settings` with headings `Devices`, `Virtual Machines`, `Images`, `Disks`, `Networks`, `Repositories`, `Logs`, `Settings`. Capture at least `nav-vms` and `nav-settings`.
- **Root.** `page.goto("/")` lands on `/dashboard`. `page.goto("/this-page-does-not-exist")` lands on `/dashboard`.

## Gotchas

- Ollama and Chat sidebar items appear only for those roles/features. Their absence on a default admin Home is not a failure.
- Device scope `<select id="device-scope">` filters list pages. Leave it on `All` unless the recipe says otherwise.
- Cypress dashboard specs still mention Quick Launch cards (`Machines`, `Templates`, …). The current dashboard uses widgets plus `Create VM` / `Customize`, not those six cards. Drive what is on screen.
- A modal or Customize panel aria-hides the rest of the page. Capture with the panel closed for a full snapshot.
