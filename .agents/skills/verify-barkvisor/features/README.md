# BarkVisor feature map

Maintained verification source for the web console (Swift daemon + Vue SPA at `/`). One file per user-facing feature area; each answers how to reach it as a user, how to drive it with the Playwright helpers in `../helpers/`, and what proves it worked.

| Feature | Route | File |
|---|---|---|
| Dashboard triage inbox | `/dashboard` | [dashboard.md](dashboard.md) |
| Devices & device detail | `/devices`, `/devices/:hostId` | [devices.md](devices.md) |
| Virtual Machines list & Workload detail | `/vms`, `/vms/:id` | [virtual-machines.md](virtual-machines.md) |
| Settings (7 tabs) | `/settings?tab=…` | [settings.md](settings.md) |
| Networks & Bridge setup | `/networks` | [networks.md](networks.md) |
| Logs live tail | `/logs` | [logs.md](logs.md) |

Shared setup for every run: launch an instance (`helpers/up.sh --seed`) and doctor it (`helpers/doctor.sh`). Login is always the real form (`.login-card` inputs + **Sign In**); after login the app lands on `/vms`.

Seed content from `--seed`: networks (`lab-isolated`, `lab-nat`), disks (`demo-data`, `demo-scratch`), API key `demo-ci`, SSH key `demo-key`. No Workloads are seeded — creating one needs a boot image, so VM-list proofs should assert empty states, filters, or the create wizard opening rather than running guests.
