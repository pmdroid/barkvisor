import { describe, expect, test } from 'bun:test'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEVICE_CPU_LABEL,
  DEVICE_LABEL,
  DEVICE_MEMORY_LABEL,
  FORBIDDEN_PRODUCT_TERMS,
  HOME_LABEL,
  HOME_OF_ONE,
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

const forbiddenTemplateRe =
  /\b(?:nodes?|clusters?|datacenters?|quorums?)\b|\bdata\s+centers?\b/i

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

describe('PAS-82 Home terminology', () => {
  test('exports Home labels (not cluster)', () => {
    expect(HOME_LABEL).toBe('Home')
    expect(HOME_OF_ONE).toBe('Home of one')
    expect(FORBIDDEN_PRODUCT_TERMS).toContain('cluster')
    expect(FORBIDDEN_PRODUCT_TERMS).toContain('datacenter')
    expect(FORBIDDEN_PRODUCT_TERMS).toContain('quorum')
    expect(HOME_LABEL.toLowerCase()).not.toContain('cluster')
  })

  test('shared docs table names Home and forbids cluster jargon', () => {
    const text = readFileSync(join(docsRoot, 'product-terminology.md'), 'utf8')
    expect(text).toContain('**Home**')
    expect(text).toContain('**Library**')
    expect(text).toContain('Home of one')
    expect(text).toMatch(/\*\*Cluster\*\*.*Do not use/s)
    expect(text).toMatch(/\*\*Datacenter\*\*.*Do not use/s)
    expect(text).toMatch(/\*\*Quorum\*\*.*Do not use/s)
    expect(text).toContain('getting-started-first-launch.md')
    expect(text).not.toContain('/api/home/*` — shipped')
  })

  test('getting-started links the shared Home glossary', () => {
    const first = readFileSync(join(docsRoot, 'getting-started-first-launch.md'), 'utf8')
    expect(first).toContain('product-terminology.md')
    expect(first).toMatch(/\bHome\b/)
    const quick = readFileSync(join(docsRoot, 'getting-started-quickstart.md'), 'utf8')
    expect(quick).toContain('product-terminology.md')
    expect(quick).toMatch(/\bHome\b/)
  })

  test('SPA templates do not use cluster, datacenter, or quorum', () => {
    const offenders: string[] = []
    for (const file of walkVue(srcRoot)) {
      const text = readFileSync(file, 'utf8')
      const templates = [...text.matchAll(/<template[\s\S]*?<\/template>/g)].map((m) => m[0])
      for (const block of templates) {
        if (forbiddenTemplateRe.test(block)) offenders.push(file.replace(`${srcRoot}/`, ''))
      }
    }
    expect(offenders).toEqual([])
  })

  test('setup ready copy names this device a Home', () => {
    const text = readFileSync(join(srcRoot, 'views/SetupView.vue'), 'utf8')
    expect(text).toContain('HOME_LABEL')
    expect(text).toContain('This device is your')
    expect(text).not.toMatch(forbiddenTemplateRe)
  })

  test('orphaned onboarding overlay and unrouted About view are gone', () => {
    expect(existsSync(join(srcRoot, 'components/OnboardingWizard.vue'))).toBe(false)
    expect(existsSync(join(srcRoot, 'views/AboutView.vue'))).toBe(false)
  })
})
