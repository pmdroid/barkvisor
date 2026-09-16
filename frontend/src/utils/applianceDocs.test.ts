import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const docsRoot = join(here, '../../../docs')

function read(name: string): string {
  return readFileSync(join(docsRoot, name), 'utf8')
}

describe('appliance getting-started (#382)', () => {
  test('macOS install is .pkg, inspect-then-run, Settings Updates', () => {
    const text = read('getting-started-installation.md')
    expect(text).toContain('get-barkvisor.sh')
    expect(text).toContain('less get-barkvisor.sh')
    expect(text).toContain('.pkg')
    expect(text).toContain('Settings → Updates')
    expect(text).toContain('not through Homebrew')
    expect(text).toContain('Do not run Homebrew with `sudo`')
    expect(text).toContain('brew install qemu swtpm socket_vmnet')
    expect(text).not.toContain('sudo brew services restart barkvisor')
    expect(text).not.toMatch(/\bcluster\b/)
    expect(text).not.toMatch(/\bquorum\b/)
  })

  test('Linux install is Ubuntu/Debian .deb and never default-deletes br0', () => {
    const text = read('getting-started-linux.md')
    expect(text).toContain('Ubuntu')
    expect(text).toContain('Debian')
    expect(text).toContain('.deb')
    expect(text).toContain('root systemd service')
    expect(text).toContain('Settings → Updates')
    expect(text).toContain('shared bridges remain')
    expect(text).toContain('Keep changes')
    expect(text).toContain('within 60 seconds or BarkVisor rolls them back')
    expect(text).not.toContain('### Fedora')
    expect(text).not.toContain('sudo dnf install')
    expect(text).not.toMatch(/\bcluster\b/)
    expect(text).not.toMatch(/\bquorum\b/)
  })

  test('Networks docs explain bridge creation and safe rollback in the console', () => {
    const text = read('using-networks.md')
    expect(text).toContain('Apply')
    expect(text).toContain('Revert')
    expect(text).toContain('Keep changes')
    expect(text).toContain('within 60 seconds')
    expect(text).toContain('BarkVisor rolls them back')
    expect(text).toContain('Linux Wi-Fi interfaces and ifupdown-managed configurations are not supported')
    expect(text).toContain('Create → Bridge')
    expect(text).toContain('suggested bridge name')
    expect(text).toContain('including Wi-Fi')
    expect(text).not.toContain('macOS has no Create Bridge')
    expect(text).not.toContain('Create VM network')
    expect(text).toContain('brew install socket_vmnet')
    expect(text).toContain('Host interfaces')
    expect(text).toContain('VM networks')
    expect(text).not.toContain('Networks → Bridge setup')
    expect(text).not.toContain('## Bridge setup')
    expect(text).toMatch(/\bDevice\b/)
    expect(text).toContain('workload references')
  })

  test('Settings docs name Updates for root appliances', () => {
    const settings = read('using-settings.md')
    expect(settings).toContain('settings-updates.md')
    expect(settings).toContain('updates')
    const updates = read('settings-updates.md')
    expect(updates).toContain('Settings → Updates')
    expect(updates).toContain('not BarkVisor itself')
    expect(updates).toContain('The data directory stays in place')
    expect(updates).toContain('If the checksum is missing or incorrect, the update stops')
    expect(updates).toContain('Windows zip and portable Linux tarball installations need a manual update')
  })

  test('README leads with packages and links to contributor build instructions', () => {
    const text = read('../README.md')
    expect(text).toContain('Use a prebuilt package')
    expect(text).toContain('docs/getting-started-development.md')
    expect(text).not.toContain('swift build')
    expect(text).not.toContain('bun install')
    expect(text.indexOf('## Install BarkVisor')).toBeLessThan(text.indexOf('## Contributing'))
  })
})
