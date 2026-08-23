# Homebrew packaging

Formula and operator scripts for a **macOS Device** installed with Homebrew.

This is not a Linux path. Linux uses systemd packages in [packaging/linux](../linux/README.md).

## What the formula installs

| Path | Role |
|------|------|
| `bin/barkvisor` | Device daemon |
| `bin/barkvisor-install-helper` | Optional copy of the privileged helper (PAS-292) |
| `libexec/dev.barkvisor.helper` | Ad-hoc signed helper (`codesign -s -`) kept in the keg |
| `share/barkvisor/frontend/` | SPA |
| `share/barkvisor/templates.json` | Built-in template catalog |
| `share/barkvisor/postinstall` | Creates `_barkvisor` and `/var/lib/barkvisor` |
| `share/barkvisor/dev.barkvisor.helper.plist` | MachServices LaunchDaemon template |
| `homebrew.mxcl.barkvisor.plist` | Root brew services unit (PAS-223 `AbandonProcessGroup`) |

Runtime QEMU, swtpm, socket_vmnet, and cdrtools come from Homebrew (`depends_on`). They are not in this keg.

## Install the Device daemon

From a checkout of this repo (no tap yet):

```sh
brew install --formula ./packaging/homebrew/barkvisor.rb
sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall"
sudo brew services start barkvisor
```

Open `http://localhost:7777` and finish first-launch setup. NAT Workloads work at this point.

Operator walkthrough: [docs/getting-started-homebrew.md](../../docs/getting-started-homebrew.md).

## Bridged networking (optional)

`brew services` does **not** load the privileged helper. NAT does not need it.

To install the helper into Apple's privileged locations:

```sh
sudo barkvisor-install-helper
```

That copies the **ad-hoc signed** keg helper to `/Library/PrivilegedHelperTools/dev.barkvisor.helper` and writes `/Library/LaunchDaemons/dev.barkvisor.helper.plist` with `MachServices` `dev.barkvisor.helper`. The formula also ad-hoc signs `bin/barkvisor` as `dev.barkvisor.app`. The helper accepts that client only under the Homebrew prefix; `.pkg` SMJobBless still requires the BarkVisor Team ID.

You still need Homebrew `socket_vmnet` for bridges.

Remove the helper later (the formula does not):

```sh
sudo launchctl bootout system/dev.barkvisor.helper
sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
```

## Maintainer notes

There is no public tap yet. Install from this checkout with `brew install --formula ./packaging/homebrew/barkvisor.rb`. When a tap exists, keep the tap formula identical to this file and bump the tap on each Device release.

After formula edits, run Homebrew's linter on this checkout:

```sh
brew style ./packaging/homebrew/barkvisor.rb
```

Do not attach bottles in this repo. `head` builds from source until a tap publishes bottles (`brew bottle` / GitHub Packages). Do not commit `sha256` bottle lines here until that tap is live.

## Tests

`Tests/BarkVisorTests/HomebrewFormulaTests.swift` covers the daemon formula.

`Tests/BarkVisorTests/HomebrewInstallHelperTests.swift` covers the helper copy, MachServices plist, and that NAT is documented as independent of the helper.
