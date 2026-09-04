# System-Review Findings Review (origin/main..HEAD)

Reviewed 6 commits closing findings #521-#533: pairing identity seal, ttyd
credential gate, Ollama key at-rest encryption, smoke-script password
hardening, QEMU lifecycle (chardev booleans, swtpm wait, UDP probe, ticker),
host network (iptables uid-owner, setuid helper restore), and dead code.
Build (`swift build`) and targeted suites (OllamaSettings, PairingIdentity,
CodingAgentImage, VMStartHelpers, PortRegistry, PendingVMImageOverlay,
AgentNetworkCage, WorkloadPrivilegeDrop, QEMU*, JWTAuthMiddleware,
HomeOllamaController, LinuxGuestScripts, DaemonRestartIsolation) all green.

### Issue 1 -- Severity: bug
File: Sources/BarkVisorCore/Platform/AgentNetworkCage.swift:142-222
Description: The switch from `-m owner --pid-owner <qemu pid>` to
`-m owner --uid-owner <drop user uid>` (finding #530) changes the filter from
per-VM to per-user, with three cross-VM side effects on a root Linux daemon
where QEMU is dropped to `barkvisor`/`qemu`:
  1. House-class NAT VMs also run dropped (`VMManager.swift:271` drops every
     workload), so the REJECT rules for 10/8, 172.16/12, 192.168/16, 127/8,
     169.254/16, 100.64/10, 224/4 now also block any house VM's guest NAT
     traffic whenever an agent VM's filter is installed.
  2. The Ollama ACCEPT rule (`--uid-owner ... -d 127.0.0.1 --dport 11434`)
     is uid-wide too: if one agent VM opts into host Ollama, every other
     agent (and house) VM can reach host Ollama, even without the grant.
  3. `removeLinuxFilter` (`VMManager+ProcessHelpers.swift:214`) deletes the
     matching rules on one VM's cleanup, lifting the block (and the Ollama
     grant) for every other still-running agent VM until it restarts.
