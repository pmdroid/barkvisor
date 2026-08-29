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
    expect(text).toContain('Do not `brew upgrade barkvisor`')
    expect(text).toContain('Do not `sudo brew install`')
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
    expect(text).toContain('User=root')
    expect(text).toContain('Settings → Updates')
    expect(text).toContain('default-deleted')
    expect(text).toContain('host timer')
    expect(text).not.toContain('### Fedora')
    expect(text).not.toContain('sudo dnf install')
    expect(text).not.toMatch(/\bcluster\b/)
    expect(text).not.toMatch(/\bquorum\b/)
  })

  test('Networks docs apply host bridge and keep equivalent commands', () => {
    const text = read('using-networks.md')
    expect(text).toContain('Apply')
    expect(text).toContain('linux-bridge-apply.sh')
    expect(text).toContain('host timer')
    expect(text).toContain('Wi-Fi is refused')
    expect(text).toContain('brew install socket_vmnet')
    expect(text).toMatch(/\bHome\b/)
    expect(text).toMatch(/\bDevice\b/)
    expect(text).toMatch(/\bWorkload\b/)
  })

  test('Settings docs name Updates for root appliances', () => {
    const settings = read('using-settings.md')
    expect(settings).toContain('settings-updates.md')
    expect(settings).toContain('updates')
    const updates = read('settings-updates.md')
    expect(updates).toContain('Settings → Updates')
    expect(updates).toContain('Do not `brew upgrade barkvisor`')
    expect(updates).toContain('/var/lib/barkvisor')
  })
})
