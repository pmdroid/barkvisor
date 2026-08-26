---
title: "Dashboard"
description: "The triage inbox for your Home — incidents, feed columns, and vitals."
---
**Dashboard** is the triage inbox for your Home: what needs attention first, what is running, and how the machines feel. Admins see it right after sign-in.

![Dashboard with the ops ticker, feed columns, and vitals rail](/docs-img/dashboard.png)

## Incidents

Problems float to the top as incident rows — **Failed** Workloads and **Unreachable** Devices — each with an **Open** button that jumps straight to the offending item. If nothing is wrong, there are no incidents and the board reads calm.

## Feed columns

Below the incidents, Workloads sort into four columns:

| Column | Meaning |
|--------|---------|
| **Needs you** | Waiting on a human decision — failed, stopped unexpectedly, or pending action |
| **Running** | Live Workloads across the scoped Devices |
| **Failed** | Workloads whose process died or never came up |
| **Stopped** | Deliberately shut down Workloads |

Each card carries the Workload name and its Device; clicking one opens [Workload details](/docs/using/vm-details/).

## Vitals rail

The side rail meters **CPU**, **Memory**, **Temperature**, and **Storage** for the current Device scope. Spikes here usually explain the incidents on the left.

## Customize

**Customize** opens the "Customize Home" drawer: reorder modules with **move up/down** and hide modules you never look at. Layout is per person, not global.

## Create VM

**Create VM** starts the [Create a Workload](/docs/guides/create-workload/) wizard without leaving the dashboard — the fastest path from "I noticed something" to "I placed a fix".

## Related

- [Devices](/docs/using/devices/)
- [Workload details](/docs/using/vm-details/)
- [Logs](/docs/using/logs/) — dig into why something failed
