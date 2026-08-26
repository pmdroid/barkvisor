import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..')

describe('modal light mode', () => {
  test('modal and split-frame use theme surface tokens', () => {
    const css = readFileSync(join(srcRoot, 'style.css'), 'utf8')
    expect(css).toContain('--modal-surface: #0c1118')
    expect(css).toContain('--modal-surface: #ffffff')
    expect(css).toMatch(/\.modal \{[\s\S]*?background: var\(--modal-surface\)/)
    expect(css).toMatch(/\.split-frame \{[\s\S]*?background: var\(--modal-surface\)/)
    expect(css).toMatch(/\.modal-overlay \{[\s\S]*?background: var\(--modal-overlay-bg\)/)
    expect(css).not.toMatch(/\.modal \{\s*background: #0c1118/)
    expect(css).not.toMatch(/\.split-frame \{[\s\S]{0,180}background: #0c1118/)
  })

  test('FolderPicker teleports above the host dialog', () => {
    const text = readFileSync(join(srcRoot, 'components/FolderPicker.vue'), 'utf8')
    expect(text).toContain('Teleport')
    expect(text).toContain('split-frame')
    expect(text).toContain('apiErrorMessage')
    expect(text).toContain('modal-overlay stack')
  })

  test('USB picker teleports out of the Create VM frame', () => {
    const text = readFileSync(join(srcRoot, 'components/create-vm/CreateVMNetworkStep.vue'), 'utf8')
    expect(text).toContain('Teleport')
    expect(text).toContain('modal-overlay stack')
  })
})
