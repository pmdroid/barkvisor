import { describe, expect, test } from 'bun:test'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const srcRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

function walk(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...walk(path))
    else if (entry.name.endsWith('.vue') || entry.name.endsWith('.ts')) out.push(path)
  }
  return out
}

function scriptOf(path: string, text: string): { script: string; offset: number } | null {
  if (path.endsWith('.ts')) return { script: text, offset: 0 }
  const match = text.match(/<script setup[^>]*>([\s\S]*?)<\/script>/)
  if (!match || match.index == null) return null
  return { script: match[1], offset: text.slice(0, match.index + match[0].indexOf(match[1])).split('\n').length - 1 }
}

function firstArg(block: string): string | null {
  const startAt = block.search(/\bwatch\s*\(/)
  if (startAt < 0) return null
  const start = block.indexOf('(', startAt) + 1
  let paren = 1
  let brack = 0
  let brace = 0
  for (let i = start; i < block.length; i++) {
    const ch = block[i]
    if (ch === '(') paren += 1
    else if (ch === ')') {
      paren -= 1
      if (paren === 0) return block.slice(start, i)
    } else if (ch === '[') brack += 1
    else if (ch === ']') brack -= 1
    else if (ch === '{') brace += 1
    else if (ch === '}') brace -= 1
    else if (ch === ',' && paren === 1 && brack === 0 && brace === 0) return block.slice(start, i)
  }
  return null
}

const skip = new Set([
  'watch', 'computed', 'ref', 'toRef', 'toRefs', 'storeToRefs',
  'true', 'false', 'null', 'undefined', 'const', 'let', 'as',
  'route', 'props', 'window', 'document',
])

describe('ops console mobile chrome', () => {
  test('phone breakpoint overlays the menu and stacks split chrome', () => {
    const css = readFileSync(join(srcRoot, 'style.css'), 'utf8')
    expect(css).toMatch(/@media \(max-width: 768px\)/)
    expect(css).toMatch(/\.sidebar\.mobile-open\s*\{[^}]*position:\s*fixed/)
    expect(css).toMatch(/\.split-frame\s*\{[^}]*flex-direction:\s*column/)
    expect(css).toMatch(/\.ops-toolbar\s*\{[^}]*flex-wrap:\s*wrap/)
    expect(css).toMatch(/\.list-col,\s*\.convos\s*\{[^}]*max-height:\s*40vh/)
  })
})

describe('watch sources are initialized first', () => {
  test('no watch() reads a later const/let', () => {
    const offenders: string[] = []
    for (const path of walk(srcRoot)) {
      if (path.endsWith('.test.ts')) continue
      const text = readFileSync(path, 'utf8')
      const parsed = scriptOf(path, text)
      if (!parsed) continue
      const lines = parsed.script.split('\n')
      const decl = new Map<string, number>()
      lines.forEach((line, idx) => {
        for (const name of line.matchAll(/\b(?:const|let)\s+([A-Za-z_]\w*)/g)) {
          if (!decl.has(name[1])) decl.set(name[1], idx + 1 + parsed.offset)
        }
      })
      lines.forEach((line, idx) => {
        if (!/\bwatch\s*\(/.test(line.replace(/\/\/.*$/, ''))) return
        const block = lines.slice(idx, idx + 20).map((row) => row.replace(/\/\/.*$/, '')).join('\n')
        const src = firstArg(block)
        if (!src) return
        const cleaned = src.replace(/\?\.[\w$]+/g, '').replace(/\.[\w$]+/g, '')
        for (const name of cleaned.matchAll(/\b([A-Za-z_]\w*)\b/g)) {
          const id = name[1]
          if (skip.has(id) || !decl.has(id)) continue
          const declared = decl.get(id)!
          const used = idx + 1 + parsed.offset
          if (declared > used) {
            offenders.push(`${path.slice(srcRoot.length + 1)}:${used} ${id} declared at ${declared}`)
          }
        }
      })
    }
    expect(offenders).toEqual([])
  })
})
