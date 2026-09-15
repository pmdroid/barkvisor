# BarkVisor

A person's Home of Devices. Each Device runs Workloads the person placed there. One Device is already a Home.

## Home

**Home**:
A person's set of Devices. A single Device is a Home of one; more Devices join that Home later.
_Avoid_: Cluster, datacenter, quorum, fleet, node

**Device**:
The computer running BarkVisor. A Mac, PC, or board. Workloads, disks, and the Library on that machine belong to it.
_Avoid_: Node, host (when speaking to a person), This Device as a stand-in name. Use the Device's display name.

**Member**:
A Device in the Home other than the Device the person is using as the console.

**Agent**:
The BarkVisor process on a Device, whether it serves the console or is API-only.
_Avoid_: Node agent, worker node

**Pairing**:
Joining a Device to an existing Home. After pairing, Devices share the Home login. Pairing does not move Workloads or share disks.

**Pairing offer**:
The code and QR a Device issues so another Device can join the Home. Distinct from a Login offer.

**Login offer**:
The code and QR a Home issues so a phone or browser can sign in. Distinct from Pairing.

**Home login**:
The shared sign-in of the Home, copied to a Device when it pairs. The person signs in once for the Home, not once per Device.

**Scope**:
Whether the console is showing the whole Home or one Device.

**Placement**:
Choosing which Device a new Workload will run on. A recommendation is a suggestion; the person confirms or overrides it.

## Workloads

**Workload**:
Something the Home runs on exactly one Device: a Virtual Machine or an App.

**Virtual Machine**:
A Workload that is a guest computer on a Device.

**App**:
A Workload that is a Docker Compose project on a Device, not a guest computer.
_Avoid_: Container (as the Workload)

**House Workload**:
A Workload granted the house LAN and USB.

**Agent Workload**:
A Workload granted WAN access only: no house LAN, no USB. Not the Agent process.
_Avoid_: Agent (unqualified)

**Disk**:
A virtual disk that lives on one Device and may attach to a Virtual Machine. Distinct from an Image.

**Volume**:
Storage an App binds on a Device. Distinct from a Disk.

## Library

**Library**:
The Images and Templates a Device can deploy from. Each Device has its own Library.

**Image**:
Boot media in a Library. An ISO or cloud image used to create a Virtual Machine.

**Template**:
A reusable recipe for creating a Virtual Machine from a Library Image.

**Catalog**:
A remote list of Images, Templates, or Apps a Device can sync.
_Avoid_: Marketplace, store

**Repository**:
A Catalog URL the Home syncs.

## Networks

**Network**:
A connectivity record a Workload can attach to: NAT, bridged, or isolated.

**Bridge**:
A host switch on a Device that bridged Workloads share.

**USB peripheral**:
A USB gadget plugged into a Device. Not a BarkVisor Device.

## People

**Passkey**:
The credential that signs a person into the Home. There is no username-and-password sign-in.

**Admin**:
A Home login with access to every part of the Home.

**Inference**:
A Home login that can use Ollama and nothing else.

**Ollama**:
The optional model runtime on a Device. Completions are asked of the Home, not of each Device's Ollama port.
