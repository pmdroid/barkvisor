import type { ComposeMount } from './composeMounts'
import { parseComposeMounts } from './composeMounts'

export type ComposePortRow = {
  hostPort: number
  containerPort: number
  proto: string
}

export type ComposeMountDraft = {
  source: string
  target: string
  readOnly: boolean
}

function unquote(text: string): string {
  return text.trim().replace(/^["']|["']$/g, '')
}

function isHostPort(value: number): boolean {
  return Number.isInteger(value) && value >= 1 && value <= 65535
}

function parsePortEntry(raw: string): ComposePortRow | null {
  const line = unquote(raw.trim().replace(/^-\s+/, ''))
  const m = line.match(/^(\d+)(?::(\d+))?(?:\/([a-zA-Z]+))?$/)
  if (!m) return null
  const host = Number(m[1])
  const container = m[2] ? Number(m[2]) : host
  if (!isHostPort(host) || !isHostPort(container)) return null
  return { hostPort: host, containerPort: container, proto: (m[3] || 'tcp').toLowerCase() }
}

export function parseComposePorts(yaml: string): ComposePortRow[] {
  const lines = yaml.split('\n')
  const blocks = findListBlocks(lines, 'ports')
  if (!blocks.length) return []
  const out: ComposePortRow[] = []
  for (const row of blocks.flatMap((block) => blockPayloads(lines, block))) {
    const parsed = parsePortEntry(row)
    if (parsed) out.push(parsed)
  }
  return out
}

export function isComposePortRow(row: ComposePortRow): boolean {
  return isHostPort(row.hostPort) && isHostPort(row.containerPort)
}

function portEntryText(row: ComposePortRow): string {
  const proto = row.proto && row.proto !== 'tcp' ? `/${row.proto}` : ''
  return `"${row.hostPort}:${row.containerPort}${proto}"`
}

function mountEntryText(mount: ComposeMountDraft): string {
  return `"${mount.source}:${mount.target}${mount.readOnly ? ':ro' : ''}"`
}

function payloadMatches(payload: string, mount: ComposeMountDraft): boolean {
  const text = unquote(payload)
  const parts = text.split(':')
  if (parts.length < 2 || parts.length > 3) return false
  if (parts.length === 3 && !['ro', 'rw', 'z', 'Z'].includes(parts[2])) return false
  if (parts[0] !== mount.source || parts[1] !== mount.target) return false
  const ro = parts[2] === 'ro'
  return ro === mount.readOnly
}

type ListBlock = {
  key: number
  keyName: string
  keyIndent: string
  entries: number[]
  entryIndent: string
  flow: boolean
}

function findListBlocks(lines: string[], key: string): ListBlock[] {
  const blocks: ListBlock[] = []
  const keyRe = new RegExp(`^(\\s*)${key}:\\s*(\\[\\s*\\])?\\s*(#.*)?$`)
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(keyRe)
    if (!m) continue
    const keyIndent = m[1]
    const entries: number[] = []
    let entryIndent = `${keyIndent}  `
    let j = i + 1
    for (; j < lines.length; j++) {
      const row = lines[j]
      if (!row.trim()) {
        const next = lines.slice(j + 1).find((r) => r.trim() !== '')
        const nextIndent = next?.match(/^(\s*)/)?.[1].length ?? 0
        if (next && next.trim().startsWith('-') && nextIndent > keyIndent.length) continue
        break
      }
      const indented = row.match(/^(\s*)-\s+(\S.*)$/)
      if (indented && indented[1].length > keyIndent.length) {
        if (!entries.length) entryIndent = indented[1]
        entries.push(j)
        continue
      }
      break
    }
    if (!entries.length && !m[2]) {
      const next = lines.slice(i + 1).find((r) => r.trim() !== '')
      const nextIndent = next?.match(/^(\s*)/)?.[1].length ?? 0
      if (next && nextIndent > keyIndent.length && !next.trim().startsWith('-')) continue
    }
    blocks.push({ key: i, keyName: key, keyIndent, entries, entryIndent, flow: Boolean(m[2]) })
  }
  return blocks
}

function blockPayloads(lines: string[], block: ListBlock): string[] {
  return block.entries.map((idx) => lines[idx].trim().replace(/^-\s+/, ''))
}

function applyBlocks(
  lines: string[],
  blocks: ListBlock[],
  perBlock: string[][],
): string {
  const drop = new Set<number>()
  const insertAfter = new Map<number, string[]>()
  const keyRewrite = new Map<number, string>()
  blocks.forEach((block, b) => {
    const entries = perBlock[b] ?? []
    block.entries.forEach((idx) => drop.add(idx))
    if (!entries.length) {
      drop.add(block.key)
      return
    }
    if (block.flow) keyRewrite.set(block.key, `${block.keyIndent}${block.keyName}:`)
    insertAfter.set(block.key, entries.map((entry) => `${block.entryIndent}- ${entry}`))
  })
  const out: string[] = []
  lines.forEach((line, i) => {
    if (drop.has(i)) return
    out.push(keyRewrite.get(i) ?? line)
    const extra = insertAfter.get(i)
    if (extra) out.push(...extra)
  })
  return out.join('\n')
}

function serviceChildAnchor(lines: string[]): { indent: string; after: number } {
  const imageIdx = lines.findIndex((row) => /^\s*image:/.test(row))
  if (imageIdx >= 0) {
    return { indent: lines[imageIdx].match(/^(\s*)/)?.[1] ?? '    ', after: imageIdx }
  }
  const servicesIdx = lines.findIndex((row) => /^\s*services:\s*$/.test(row))
  if (servicesIdx >= 0) {
    for (let i = servicesIdx + 1; i < lines.length; i++) {
      const m = lines[i].match(/^(\s+)[^\s:#]+:\s*$/)
      if (m) return { indent: `${m[1]}  `, after: i }
    }
  }
  return { indent: '    ', after: lines.length - 1 }
}

function insertFreshBlock(yaml: string, key: string, entries: string[]): string {
  const lines = yaml.split('\n')
  const anchor = serviceChildAnchor(lines)
  const out = lines.slice(0, anchor.after + 1)
  out.push(`${anchor.indent}${key}:`)
  entries.forEach((entry) => out.push(`${anchor.indent}  - ${entry}`))
  out.push(...lines.slice(anchor.after + 1))
  return out.join('\n')
}

function replaceListKey(yaml: string, key: string, entries: string[]): string {
  const lines = yaml.split('\n')
  const blocks = findListBlocks(lines, key)
  if (!blocks.length) {
    if (!entries.length) return yaml
    return insertFreshBlock(yaml, key, entries)
  }
  const counts = blocks.map((block) => block.entries.length)
  const allocation: number[] = []
  let remaining = entries.length
  blocks.forEach((_, b) => {
    allocation.push(Math.min(counts[b], remaining))
    remaining -= allocation[b]
  })
  if (remaining > 0) allocation[allocation.length - 1] += remaining
  let cursor = 0
  const perBlock = allocation.map((count) => {
    const slice = entries.slice(cursor, cursor + count)
    cursor += count
    return slice
  })
  return applyBlocks(lines, blocks, perBlock)
}

export function setComposePorts(yaml: string, rows: ComposePortRow[]): string {
  return replaceListKey(yaml, 'ports', rows.filter(isComposePortRow).map(portEntryText))
}

export function setComposeMounts(yaml: string, mounts: ComposeMountDraft[]): string {
  const valid = mounts
    .map((mount) => composeMountFromDraft(mount))
    .filter((mount): mount is ComposeMountDraft => mount !== null)
  return replaceListKey(yaml, 'volumes', valid.map(mountEntryText))
}

export function applyComposeDrafts(
  compose: string,
  drafts: { ports?: ComposePortRow[]; mounts?: ComposeMountDraft[] },
): string {
  let next = compose
  if (drafts.ports !== undefined) next = setComposePorts(next, drafts.ports)
  if (drafts.mounts !== undefined) next = setComposeMounts(next, drafts.mounts)
  return next
}

export function addComposeMount(yaml: string, mount: ComposeMountDraft): string {
  const exists = parseComposeMounts(yaml).some(
    (row) => row.source === mount.source && row.target === mount.target,
  )
  if (exists) return yaml
  const lines = yaml.split('\n')
  const blocks = findListBlocks(lines, 'volumes')
  if (!blocks.length) {
    return insertFreshBlock(yaml, 'volumes', [mountEntryText(mount)])
  }
  const first = blocks[0]
  return applyBlocks(lines, [first], [[...blockPayloads(lines, first), mountEntryText(mount)]])
}

export function removeComposeMount(yaml: string, mount: ComposeMountDraft): string {
  const lines = yaml.split('\n')
  const blocks = findListBlocks(lines, 'volumes')
  if (!blocks.length) return yaml
  const perBlock = blocks.map((block) =>
    blockPayloads(lines, block).filter((payload) => !payloadMatches(payload, mount)),
  )
  return applyBlocks(lines, blocks, perBlock)
}

function composeBlockRegion(document: string): { start: number; end: number; minIndent: number; keyLine: number } | null {
  const lines = document.split('\n')
  const keyLine = lines.findIndex((row) => /^(\s*)compose:\s*[|>][-+]?\s*$/.test(row))
  if (keyLine < 0) return null
  const keyIndent = lines[keyLine].match(/^(\s*)/)![1].length
  let end = lines.length
  for (let j = keyLine + 1; j < lines.length; j++) {
    if (!lines[j].trim()) continue
    if ((lines[j].match(/^(\s*)/)![1].length) <= keyIndent) {
      end = j
      break
    }
  }
  const body = lines.slice(keyLine + 1, end).filter((row) => row.trim())
  if (!body.length) return null
  const minIndent = Math.min(...body.map((row) => row.match(/^(\s*)/)![1].length))
  if (minIndent <= keyIndent) return null
  return { start: keyLine + 1, end, minIndent, keyLine }
}

export function extractComposeBlock(document: string): string | null {
  const region = composeBlockRegion(document)
  if (!region) return null
  const lines = document.split('\n')
  return lines
    .slice(region.start, region.end)
    .map((row) => (row.trim() ? row.slice(region.minIndent) : ''))
    .join('\n')
    .replace(/\s+$/, '')
}

export function replaceComposeBlock(document: string, compose: string): string | null {
  const region = composeBlockRegion(document)
  if (!region) return null
  const lines = document.split('\n')
  const pad = ' '.repeat(region.minIndent)
  const block = compose.replace(/\s+$/, '').split('\n').map((row) => (row.trim() ? `${pad}${row}` : ''))
  return [...lines.slice(0, region.start), ...block, ...lines.slice(region.end)].join('\n')
}

export function sharedHostKey(path: string): string {
  let raw = path.trim()
  if (raw.endsWith(':ro')) raw = raw.slice(0, -3)
  else if (raw.endsWith(':rw')) raw = raw.slice(0, -3)
  const i = raw.lastIndexOf(':')
  if (i > 0 && raw.slice(i + 1).startsWith('/')) return raw.slice(0, i)
  return raw
}

export function retainUsedPaths(paths: string[] | null | undefined, mounts: ComposeMount[]): string[] {
  const used = new Set(mounts.map((mount) => mount.source))
  return (paths ?? []).filter((path) => used.has(sharedHostKey(path)))
}

export function afterRemoveSharedPaths(
  paths: string[] | null | undefined,
  mount: ComposeMountDraft,
  remaining: ComposeMount[],
): string[] {
  if (remaining.length) return retainUsedPaths(paths, remaining)
  return (paths ?? []).filter((path) => sharedHostKey(path) !== mount.source)
}

export function composeMountFromDraft(draft: ComposeMountDraft): ComposeMountDraft | null {
  const source = draft.source.trim()
  const target = draft.target.trim()
  if (!source || source.includes(' ') || !target.startsWith('/') || target === '/') return null
  return { source, target, readOnly: draft.readOnly }
}

export function composeBindFromDraft(draft: ComposeMountDraft): ComposeMountDraft | null {
  const mount = composeMountFromDraft(draft)
  if (!mount?.source.startsWith('/')) return null
  return mount
}

export function applyComposeDocumentDrafts(
  document: string,
  drafts: { ports?: ComposePortRow[]; mounts?: ComposeMountDraft[] },
): string | null {
  const compose = extractComposeBlock(document)
  if (compose === null) {
    return (drafts.ports?.length || drafts.mounts?.length) ? null : document
  }
  return replaceComposeBlock(document, applyComposeDrafts(compose, drafts))
}
