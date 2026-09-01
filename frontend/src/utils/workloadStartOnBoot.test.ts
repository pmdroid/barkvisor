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

  test('Workload detail puts the Device-boot toggle next to Start and still PATCHes startOnBoot', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const actions = detail.match(/<div class="ops-actions">[\s\S]*?<\/div>/)?.[0] ?? ''
    expect(actions).toContain('role="switch"')
    expect(actions).toContain('startOnBootLabel()')
    expect(actions).toContain('toggleStartOnBoot')
    expect(actions).toContain('>Start</AppButton>')
    expect(actions.indexOf('role="switch"')).toBeLessThan(actions.indexOf('>Start</AppButton>'))

    const hardware = detail.slice(detail.indexOf('<h3>Hardware</h3>'), detail.indexOf('<h3>Network</h3>'))
    expect(hardware).not.toContain('startOnBootLabel')
    expect(hardware).not.toContain('toggleStartOnBoot')
    expect(hardware).not.toContain('role="switch"')

    expect(detail).toContain("from '../utils/workloadStartOnBoot'")
    expect(detail).toContain('parseStartOnBoot')
    expect(detail).toContain('await patchWorkload({ startOnBoot: checked })')
    expect(detail).not.toContain('node')
    expect(detail).not.toContain('cluster')
  })
})
