import { describe, expect, test } from 'bun:test'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEVICE_CPU_LABEL,
  DEVICE_LABEL,
  DEVICE_MEMORY_LABEL,
  NETWORKS_NAV_LABEL,
  THIS_DEVICE,
} from './terminology'

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..')
const docsRoot = join(here, '../../../docs')

function walkVue(dir: string): string[] {
  const out: string[] = []
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    const st = statSync(path)
    if (st.isDirectory()) out.push(...walkVue(path))
    else if (name.endsWith('.vue')) out.push(path)
  }
  return out
}

describe('PAS-97 Device terminology', () => {
  test('exports Device labels (not node)', () => {
    expect(DEVICE_LABEL).toBe('Device')
    expect(DEVICE_CPU_LABEL).toBe('Device CPU')
    expect(DEVICE_MEMORY_LABEL).toBe('Device Memory')
    expect(THIS_DEVICE).toBe('this device')
    expect(NETWORKS_NAV_LABEL).toBe('Networks')
    expect(DEVICE_LABEL.toLowerCase()).not.toContain('node')
  })

  test('shared docs table names Device and forbids node', () => {
    const text = readFileSync(join(docsRoot, 'product-terminology.md'), 'utf8')
    expect(text).toContain('**Device**')
    expect(text).toContain('**Home**')
    expect(text).toMatch(/\*\*Node\*\*.*Do not use/s)
    expect(text).toContain('Settings → Network')
    expect(text).toContain('hostId')
  })

  test('SPA templates do not use node as a product term', () => {
    const offenders: string[] = []
    for (const file of walkVue(srcRoot)) {
      const text = readFileSync(file, 'utf8')
      const templates = [...text.matchAll(/<template[\s\S]*?<\/template>/g)].map((m) => m[0])
      for (const block of templates) {
        if (/\bnodes?\b/i.test(block)) offenders.push(file.replace(`${srcRoot}/`, ''))
      }
    }
    expect(offenders).toEqual([])
  })

  test('create/deploy copy no longer points at Settings → Network', () => {
    const files = [
      join(srcRoot, 'components/create-vm/CreateVMNetworkStep.vue'),
      join(srcRoot, 'components/TemplateDeployDrawer.vue'),
    ]
    for (const file of files) {
      const text = readFileSync(file, 'utf8')
      expect(text).not.toMatch(/Settings\s*&rarr;\s*Network/)
      expect(text).not.toMatch(/Settings\s*→\s*Network/)
      expect(text).toContain('to="/networks"')
    }
  })
})
