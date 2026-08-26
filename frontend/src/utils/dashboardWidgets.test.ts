import { describe, expect, test } from 'bun:test'
import {
  DASHBOARD_MODULES,
  DASHBOARD_WIDGETS_STORAGE_KEY,
  DEFAULT_LAYOUT,
  isModuleOn,
  moveModule,
  parseDashboardLayout,
  resetDashboardLayout,
  toggleModule,
} from './dashboardWidgets'

describe('dashboard layout defaults', () => {
  test('Grok triage modules with Failed off', () => {
    expect(DASHBOARD_MODULES).toEqual([
      'attention',
      'needs',
      'running',
      'stopped',
      'failed',
      'devices',
    ])
    expect(DASHBOARD_WIDGETS_STORAGE_KEY).toBe('barkvisor.dashboardWidgets')
    expect(resetDashboardLayout()).toEqual(DEFAULT_LAYOUT)
    expect(resetDashboardLayout()).not.toBe(DEFAULT_LAYOUT)
    expect(isModuleOn(DEFAULT_LAYOUT, 'attention')).toBe(true)
    expect(isModuleOn(DEFAULT_LAYOUT, 'failed')).toBe(false)
    expect(isModuleOn(DEFAULT_LAYOUT, 'devices')).toBe(true)
  })
})

describe('parseDashboardLayout', () => {
  test('null empty and invalid restore defaults', () => {
    expect(parseDashboardLayout(null)).toEqual(DEFAULT_LAYOUT)
    expect(parseDashboardLayout('')).toEqual(DEFAULT_LAYOUT)
    expect(parseDashboardLayout('not-json')).toEqual(DEFAULT_LAYOUT)
    expect(parseDashboardLayout('{}')).toEqual(DEFAULT_LAYOUT)
    expect(parseDashboardLayout('["devices"]')).toEqual(DEFAULT_LAYOUT)
  })

  test('keeps known modules order and fills missing', () => {
    const parsed = parseDashboardLayout(
      JSON.stringify([
        { id: 'running', on: true },
        { id: 'meters', on: true },
        { id: 'bogus', on: true },
      ]),
    )
    expect(parsed.map((row) => row.id)).toEqual([
      'running',
      'attention',
      'needs',
      'stopped',
      'failed',
      'devices',
    ])
    expect(isModuleOn(parsed, 'running')).toBe(true)
    expect(isModuleOn(parsed, 'devices')).toBe(true)
    expect(parsed.map((row) => row.id as string)).not.toContain('meters')
  })
})

describe('toggle and move', () => {
  test('toggle flips one module', () => {
    const next = toggleModule(DEFAULT_LAYOUT, 'failed')
    expect(isModuleOn(next, 'failed')).toBe(true)
    expect(isModuleOn(DEFAULT_LAYOUT, 'failed')).toBe(false)
  })

  test('move swaps neighbors', () => {
    const swapped = moveModule(DEFAULT_LAYOUT, 0, 1)
    expect(swapped[0]?.id).toBe('needs')
    expect(swapped[1]?.id).toBe('attention')
  })

  test('move past the ends is a no-op copy', () => {
    expect(moveModule(DEFAULT_LAYOUT, 0, -1).map((row) => row.id)).toEqual(
      DEFAULT_LAYOUT.map((row) => row.id),
    )
  })
})
