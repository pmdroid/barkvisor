import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const source = readFileSync(resolve(import.meta.dir, 'SettingsUpdatesTab.vue'), 'utf8')

describe('SettingsUpdatesTab GH-619', () => {
  test('changing Device clears update state before loading the new Device', () => {
    expect(source).toContain('watch(selectedHostId, () => {\n  resetForDevice()\n  void loadUpdates()')
    expect(source).toContain('updateTask.value = null')
    expect(source).toContain('installConfirm.value = false')
  })

  test('offline Device actions return before making a proxy request', () => {
    expect(source).toContain('return device && canCallDeviceAPI(device) ? device : null')
    expect(source).toContain(':disabled="!selectedDeviceReachable"')
  })
})
