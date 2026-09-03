# BarkVisor feature map

Maintained verification source for the web console (Swift daemon + Vue SPA at `/`). One file per user-facing feature area; each answers how to reach it as a user, how to drive it with the Playwright helpers in `../helpers/`, and what proves it worked.

| Feature | Route | File |
|---|---|---|
| Setup wizard (first run) | `/setup` | [setup.md](setup.md) |
| Dashboard triage inbox | `/dashboard` | [dashboard.md](dashboard.md) |
| Devices & device detail | `/devices`, `/devices/:hostId` | [devices.md](devices.md) |
| Virtual Machines list & Workload detail | `/vms`, `/vms/:id` | [virtual-machines.md](virtual-machines.md) |
| Ollama | `/models` | [ollama.md](ollama.md) |
| Images | `/images` | [images.md](images.md) |
| Disks | `/disks` | [disks.md](disks.md) |
| Settings (9 tabs) | `/settings?tab=…` | [settings.md](settings.md) |
| Networks | `/networks` | [networks.md](networks.md) |
| Logs live tail | `/logs` | [logs.md](logs.md) |

Shared setup for a provisioned run: `helpers/up.sh --seed` then `helpers/doctor.sh`. The login page is passkey-only (**Sign in with passkey** on `.login-card`); helpers inject a JWT from `POST /api/auth/login`. After a real passkey login the app lands on `/vms`. Setup wizard proofs need a **separate** `--no-provision` instance — `doctor.sh` refuses those until the wizard finishes.

Seed content from `--seed`: networks (`lab-isolated`, `lab-nat`), disks (`demo-data`, `demo-scratch`), API key `demo-ci`, SSH key `demo-key`. No Workloads are seeded — creating one needs a boot image, so VM-list proofs should assert empty states, filters, or the create wizard opening rather than running guests.
