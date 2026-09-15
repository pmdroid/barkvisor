# A Home is paired Devices, not a cluster

A Home is a person's set of Devices joined by Pairing. There is no quorum, no elected controller, and no requirement that other Devices be up for local Workloads to run. If one Device is unreachable, Workloads on the others keep running.

This is deliberate. Failover, live migration, and quorum stay later ideas; they are not how the Home works today.
