import type { ComposeMount } from './composeMounts'
import { parseComposeMounts } from './composeMounts'

export type ComposePortRow = {
  hostPort: number
  containerPort: number
  proto: string
  hostIP?: string
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

function parsePortObject(raw: string): ComposePortRow | null {
  const text = raw.trim().replace(/^-\s+/, '')
  if (!/target:|published:|host_port:|container_port:/.test(text)) return null
  const fields: Record<string, string> = {}
  const body = text.replace(/^\{/, '').replace(/\}$/, '')
  for (const part of body.split(/[,\n]/)) {
    const m = part.match(/^\s*([A-Za-z_]+)\s*:\s*(.+?)\s*$/)
    if (!m) continue
    fields[m[1]] = unquote(m[2])
  }
  const published = Number(fields.published ?? fields.host_port)
  const target = Number(fields.target ?? fields.container_port)
  if (!isHostPort(published) || !isHostPort(target)) return null
  const proto = (fields.protocol || 'tcp').toLowerCase()
  const hostIP = fields.host_ip?.trim()
  return {
    hostPort: published,
    containerPort: target,
    proto,
    ...(hostIP ? { hostIP } : {}),
  }
}

function parsePortEntry(raw: string): ComposePortRow | null {
  const asObject = parsePortObject(raw)
  if (asObject) return asObject
  let line = unquote(raw.trim().replace(/^-\s+/, ''))
  let proto = 'tcp'
  const slash = line.lastIndexOf('/')
  if (slash >= 0) {
    const suffix = line.slice(slash + 1)
    if (!/^[a-zA-Z]+$/.test(suffix)) return null
    proto = suffix.toLowerCase()
    line = line.slice(0, slash)
  }
  let hostIP: string | undefined
  if (line.startsWith('[')) {
    const close = line.indexOf(']')
    if (close < 0) return null
    hostIP = line.slice(1, close)
    line = line.slice(close + 1)
    if (line.startsWith(':')) line = line.slice(1)
  }
  const parts = line.split(':')
  let host: number
  let container: number
  if (parts.length === 1) {
    host = Number(parts[0])
    container = host
  } else if (parts.length === 2) {
    host = Number(parts[0])
    container = Number(parts[1])
  } else if (parts.length === 3) {
    hostIP = hostIP ?? parts[0]
    host = Number(parts[1])
    container = Number(parts[2])
  } else {
    return null
  }
  if (!isHostPort(host) || !isHostPort(container)) return null
  return {
    hostPort: host,
    containerPort: container,
    proto,
    ...(hostIP ? { hostIP } : {}),
  }
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

function portHostPrefix(hostIP?: string): string {
  const ip = hostIP?.trim()
  if (!ip) return ''
  if (ip.includes(':') && !ip.startsWith('[')) return `[${ip}]:`
  return `${ip}:`
}

function portEntryText(row: ComposePortRow): string {
  const proto = row.proto && row.proto !== 'tcp' ? `/${row.proto}` : ''
  return `"${portHostPrefix(row.hostIP)}${row.hostPort}:${row.containerPort}${proto}"`
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

function parseMountPayload(payload: string): ComposeMountDraft | null {
  const text = unquote(payload.trim().replace(/^-\s+/, '').split('\n')[0] ?? '')
  const m = text.match(/^([^:]+):(\/[^:]+)(?::(ro|rw|z|Z))?$/)
  if (!m) return null
  const source = m[1].trim()
  const target = m[2].trim()
  if (!source || source.includes(' ') || !target.startsWith('/') || target === '/') return null
  return { source, target, readOnly: m[3] === 'ro' }
}

function listEntryLines(indent: string, entry: string): string[] {
  return entry.split('\n').map((part, i) => (i === 0 ? `${indent}- ${part}` : `${indent}  ${part}`))
}

type ListItem = {
  span: number[]
}

type ListBlock = {
  key: number
  keyName: string
  keyIndent: string
  items: ListItem[]
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
    const items: ListItem[] = []
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
        if (!items.length) entryIndent = indented[1]
        const span = [j]
        let k = j + 1
        for (; k < lines.length; k++) {
          const cont = lines[k]
          if (!cont.trim()) break
          const cIndent = cont.match(/^(\s*)/)?.[1].length ?? 0
          if (cIndent > indented[1].length && !/^\s*-\s+/.test(cont)) {
            span.push(k)
            continue
          }
          break
        }
        items.push({ span })
        j = k - 1
        continue
      }
      break
    }
    if (!items.length && !m[2]) {
      const next = lines.slice(i + 1).find((r) => r.trim() !== '')
      const nextIndent = next?.match(/^(\s*)/)?.[1].length ?? 0
      if (next && nextIndent > keyIndent.length && !next.trim().startsWith('-')) continue
    }
    blocks.push({ key: i, keyName: key, keyIndent, items, entryIndent, flow: Boolean(m[2]) })
  }
  return blocks
}

