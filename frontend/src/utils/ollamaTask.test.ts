import { describe, expect, test } from 'bun:test'
import {
  ollamaModelMatchesName,
  ollamaPullPercent,
  ollamaPullTaskPath,
  ollamaRunningHostId,
  ollamaDefaultStartHostId,
  ollamaSoleStartHostId,
  ollamaStartBody,
  ollamaStartLocations,
  ollamaStartNeedsPicker,
  ollamaStartCanStart,
  ollamaStartCandidates,
  ollamaStartDisabledReason,
} from './ollamaTask'

describe('ollama pull/start helpers (PAS-269)', () => {
  test('local pull uses Device task path', () => {
    expect(ollamaPullTaskPath({ taskID: 't1', hostId: 'self' }, 'self')).toBe('/tasks/t1')
  })

  test('member pull uses Home proxy task path', () => {
    expect(ollamaPullTaskPath({ taskID: 't1', hostId: 'peer/1' }, 'self')).toBe(
      '/home/devices/peer%2F1/v1/tasks/t1',
    )
  })

  test('Start does not pin a hostId from location order', () => {
    expect(ollamaStartBody('llama3:latest')).toEqual({ name: 'llama3:latest' })
    expect('hostId' in ollamaStartBody('llama3:latest')).toBe(false)
  })

  test('Start includes hostId when a Device is picked', () => {
    expect(ollamaStartBody('llama3:latest', 'desk')).toEqual({
      name: 'llama3:latest',
      hostId: 'desk',
    })
  })

  test('name filter is case-insensitive and ignores blank query', () => {
    expect(ollamaModelMatchesName('llama3:latest', '')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', '  ')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', 'LLAMA')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', 'mistral')).toBe(false)
  })

  test('Stop uses the live running host, not a stale snapshot', () => {
    const live = {
      running: true,
      locations: [
        { hostId: 'old', running: false },
        { hostId: 'desk', running: true },
      ],
    }
    expect(ollamaRunningHostId(live)).toBe('desk')
    expect(ollamaRunningHostId({ running: false, locations: live.locations })).toBeUndefined()
    expect(ollamaRunningHostId(undefined)).toBeUndefined()
  })

  test('pull progress is a percent', () => {
    expect(ollamaPullPercent(0.42)).toBe(42)
    expect(ollamaPullPercent(null)).toBeUndefined()
  })
})

