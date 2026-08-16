# Guest-boot CI and the self-hosted KVM runner

Optional GitHub Actions lanes that start a real QEMU Workload. They live in
[`.github/workflows/guest-boot.yml`](../.github/workflows/guest-boot.yml) and
are **never a required status check**. Required PR gates stay in
[`ci.yml`](../.github/workflows/ci.yml) (lint, build, test, linux-build).

A Device still runs if other Devices in the Home are unreachable. Local
SQLite owns Workload runtime. These lanes only prove guest boot on one
Linux Device; they do not invent a second control plane.

## What runs

| Lane | Runner | When | What |
|------|--------|------|------|
| Tier 1 blank | `ubuntu-24.04` | every PR and push to `main` | Probe `/dev/kvm`. If usable, install QEMU + OVMF, run `scripts/guest-boot-bdd.sh blank`. Else **SKIP** (exit 0). Never TCG. |
| Tier 1 REAL_GUEST | `ubuntu-24.04` | nightly schedule, `run-guest-boot` PR label, or `workflow_dispatch` with `real_guest` | Same probe, then `scripts/guest-boot-bdd.sh real` (Ubuntu cloud image + SSH). |
| Tier 2 blank | `[self-hosted, linux, kvm]` | only if repo variable `KVM_RUNNER_ENABLED=true` | Blank-disk smoke. Missing runners never hang PRs because the job `if:` is false when the variable is unset. |
| Tier 2 REAL_GUEST | `[self-hosted, linux, kvm]` | `KVM_RUNNER_ENABLED=true` **and** nightly / label / dispatch | Cloud-image + SSH smoke on the operator’s KVM Device. |

Smoke logs (`server.log` under `BARKVISOR_DATA_DIR`) upload as Actions
artifacts on every run, including failures.

`mise run prepush` stays lint + Swift tests + frontend tests. Do **not** add
guest-boot to the default push gate. Local opt-in remains:

```sh
mise run guest-smoke        # blank disk
mise run guest-smoke-real   # REAL_GUEST=1
```

## Do not make this required

Do not add `Guest Boot` (or any job name from `guest-boot.yml`) to
branch-protection required checks until the lanes have been stable for a
while **and** an operator explicitly asks. A missing `/dev/kvm` on
GitHub-hosted runners must stay a skip, not a red required check.

## Repo variable: `KVM_RUNNER_ENABLED`

GitHub → Settings → Secrets and variables → Actions → Variables:

| Name | Value | Effect |
|------|--------|--------|
| `KVM_RUNNER_ENABLED` | `true` | Queue the self-hosted jobs. |
| unset / anything else | — | Self-hosted jobs are skipped. PRs never wait for a runner. |

Set the variable only after a runner with labels `linux` and `kvm` is
online. If the variable is `true` and the runner is offline, GitHub will
wait for it.

## Register a self-hosted runner

Use a dedicated Linux Device (x86_64 or aarch64) with hardware
virtualization. One process ↔ one Device ↔ one data directory still
applies: give Actions an ephemeral working directory, not the
production `BARKVISOR_DATA_DIR`.

### 1. Packages

Ubuntu / Debian:

```sh
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-system-x86 qemu-system-arm qemu-utils ovmf \
  genisoimage jq python3 curl ca-certificates \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev \
  swtpm
```

Fedora / RHEL-family: `qemu-kvm`, `edk2-ovmf`, `genisoimage`, `jq`, `swtpm`.

`swtpm` is optional for these Linux smokes and required later for Windows
guests with TPM.

### 2. KVM access

```sh
ls -l /dev/kvm
sudo usermod -aG kvm "$USER"
# log out and back in so the group applies
test -r /dev/kvm && test -w /dev/kvm && echo "kvm ok"
```

The Actions user must be able to read **and** write `/dev/kvm`.

### 3. Swift

```sh
./scripts/install-swift-linux.sh
echo /opt/swift/usr/bin >> ~/.profile
```

The workflow also runs that script when `swift` is not on `PATH`.

### 4. GitHub runner labels

Install the GitHub Actions runner for this repository (not an org-wide
wildcard unless you intend that). Required labels:

- `self-hosted` (added automatically)
- `linux`
- `kvm`

Match `runs-on: [self-hosted, linux, kvm]` exactly.

### 5. Enable the lane

1. Confirm the runner is Idle in the repo’s Actions → Runners list.
2. Set `KVM_RUNNER_ENABLED=true`.
3. Dispatch **Guest Boot** once from the Actions tab (`real_guest` optional).

## PR label `run-guest-boot`

Add the `run-guest-boot` label to a pull request to run REAL_GUEST on
that PR (hosted if `/dev/kvm` is usable, plus self-hosted when the
variable is on). Unlabelled PRs only attempt the blank-disk hosted probe.

Create the label if it is missing:

```sh
gh label create run-guest-boot --description "Run REAL_GUEST guest-boot CI on this PR" --color 0E8A16
```

## What this is not

- Not a required check.
- Not macOS / HVF guest boot in CI.
- Not a Windows ISO boot (the `windows-amd64` guest profile is separate).
- Not a multi-Device Home orchestration in CI. Cross-Device smoke stays
  local and opt-in (`mise run cross-device-smoke`).
- Not a replacement for `mise run prepush`.

## Related

- [Development — Guest-boot BDD](getting-started-development.md#guest-boot-bdd-opt-in-not-prepush)
- [Installation (Linux)](getting-started-linux.md)
- [Product terminology](product-terminology.md)