function blockPayloads(lines: string[], block: ListBlock): string[] {
  return block.items.map((item) =>
    item.span
      .map((idx, i) => {
        const raw = lines[idx].trim()
        return i === 0 ? raw.replace(/^-\s+/, '') : raw
      })
      .join('\n'),
  )
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
    block.items.forEach((item) => item.span.forEach((idx) => drop.add(idx)))
    if (!entries.length) {
      drop.add(block.key)
      return
    }
    if (block.flow) keyRewrite.set(block.key, `${block.keyIndent}${block.keyName}:`)
    insertAfter.set(block.key, entries.flatMap((entry) => listEntryLines(block.entryIndent, entry)))
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
  entries.forEach((entry) => out.push(...listEntryLines(`${anchor.indent}  `, entry)))
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
  const counts = blocks.map((block) => block.items.length)
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
  const lines = yaml.split('\n')
  const kept: string[] = []
  for (const block of findListBlocks(lines, 'ports')) {
    for (const payload of blockPayloads(lines, block)) {
      if (!parsePortEntry(payload)) kept.push(payload)
    }
  }
  return replaceListKey(yaml, 'ports', [
    ...rows.filter(isComposePortRow).map(portEntryText),
    ...kept,
  ])
}

export function setComposeMounts(yaml: string, mounts: ComposeMountDraft[]): string {
  const valid = mounts
    .map((mount) => composeMountFromDraft(mount))
    .filter((mount): mount is ComposeMountDraft => mount !== null)
  const lines = yaml.split('\n')
  const kept: string[] = []
  for (const block of findListBlocks(lines, 'volumes')) {
    for (const payload of blockPayloads(lines, block)) {
      if (!parseMountPayload(payload)) kept.push(payload)
    }
  }
  return replaceListKey(yaml, 'volumes', [...valid.map(mountEntryText), ...kept])
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

function yamlQuoted(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

function parseSharedPathItem(raw: string): string | null {
  const text = unquote(raw.trim().replace(/^-\s+/, ''))
  return text || null
}

function specChildIndent(document: string): { specLine: number; specIndent: number; childIndent: string } | null {
  const region = composeBlockRegion(document)
  const lines = document.split('\n')
  for (let i = 0; i < lines.length; i++) {
    if (region && i >= region.start && i < region.end) continue
    const m = lines[i].match(/^(\s*)spec:\s*$/)
    if (!m) continue
    return { specLine: i, specIndent: m[1].length, childIndent: `${m[1]}  ` }
  }
  return null
}

function sharedPathsBlock(document: string): { keyLine: number; itemEnd: number; flow: boolean } | null {
  const spec = specChildIndent(document)
  if (!spec) return null
  const region = composeBlockRegion(document)
  const lines = document.split('\n')
  for (let i = spec.specLine + 1; i < lines.length; i++) {
    if (region && i >= region.start && i < region.end) continue
    if (!lines[i].trim()) continue
    const indent = lines[i].match(/^(\s*)/)![1].length
    if (indent <= spec.specIndent) break
    const m = lines[i].match(/^(\s*)sharedPaths:\s*(\[[^\]]*\])?\s*$/)
    if (!m || m[1] !== spec.childIndent) continue
    let itemEnd = i + 1
    if (!m[2]) {
      for (let j = i + 1; j < lines.length; j++) {
        if (region && j >= region.start && j < region.end) break
        if (!lines[j].trim()) {
          itemEnd = j + 1
          continue
        }
        const jIndent = lines[j].match(/^(\s*)/)![1].length
        if (jIndent <= m[1].length) break
        itemEnd = j + 1
      }
    }
    return { keyLine: i, itemEnd, flow: Boolean(m[2]) }
  }
  return null
}

export function extractApplicationSharedPaths(document: string): string[] {
  const block = sharedPathsBlock(document)
  if (!block) return []
  const lines = document.split('\n')
  const key = lines[block.keyLine]
  const flow = key.match(/sharedPaths:\s*(\[[^\]]*\])\s*$/)
  if (flow?.[1]) {
    const inner = flow[1].slice(1, -1).trim()
    if (!inner) return []
    return inner.split(',').map((part) => parseSharedPathItem(part)).filter((row): row is string => row !== null)
  }
  const out: string[] = []
  for (let i = block.keyLine + 1; i < block.itemEnd; i++) {
    const row = lines[i].trim()
    if (!row.startsWith('-')) continue
    const parsed = parseSharedPathItem(row)
    if (parsed) out.push(parsed)
  }
  return out
}

