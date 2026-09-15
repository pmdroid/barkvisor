import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { adjacentDetailTabKey, detailTabKeys, detailTabs } from './appDetailTabs'
import type { DetailTabContext } from './appDetailTabs'

const here = dirname(fileURLToPath(import.meta.url))

function ctx(partial: Partial<DetailTabContext> = {}): DetailTabContext {
  return {
    isApp: false,
    isAdmin: false,
    isMemberDetail: false,
    showMemberConnect: true,
    running: true,
    ...partial,
  }
}

describe('detailTabs', () => {
  test('application tabs keep the shipped order', () => {
    expect(detailTabKeys(ctx({ isApp: true, isAdmin: true })))
      .toEqual(['overview', 'terminal', 'logs', 'environment', 'volumes'])
  })

  test('application terminal tab is admin-only on the local device', () => {
    expect(detailTabKeys(ctx({ isApp: true, isAdmin: false })))
      .not.toContain('terminal')
    expect(detailTabKeys(ctx({ isApp: true, isAdmin: true })))
      .toContain('terminal')
  })

  test('application tabs never expose VM hardware tabs', () => {
    const keys = detailTabKeys(ctx({ isApp: true, isAdmin: true }))
    expect(keys).not.toContain('console')
    expect(keys).not.toContain('vnc')
    expect(keys).not.toContain('metrics')
  })

  test('member application terminal tab follows member connect instead of admin', () => {
    expect(detailTabKeys(ctx({ isApp: true, isAdmin: false, isMemberDetail: true })))
      .toContain('terminal')
    expect(detailTabKeys(ctx({
      isApp: true,
      isAdmin: true,
      isMemberDetail: true,
      showMemberConnect: false,
    }))).not.toContain('terminal')
  })

  test('workload tabs keep the shipped order', () => {
    expect(detailTabKeys(ctx()))
      .toEqual(['overview', 'console', 'vnc', 'metrics', 'logs'])
  })

  test('workload tabs never expose app tabs', () => {
    const keys = detailTabKeys(ctx())
    expect(keys).not.toContain('environment')
    expect(keys).not.toContain('volumes')
    expect(keys).not.toContain('terminal')
  })

  test('metrics tab only exists while the workload runs', () => {
    expect(detailTabKeys(ctx({ running: false }))).not.toContain('metrics')
    expect(detailTabKeys(ctx({ running: true }))).toContain('metrics')
  })

  test('member console and vnc tabs require member connect', () => {
    const blocked = detailTabKeys(ctx({ isMemberDetail: true, showMemberConnect: false }))
    expect(blocked).not.toContain('console')
    expect(blocked).not.toContain('vnc')
    expect(blocked).toContain('logs')
    const open = detailTabKeys(ctx({ isMemberDetail: true, showMemberConnect: true }))
    expect(open).toContain('console')
    expect(open).toContain('vnc')
  })

  test('labels match the previous inline tab captions', () => {
    const tabs = detailTabs(ctx({ isApp: true, isAdmin: true }))
    expect(tabs.map((tab) => tab.label))
      .toEqual(['Overview', 'Terminal', 'Logs', 'Environment', 'Volumes'])
    expect(detailTabs(ctx()).map((tab) => tab.label))
      .toEqual(['Overview', 'Console', 'VNC', 'Metrics', 'Logs'])
  })
})

describe('adjacentDetailTabKey', () => {
  const keys = detailTabKeys(ctx({ isApp: true, isAdmin: true }))

  test('arrow keys move through the visible tabs and wrap', () => {
    expect(adjacentDetailTabKey(keys, 'overview', 'ArrowRight')).toBe('terminal')
    expect(adjacentDetailTabKey(keys, 'overview', 'ArrowLeft')).toBe('volumes')
    expect(adjacentDetailTabKey(keys, 'volumes', 'ArrowRight')).toBe('overview')
    expect(adjacentDetailTabKey(keys, 'volumes', 'ArrowLeft')).toBe('environment')
  })

  test('home and end jump to the ends', () => {
    expect(adjacentDetailTabKey(keys, 'logs', 'Home')).toBe('overview')
    expect(adjacentDetailTabKey(keys, 'logs', 'End')).toBe('volumes')
  })

  test('unknown current key or non-navigation keys are ignored', () => {
    // An unknown current key anchors at the first tab before stepping.
    expect(adjacentDetailTabKey(keys, 'nope', 'ArrowRight')).toBe('terminal')
    expect(adjacentDetailTabKey(keys, 'nope', 'Home')).toBe('overview')
    expect(adjacentDetailTabKey(keys, 'logs', 'Enter')).toBeNull()
    expect(adjacentDetailTabKey([], 'logs', 'ArrowRight')).toBeNull()
  })
})

describe('detail view renders accessible tabs from the tab list', () => {
  const view = readFileSync(join(here, '..', 'views', 'VMDetailView.vue'), 'utf8')

  test('tablist and tab roles replace the old clickable divs', () => {
    expect(view).toContain('role="tablist"')
    expect(view).toContain('detailTabs')
    expect(view).toContain('role="tab"')
    expect(view).toContain('aria-selected')
    expect(view).toContain('@keydown="onDetailTabKeydown"')
  })

  test('each tab controls its panel and panels are tabpanel regions', () => {
    expect(view).toContain('aria-controls')
    expect(view).toContain('workload-panel-')
    expect(view).toContain('role="tabpanel"')
  })
})
