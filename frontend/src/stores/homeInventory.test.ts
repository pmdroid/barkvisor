import { describe, expect, test } from 'bun:test'
import { createHomeInventory } from './homeInventory'

type Row = { id: string; name: string }

function device(hostId: string, reachability: 'ok' | 'unreachable' = 'ok') {
  return { hostId, role: 'member' as const, reachability }
}

describe('home inventory union (PAS-234)', () => {
  test('unreachable after a success keeps last-known rows and does not invent new ones', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('orb')
    await inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => [{ id: '1', name: 'wave1-ubuntu' }],
      asList: (data) => data as Row[],
    })
    expect(inv.listFor('orb')).toEqual([{ id: '1', name: 'wave1-ubuntu' }])

    let called = false
    await inv.fetchFor({
      device: { ...peer, reachability: 'unreachable' },
      canFetch: false,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => {
        called = true
        return [{ id: 'ghost', name: 'ghost' }]
      },
      asList: (data) => data as Row[],
    })
    expect(called).toBe(false)
    expect(inv.listFor('orb')).toEqual([{ id: '1', name: 'wave1-ubuntu' }])
    expect(inv.errorFor('orb')).toBeNull()
    expect(inv.isLoading('orb')).toBe(false)
  })

  test('unreachable on first miss does not invent a list', async () => {
    const inv = createHomeInventory<Row>()
    let called = false
    await inv.fetchFor({
      device: device('peer-down', 'unreachable'),
      canFetch: false,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => {
        called = true
        return [{ id: 'ghost', name: 'ghost' }]
      },
      asList: (data) => data as Row[],
    })
    expect(called).toBe(false)
    expect(inv.listFor('peer-down')).toEqual([])
    expect(inv.hasList('peer-down')).toBe(true)
    expect(inv.errorFor('peer-down')).toBeNull()
  })

  test('clear bumps fetch seq so an in-flight list cannot land after a new fetch', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('peer-1')
    let resolveOlder!: (rows: Row[]) => void
    const older = new Promise<Row[]>((resolve) => {
      resolveOlder = resolve
    })
    const first = inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: () => older,
      asList: (data) => data as Row[],
    })
    inv.clear()
    await inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => [{ id: 'new', name: 'new' }],
      asList: (data) => data as Row[],
    })
    resolveOlder([{ id: 'old', name: 'old' }])
    await first
    expect(inv.listFor('peer-1').map((row) => row.id)).toEqual(['new'])
  })

  test('a stale list does not overwrite a newer fetch', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('peer-1')
    let resolveOlder!: (rows: Row[]) => void
    let resolveNewer!: (rows: Row[]) => void
    const older = new Promise<Row[]>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<Row[]>((resolve) => {
      resolveNewer = resolve
    })
    const first = inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: () => older,
      asList: (data) => data as Row[],
    })
    const second = inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: () => newer,
      asList: (data) => data as Row[],
    })
    resolveNewer([{ id: 'new', name: 'new' }])
    await second
    resolveOlder([{ id: 'old', name: 'old' }])
    await first
    expect(inv.listFor('peer-1').map((row) => row.id)).toEqual(['new'])
    expect(inv.isLoading('peer-1')).toBe(false)
    expect(inv.errorFor('peer-1')).toBeNull()
  })

  test('an unreachable refresh does not leave loading stuck after a stale list arrives', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('peer-1')
    let resolveOlder!: (rows: Row[]) => void
    const older = new Promise<Row[]>((resolve) => {
      resolveOlder = resolve
    })
    const first = inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: () => older,
      asList: (data) => data as Row[],
    })
    expect(inv.isLoading('peer-1')).toBe(true)
    await inv.fetchFor({
      device: { ...peer, reachability: 'unreachable' },
      canFetch: false,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => [{ id: 'ghost', name: 'ghost' }],
      asList: (data) => data as Row[],
    })
    expect(inv.isLoading('peer-1')).toBe(false)
    resolveOlder([{ id: 'stale', name: 'stale' }])
    await first
    expect(inv.listFor('peer-1')).toEqual([])
    expect(inv.isLoading('peer-1')).toBe(false)
  })

  test('a failed fetch keeps the previous list and records the error', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('peer-1')
    await inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => [{ id: '1', name: 'nas' }],
      asList: (data) => data as Row[],
    })
    await inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => {
        throw new TypeError('Failed to fetch')
      },
      asList: (data) => data as Row[],
    })
    expect(inv.listFor('peer-1')).toEqual([{ id: '1', name: 'nas' }])
    expect(inv.errorFor('peer-1')).toBeTruthy()
  })

  test('rows fetched under the self placeholder stay visible after the real hostId arrives', async () => {
    const inv = createHomeInventory<Row>()
    await inv.fetchFor({
      device: { hostId: 'self', role: 'self' },
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load',
      request: async () => [{ id: '1', name: 'boot' }],
      asList: (data) => data as Row[],
    })
    expect(inv.listFor('self')).toEqual([{ id: '1', name: 'boot' }])
    expect(inv.listFor('box')).toEqual([])

    inv.noteSelf({ hostId: 'box', role: 'self' })
    expect(inv.listFor('box')).toEqual([{ id: '1', name: 'boot' }])
    expect(inv.listFor('self')).toEqual([{ id: '1', name: 'boot' }])
    expect(inv.hasList('box')).toBe(true)
    expect(inv.listFor('orb')).toEqual([])
  })

  test('omit policy drops live rows when the Device is unreachable', async () => {
    const inv = createHomeInventory<Row>()
    const peer = device('orb')
    await inv.fetchFor({
      device: peer,
      canFetch: true,
      unreachablePolicy: 'omit',
      loadError: 'Unable to load',
      request: async () => [{ id: '1', name: 'orb' }],
      asList: (data) => data as Row[],
    })
    await inv.fetchFor({
      device: { ...peer, reachability: 'unreachable' },
      canFetch: false,
      unreachablePolicy: 'omit',
      loadError: 'Unable to load',
      request: async () => [{ id: '1', name: 'orb' }],
      asList: (data) => data as Row[],
    })
    expect(inv.listFor('orb')).toEqual([])
    expect(inv.errorFor('orb')).toBeNull()
    expect(inv.isLoading('orb')).toBe(false)
  })
})
