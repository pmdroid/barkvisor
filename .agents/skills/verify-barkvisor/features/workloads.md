# Workloads

Workloads is the VM list: empty or populated rows, stats, and a wizard to create a VM. Finishing a guest that actually boots is outside this map.

## Sub-features

- `vm-list` shows heading `Virtual Machines` and `Create VM`.
- `vm-empty` shows `No virtual machines yet` and `Create your first VM` when there are none.
- `vm-wizard-open` opens `Create Virtual Machine` from either create button or dashboard `Create VM`.
- `vm-wizard-basics` is step 1 (`Basics`): Linux/Windows, name placeholder `my-vm`, no Device picker yet.
- `vm-wizard-cancel` closes the wizard without creating a row.
- `vm-create-submit` is reachable only with a ready Library image; otherwise report `verified-unreachable`.

## How to get to it (user POV)

- Choose `Virtual Machines` in the sidebar, or open `/vms`.
- Choose `Create VM` on the dashboard.
- Choose `Create VM` or `Create your first VM` on the VM list.

## Driving it with drive.ts

Preconditions:

- Setup complete; signed in.
- Isolated instance with no leftover VMs (fresh data dir).

- **List.** Run `bun .agents/skills/verify-barkvisor/drive.ts open /vms --label vms` or `withBarkVisor` `page.goto("/vms")`. Heading `Virtual Machines` is visible. Button `Create VM` is visible. Stats copy includes `Device CPU` and `Device Memory`. Capture `vms-list`.
- **Empty.** On a fresh instance, status `No virtual machines yet` and button `Create your first VM` are visible. No table rows.
- **Open wizard.** Choose `Create VM`. Heading `Create Virtual Machine` is visible. Step label includes `Basics`. Capture `vm-wizard-basics`.
- **Basics.** Linux/Windows cards are selectable. Name field placeholder `my-vm`. Device picker is not on this step. Type `verify-vm` into the name field. Choose `Next` only if an image will be chosen next.
- **Cancel.** Choose `Cancel` (step 1) or `Back` then `Cancel`. List returns. Name `verify-vm` is not a row. Capture `vms-after-cancel`.
- **Create (if a ready image exists).** Walk Basics → Image → Place → Hardware → remaining steps → `Create VM`. A row named as entered appears after reload of `/vms`. Without a ready image, stop after `vm-wizard-open` and record `vm-create-submit` as unreachable: no ready Library image.

## Gotchas

- Wizard step count is 7 dots; labels include Basics, Image, Place, Hardware. Image is required to proceed past Image. Empty Library is the normal skip-catalog state.
- Dashboard `Create VM` navigates to `/vms?create=1` and should open the same wizard. If only the list appears, that entry point failed.
- Do not `POST /api/vms` and then screenshot the list as proof of the wizard.
- Starting/stopping a guest needs QEMU and a disk. That is guest-boot, not this feature.