describe('ollama start locations', () => {
  const desk = { hostId: 'desk', displayName: 'Desk', running: false, reachable: true }
  const lab = { hostId: 'lab', displayName: 'Lab', running: false, reachable: true }
  const down = { hostId: 'down', displayName: 'Garage', running: false, reachable: false }
  const stale = { hostId: 'stale', displayName: 'Attic', running: false, reachable: false }

  test('one location starts without a picker', () => {
    const model = { locations: [desk] }
    expect(ollamaStartLocations(model)).toEqual([desk])
    expect(ollamaSoleStartHostId(model)).toBe('desk')
    expect(ollamaDefaultStartHostId(model)).toBe('desk')
    expect(ollamaStartNeedsPicker(model)).toBe(false)
  })

  test('two locations need a picker of those Devices only', () => {
    const model = { locations: [desk, lab] }
    expect(ollamaStartLocations(model)).toEqual([desk, lab])
    expect(ollamaSoleStartHostId(model)).toBeUndefined()
    expect(ollamaDefaultStartHostId(model)).toBe('desk')
    expect(ollamaStartNeedsPicker(model)).toBe(true)
  })

  test('empty locations have no sole host and no picker', () => {
    const model = { locations: [] as typeof desk[] }
    expect(ollamaStartLocations(model)).toEqual([])
    expect(ollamaSoleStartHostId(model)).toBeUndefined()
    expect(ollamaDefaultStartHostId(model)).toBeUndefined()
    expect(ollamaStartNeedsPicker(model)).toBe(false)
    expect(ollamaStartLocations(undefined)).toEqual([])
    expect(ollamaSoleStartHostId(undefined)).toBeUndefined()
    expect(ollamaDefaultStartHostId(undefined)).toBeUndefined()
    expect(ollamaStartNeedsPicker(undefined)).toBe(false)
  })

  test('prefers a reachable location over an earlier unreachable one', () => {
    const model = { locations: [down, desk, stale] }
    expect(ollamaStartLocations(model).map((loc) => loc.hostId)).toEqual(['desk', 'down', 'stale'])
    expect(ollamaSoleStartHostId(model)).toBe('desk')
    expect(ollamaDefaultStartHostId(model)).toBe('desk')
    expect(ollamaStartNeedsPicker(model)).toBe(false)
    expect(ollamaStartCanStart(model)).toBe(true)
  })

  test('one unreachable location does not open a picker and cannot start', () => {
    const model = { locations: [down] }
    expect(ollamaStartLocations(model)).toEqual([down])
    expect(ollamaSoleStartHostId(model)).toBeUndefined()
    expect(ollamaDefaultStartHostId(model)).toBeUndefined()
    expect(ollamaStartNeedsPicker(model)).toBe(false)
    expect(ollamaStartCanStart(model)).toBe(false)
    expect(ollamaStartDisabledReason(model)).toBe('Model is on Devices that are unreachable')
  })

  test('multiple unreachable locations have no picker', () => {
    const model = { locations: [down, stale] }
    expect(ollamaStartLocations(model).map((loc) => loc.hostId)).toEqual(['down', 'stale'])
    expect(ollamaSoleStartHostId(model)).toBeUndefined()
    expect(ollamaDefaultStartHostId(model)).toBeUndefined()
    expect(ollamaStartNeedsPicker(model)).toBe(false)
    expect(ollamaStartCanStart(model)).toBe(false)
  })

  test('sidebar Device that has the model skips the picker even if another Device also has it', () => {
    const model = { locations: [desk, lab] }
    expect(ollamaStartCandidates(model, 'desk').map((loc) => loc.hostId)).toEqual(['desk'])
    expect(ollamaStartNeedsPicker(model, 'desk')).toBe(false)
    expect(ollamaSoleStartHostId(model, 'desk')).toBe('desk')
    expect(ollamaStartCanStart(model, 'desk')).toBe(true)
    expect(ollamaStartNeedsPicker(model, 'all')).toBe(true)
  })

  test('sidebar Device that lacks the model disables Start', () => {
    const model = { locations: [lab] }
    expect(ollamaStartCanStart(model, 'desk')).toBe(false)
    expect(ollamaStartDisabledReason(model, 'desk')).toBe('Model is not on this Device')
    expect(ollamaStartNeedsPicker(model, 'desk')).toBe(false)
  })

  test('duplicate hostIds never trigger a picker', () => {
    const model = { locations: [desk, { ...desk, displayName: 'Desk copy' }] }
    expect(ollamaStartLocations(model)).toEqual([desk])
    expect(ollamaStartNeedsPicker(model)).toBe(false)
    expect(ollamaSoleStartHostId(model)).toBe('desk')
  })

  test('duplicate hostId keeps the reachable copy', () => {
    const downDesk = { hostId: 'desk', displayName: 'Desk', running: false, reachable: false }
    const model = { locations: [downDesk, desk] }
    expect(ollamaStartLocations(model)).toEqual([desk])
    expect(ollamaStartCanStart(model)).toBe(true)
    expect(ollamaSoleStartHostId(model)).toBe('desk')
  })

  test('scoped unreachable Device has a distinct reason', () => {
    const model = { locations: [down] }
    expect(ollamaStartDisabledReason(model, 'down')).toBe('Model is on this Device but unreachable')
    expect(ollamaStartDisabledReason(model, 'desk')).toBe('Model is not on this Device')
  })
})
