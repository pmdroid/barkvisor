# One process, one Device, one data directory

Multi-Device is N BarkVisor installs, not one process that owns many machines. Each process is one Device with one data directory and one durable Device identity. Pairing attaches Devices over the network; it does not put two Devices in one database.

**Considered Options**: one process managing many hosts. Rejected because Workloads, sockets, and local state are host-local and would not survive a remote controller going away.
