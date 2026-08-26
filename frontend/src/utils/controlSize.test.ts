import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..')

describe('shared control size', () => {
  test('buttons selects search and filter chips share --control-h', () => {
    const css = readFileSync(join(srcRoot, 'style.css'), 'utf8')
    expect(css).toContain('--control-h: 32px')
    expect(css).toMatch(/\.app-btn,[\s\S]*?height: var\(--control-h\)/)
    expect(css).toMatch(/\.ops-search \{[\s\S]*?height: var\(--control-h\)/)
    expect(css).toMatch(/\.fchip \{[\s\S]*?height: var\(--control-h\)/)
    expect(css).toMatch(/\.sidebar-scope select \{[\s\S]*?height: var\(--control-h\)/)
    const select = readFileSync(join(srcRoot, 'components/ui/AppSelect.vue'), 'utf8')
    expect(select).toContain('height: var(--control-h)')
    expect(select).not.toContain('height: 38px')
    const tabs = readFileSync(join(srcRoot, 'components/ui/TabGroup.vue'), 'utf8')
    expect(tabs).toContain('height: var(--control-h)')
  })
})