The pid-owner rules were scoped to a single QEMU pid and avoided all three.
Suggestion: keep uid-owner but scope by VM, e.g. combine `--uid-owner` with a
per-VM marker only that VM can match (mark that QEMU process via
`-m owner --uid-owner <uid>` plus a per-VM iptables chain, or per-VM
cgroup/cgroup2 owner match on `-m owner`; alternatively re-apply the full
rule set on every start/stop for the set of live agent VMs and key the Ollama
exception to the VM's user-data, not the uid alone). At minimum document that
the appliance must not mix house-NAT and agent workloads, since the block is
now user-wide.
Status: open

### Issue 2 -- Severity: suggestion
File: Sources/BarkVisorCore/Services/CodingAgentImage.swift:82-131, 158-302
Description: ttyd now requires Basic auth (`ExecStart ... -c "$TTYD_CREDENTIAL"`),
and ttyd 1.7.7's `-c` is `USER[:PASSWORD]` — `barkvisor-vm:<32 hex>` parses
correctly, so the gate itself works. But the credential is generated inside
`userData()`, written only into the guest `/etc/default/barkvisor-ttyd`
(0600) and the stored cloud-init user-data; nothing in the console, the SPA,
or any API surfaces it, so an operator cannot authenticate to the web
terminal after this change. Additionally, a VM created before this change (or
a managed VM whose stored user-data has no `TTYD_CREDENTIAL`) regenerates a
brand-new credential whenever `userData()`/`userDataForGPU` runs (e.g. GPU
detach/attach), silently invalidating any previously-known value.
Suggestion: surface the per-VM credential (e.g. read it back from the stored
user-data and show it in VM detail, or serve it behind the existing
`?session=` ticket flow that already gates VNC/console — ideally reuse the
single-use ticket path instead of a static Basic-auth secret). For legacy VMs,
preserve the credential from stored user-data on first re-run instead of
regenerating.
Status: open

### Issue 3 -- Severity: suggestion
File: Sources/BarkVisorCore/Platform/AgentNetworkCage.swift:149-162, 212-222
Description: `workloadOwnerUID()` returns nil both when the daemon is not root
and when root has no `barkvisor`/`qemu` account; `applyLinuxFilter` then hard
fails and `VMManager.swift:277-281` terminates the VM. A root daemon without
the drop user previously started agent workloads fine with pid-owner rules.
Separately, when the drop user exists but neither `setpriv` nor `runuser` is
present, `WorkloadPrivilegeDrop.plan` still runs QEMU as uid 0 while the
filter is keyed to the drop-user uid — the REJECT rules then never match and
the agent LAN block silently stops working (no error), a quiet security
downgrade vs. pid-owner which matched the root QEMU pid.
Suggestion: fail loudly when a filter is installed for a uid that does not
own the QEMU process (compare the installed rule uid against the launch's
actual uid from the `Launch`), and consider a non-root or no-drop-user fallback
(pid-owner) rather than a hard start failure.
Status: open

### Issue 4 -- Severity: nit
File: Sources/BarkVisorCore/Services/OllamaSettings.swift:106-131, 134-144
Description: Legacy plaintext rows read through (`storedAPIKey` returns the
raw value) but are re-sealed only on a key-writing `save` (`updateApiKey ==
true`). An endpoint-only update, or `seedSelfFromLegacy` copying a plaintext
global key into a host row, leaves the plaintext at rest indefinitely. Commit
message says "re-seal on save," but only explicit key saves seal.
Suggestion: seal at read time when a plaintext legacy value is observed (write
back the ciphertext), or document that plaintext persists until the key is
re-entered.
Status: open

### Issue 5 -- Severity: nit
File: Sources/BarkVisorCore/Config.swift:346-360
Description: `ollamaKeySecret` generation is not serialized (unlike
`ensureAPIKeyHmacSecret`, which holds `apiKeyHmacSecretFileLock`) and returns
a freshly generated secret on every call when the persist fails. Two racing
first accesses can persist different secrets; keys sealed under one become
unreadable (silently `nil` via `storedAPIKey`) and the DB ciphertext is then
orphaned. The missing-lock pattern matches `jwtSecret`, but the at-rest
sealing makes a divergent secret consequential.
Suggestion: reuse the `apiKeyHmacSecretFileLock` (or a dedicated lock) around
load-or-create, mirroring `ensureAPIKeyHmacSecret`.
Status: open

### Issue 6 -- Severity: nit
File: Sources/BarkVisorCore/Services/LinuxHostBridgeApplyLive.swift:262-274, 672-759
Description: The setuid-helper restore depends on the pending record that is
written only after `setuidHelpers(...)` returns (line 273). If `writeLinux`
or `startRollbackTimer` throws between the chmod and the pending write,
`apply()`'s catch calls `revert`, `pending` is nil (or a stale prior record)
and the setuid/exec bits just added to `qemu-bridge-helper` are left on the
host with nothing to restore them. The window is small but real (it is
exactly the "chmod hit EROFS" case the owner-marker comment above anticipates).
Suggestion: write the pending record (with `helperModes`) before chmodding the
helpers, or capture/restore modes in a `defer` for the failure path.
Status: open

### Issue 7 -- Severity: nit
File: Sources/BarkVisorCore/Services/PairingJoin.swift:298-321; Sources/BarkVisorCore/Models/PairingDTOs.swift:118-159
Description: Mixed-version pairing: a pre-upgrade joiner ignores `identitySeal`
and pairs successfully but silently receives no shared login (no jwtSecret,
no admin row) — the operator is left with a "paired" device that cannot log in
to the issuer's account. The reverse direction (new joiner vs old issuer)
fails closed with a clear error, which is fine.
Suggestion: acceptable during a coordinated release, but if old joiners exist
in the field, keep a short overlap where the issuer still sends plaintext when
the request advertises an old apiVersion, or surface the missing shared login
in the joiner UI.
Status: open

## Summary
Security findings (#521-#526) are implemented correctly and fail closed:
redeem now seals `PairingSharedIdentity` under ECDH+AES-GCM, the joiner
rejects plaintext on the wire, the ttyd gate format is valid for ttyd 1.7.7,
the Ollama key round-trips under the new secret file with legacy read-through,
and the smoke scripts no longer default a well-known password. QEMU lifecycle
changes (#527-#529, #533) are sound and well-tested (QMP `server=on,wait=off`,
10s swtpm socket poll + `reconnect=5`, UDP hostfwd pre-start probe, ticker
failure recovery). Dead-code removal is clean. The main outstanding item is
Issue 1: the uid-owner iptables match broadens the filter's blast radius from
one VM to every process running as the drop user, affecting house-NAT traffic
and cross-VM Ollama grants, and per-VM cleanup now tears down other VMs'
filters.