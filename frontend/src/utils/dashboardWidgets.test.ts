import { describe, expect, test } from 'bun:test'
import {
  DASHBOARD_WIDGETS_STORAGE_KEY,
  DEFAULT_WIDGETS,
  THIS_DEVICE_WIDGETS,
  isThisDeviceWidget,
  isWidgetVisible,
  parseDashboardLayout,
  resetDashboardLayout,
  toggleWidget,
  type DashboardWidgetId,
} from './dashboardWidgets'

describe('dashboard widgets defaults', () => {
  test('default layout is the shipped stats set', () => {
    expect(DEFAULT_WIDGETS).toEqual([
      'devices',
      'health',
      'cpu',
      'memory',
      'storage',
      'temperature',
      'recent',
    ])
    expect(DASHBOARD_WIDGETS_STORAGE_KEY).toBe('barkvisor.dashboardWidgets')
    expect(resetDashboardLayout()).toEqual([...DEFAULT_WIDGETS])
    expect(resetDashboardLayout()).not.toBe(DEFAULT_WIDGETS)
  })

  test('this-Device widgets are the local host stats', () => {
    expect(THIS_DEVICE_WIDGETS).toEqual(['cpu', 'memory', 'storage', 'temperature'])
    for (const id of THIS_DEVICE_WIDGETS) expect(isThisDeviceWidget(id)).toBe(true)
    expect(isThisDeviceWidget('devices')).toBe(false)
    expect(isThisDeviceWidget('health')).toBe(false)
    expect(isThisDeviceWidget('recent')).toBe(false)
  })
})

describe('parseDashboardLayout', () => {
  test('null, empty, and invalid raw restore defaults', () => {
    expect(parseDashboardLayout(null)).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('')).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('  ')).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('not-json')).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('{}')).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('["nope"]')).toEqual([...DEFAULT_WIDGETS])
    expect(parseDashboardLayout('[1,2]')).toEqual([...DEFAULT_WIDGETS])
  })

  test('keeps known ids, order, and uniqueness', () => {
    expect(parseDashboardLayout('["recent","devices","cpu"]')).toEqual([
      'recent',
      'devices',
      'cpu',
    ])
    expect(parseDashboardLayout('["cpu","bogus","recent","cpu","health"]')).toEqual([
      'cpu',
      'recent',
      'health',
    ])
  })

  test('empty array is all hidden', () => {
    expect(parseDashboardLayout('[]')).toEqual([])
  })
})

describe('isWidgetVisible and toggleWidget', () => {
  test('defaults are visible', () => {
    for (const id of DEFAULT_WIDGETS) {
      expect(isWidgetVisible(DEFAULT_WIDGETS, id)).toBe(true)
    }
    expect(isWidgetVisible(['devices', 'recent'], 'cpu')).toBe(false)
    expect(isWidgetVisible([], 'health')).toBe(false)
  })

  test('toggle hides and restores at default order', () => {
    expect(toggleWidget(DEFAULT_WIDGETS, 'cpu')).toEqual([
      'devices',
      'health',
      'memory',
      'storage',
      'temperature',
      'recent',
    ])
    expect(toggleWidget(['devices', 'recent'], 'cpu')).toEqual([
      'devices',
      'cpu',
      'recent',
    ])
    expect(toggleWidget(['recent'], 'devices')).toEqual(['devices', 'recent'])
    expect(toggleWidget([], 'health')).toEqual(['health'])
  })

  test('reset after hide restores defaults', () => {
    const hidden = toggleWidget(DEFAULT_WIDGETS, 'recent')
    expect(isWidgetVisible(hidden, 'recent')).toBe(false)
    expect(resetDashboardLayout()).toEqual([...DEFAULT_WIDGETS])
    expect(isWidgetVisible(resetDashboardLayout(), 'recent')).toBe(true)
  })

  test('hiding every widget then reset restores the default set', () => {
    let layout: DashboardWidgetId[] = [...DEFAULT_WIDGETS]
    for (const id of DEFAULT_WIDGETS) layout = toggleWidget(layout, id)
    expect(layout).toEqual([])
    expect(resetDashboardLayout()).toEqual([...DEFAULT_WIDGETS])
  })
})
