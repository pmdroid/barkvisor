# Dashboard

**Dashboard** is the triage inbox for your Home: what needs attention first, what is running, and how the machines feel.

![Dashboard with the ops ticker, workload sections, and Home device card](img/dashboard.png)

## Incidents

Problems float to the top as incident rows — **Failed** Workloads and **Unreachable** Devices. Failed rows carry an **Open** button that jumps straight to the offending item. If nothing is wrong, there are no incidents and the board reads calm.

## Feed columns

Below the incidents, Workloads sort into sections:

| Section | Meaning |
|--------|---------|
| **Needs you** | Always visible — waiting on a human decision, or "Nothing needs you" |
| **Running** | Live Workloads across the scoped Devices (only when non-empty) |
| **Stopped** | Shut down Workloads (only when non-empty) |

Failed Workloads surface as incident rows at the top. Each card carries the Workload name and its Device; clicking one opens [Workload details](using-vm-details.md).

## Home card

The side rail shows the **Home** Device card (name, platform · arch, reachability) — per-Device CPU/memory meters live on [Devices](using-devices.md) and the Device detail page. Spikes there usually explain the incidents on the left.

## Customize

**Customize** opens the "Customize Home" drawer: reorder modules with the ▲/▼ (Move up/Move down) buttons and show/hide modules you never look at, then **Done**. Layout is per person, not global.

## Create VM

**Create VM** starts the [Create a Workload](create-workload.md) wizard without leaving the dashboard — the fastest path from "I noticed something" to "I placed a fix".

## Related

- [Devices](using-devices.md)
- [Workload details](using-vm-details.md)
- [Logs](using-logs.md) — dig into why something failed