export function replaceApplicationSharedPaths(document: string, paths: string[]): string {
  const spec = specChildIndent(document)
  if (!spec) return document
  const lines = document.split('\n')
  const block = sharedPathsBlock(document)
  const entries = paths.map((path) => `${spec.childIndent}  - ${yamlQuoted(path)}`)
  if (!paths.length) {
    if (!block) return document
    return [...lines.slice(0, block.keyLine), ...lines.slice(block.itemEnd)].join('\n')
  }
  if (block) {
    return [
      ...lines.slice(0, block.keyLine),
      `${spec.childIndent}sharedPaths:`,
      ...entries,
      ...lines.slice(block.itemEnd),
    ].join('\n')
  }
  let insertAt = spec.specLine + 1
  const region = composeBlockRegion(document)
  for (let i = spec.specLine + 1; i < lines.length; i++) {
    if (region && i >= region.start && i < region.end) continue
    if (!lines[i].trim()) continue
    const indent = lines[i].match(/^(\s*)/)![1].length
    if (indent <= spec.specIndent) break
    if (lines[i].startsWith(`${spec.childIndent}runtime:`)) {
      insertAt = i + 1
      break
    }
  }
  return [
    ...lines.slice(0, insertAt),
    `${spec.childIndent}sharedPaths:`,
    ...entries,
    ...lines.slice(insertAt),
  ].join('\n')
}

export function mergeApplicationSharedPaths(
  existing: string[] | undefined,
  previous: ComposeMount[],
  next: ComposeMountDraft[],
): string[] {
  const prevHosts = new Set(previous.filter((mount) => mount.kind === 'bind').map((mount) => mount.source))
  const nextHosts = next
    .map((row) => composeBindFromDraft(row))
    .filter((row): row is ComposeMountDraft => row !== null)
    .map((row) => row.source)
  const nextSet = new Set(nextHosts)
  const kept = (existing ?? []).filter((path) => {
    const key = sharedHostKey(path)
    if (nextSet.has(key)) return true
    if (prevHosts.has(key)) return false
    return true
  })
  const extra = nextHosts.filter((source) => !kept.some((path) => sharedHostKey(path) === source))
  return [...kept, ...extra]
}

export function ensureApplicationSharedPaths(
  document: string,
  previousCompose?: string | null,
  nextMounts?: ComposeMountDraft[],
): string {
  const compose = extractComposeBlock(document)
  if (compose === null) return document
  const previous = parseComposeMounts(previousCompose ?? compose)
  const mounts = nextMounts ?? previous.map((mount) => ({
    source: mount.source,
    target: mount.target,
    readOnly: mount.readOnly,
  }))
  return replaceApplicationSharedPaths(
    document,
    mergeApplicationSharedPaths(extractApplicationSharedPaths(document), previous, mounts),
  )
}

export function applyComposeDocumentDrafts(
  document: string,
  drafts: { ports?: ComposePortRow[]; mounts?: ComposeMountDraft[] },
): string | null {
  const compose = extractComposeBlock(document)
  if (compose === null) {
    return (drafts.ports?.length || drafts.mounts?.length) ? null : document
  }
  const next = replaceComposeBlock(document, applyComposeDrafts(compose, drafts))
  if (next === null) return null
  if (drafts.mounts === undefined) return next
  return replaceApplicationSharedPaths(
    next,
    mergeApplicationSharedPaths(
      extractApplicationSharedPaths(document),
      parseComposeMounts(compose),
      drafts.mounts,
    ),
  )
}
