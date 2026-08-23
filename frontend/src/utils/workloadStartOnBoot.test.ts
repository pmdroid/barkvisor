import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { hardwarePatchBody } from './editHome'
import {
  parseStartOnBoot,
  startOnBootFooter,
  startOnBootFooterFromWorkload,
  startOnBootLabel,
} from './workloadStartOnBoot'

const here = dirname(fileURLToPath(import.meta.url))

describe('workloadStartOnBoot (PAS-258)', () => {
  test('missing and false stay off so House appliances are not surprised', () => {
    expect(parseStartOnBoot(undefined)).toBe(false)
    expect(parseStartOnBoot({})).toBe(false)
    expect(parseStartOnBoot({ startOnBoot: false })).toBe(false)
    expect(parseStartOnBoot({ startOnBoot: true })).toBe(true)
    expect(parseStartOnBoot({ status: { startOnBoot: true } })).toBe(true)
  })

  test('House copy is opt-in; Agent copy keeps the cage', () => {
    expect(startOnBootLabel()).toBe('Start when this Device boots')
    expect(startOnBootFooter('house')).toContain('House appliances stay stopped')
    expect(startOnBootFooter('agent')).toContain('Agent cage stays on')
    expect(startOnBootFooterFromWorkload({ workloadClass: 'house' })).toContain('House appliances')
    expect(startOnBootFooterFromWorkload({ spec: { spec: { workloadClass: 'agent' } } })).toContain(
      'Agent cage',
    )
  })

  test('PATCH body keeps startOnBoot and drops targetHostId', () => {
    expect(
      hardwarePatchBody({
        startOnBoot: true,
        targetHostId: 'foreign',
      }),
    ).toEqual({ startOnBoot: true })
  })

  test('Workload detail exposes the Device-boot toggle', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    expect(detail).toContain("from '../utils/workloadStartOnBoot'")
    expect(detail).toContain('parseStartOnBoot')
    expect(detail).toContain('startOnBootLabel')
    expect(detail).toContain('toggleStartOnBoot')
    expect(detail).not.toContain('node')
    expect(detail).not.toContain('cluster')
  })
})
