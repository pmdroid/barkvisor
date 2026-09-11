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
    expect(text).toContain('folderBrowseRequestPath')
    expect(text).toContain('modelValue')
    expect(text).toContain('withFolderParentEntry')
  })

  test('log stream uses theme term tokens, not a hardcoded dark pane', () => {
    const css = readFileSync(join(srcRoot, 'style.css'), 'utf8')
    expect(css).toContain('--term-bg: #070a10')
    expect(css).toContain('--term-bg: #ffffff')
    expect(css).toMatch(/\.term \{[\s\S]*?background: var\(--term-bg\)/)
    expect(css).not.toMatch(/\.term \{[\s\S]{0,180}background: #070a10/)
    expect(css).toMatch(/\.term-head \{[\s\S]*?background: var\(--term-head-bg\)/)
    expect(css).toMatch(/\.line:hover \{ background: var\(--term-row-hover\)/)
  })

  test('compose log pane matches device log tokens, not a hardcoded dark pane', () => {
    const css = readFileSync(join(srcRoot, 'style.css'), 'utf8')
    const panel = readFileSync(join(srcRoot, 'components/ComposeLogsPanel.vue'), 'utf8')
    expect(css).toContain('--log-dim-bg: rgba(0, 0, 0, 0.2)')
    expect(css).toContain('--log-dim-bg: rgba(0, 0, 0, 0.04)')
    expect(panel).toMatch(/\.terminal \{[\s\S]*?background: var\(--log-dim-bg\)/)
    expect(panel).not.toMatch(/\.terminal \{[\s\S]{0,180}background: #[0-9a-f]{6}/)
    expect(panel).toMatch(/\.line \{[\s\S]{0,80}color: var\(--text-secondary\)/)
    expect(panel).not.toMatch(/background:\s*#[0-3][0-9a-f]{5}/)
  })

  test('USB picker teleports out of the Create VM frame', () => {
    const text = readFileSync(join(srcRoot, 'components/create-vm/CreateVMNetworkStep.vue'), 'utf8')
    expect(text).toContain('Teleport')
    expect(text).toContain('modal-overlay stack')
  })

  test('magazine Create VM uses theme surface tokens', () => {
    const text = readFileSync(join(srcRoot, 'components/CreateVMDrawer.vue'), 'utf8')
    expect(text).toMatch(/\.mag-overlay \{[\s\S]*?background: var\(--modal-overlay-bg\)/)
    expect(text).toMatch(/\.mag-frame \{[\s\S]*?background: var\(--modal-surface\)/)
    expect(text).toContain('--mag-text: var(--text)')
    expect(text).toContain('--mag-line: var(--line)')
    expect(text).not.toMatch(/\.mag-frame \{[\s\S]{0,220}background: #0c1118/)
    expect(text).not.toContain('--mag-bg: #0a0e14')
  })
})
