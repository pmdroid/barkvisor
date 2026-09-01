import { afterEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import api from './client'
import { deviceNamePath, getDeviceName, saveDeviceName } from './deviceName'

const here = dirname(fileURLToPath(import.meta.url))
const originalGet = api.get
const originalPut = api.put

const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }

afterEach(() => {
  api.get = originalGet
  api.put = originalPut
})

describe('device name client (#388)', () => {
  test('self stays on local /system/device-name; members hop', async () => {
    expect(deviceNamePath(self)).toBe('/system/device-name')
    expect(deviceNamePath(member)).toBe('/home/devices/peer%2F1/v1/system/device-name')

    const get = mock(() => Promise.resolve({ data: { displayName: 'Desk', hostname: 'desk' } }))
    api.get = get as typeof api.get
    await getDeviceName(self)
    expect(get.mock.calls[0]?.[0]).toBe('/system/device-name')

    const put = mock(() => Promise.resolve({ data: { displayName: 'Lab', hostname: 'lab' } }))
    api.put = put as typeof api.put
    const named = await saveDeviceName('Lab', member)
    expect(named.displayName).toBe('Lab')
    expect(put.mock.calls[0]?.[0]).toBe('/home/devices/peer%2F1/v1/system/device-name')
    expect(put.mock.calls[0]?.[1]).toEqual({ displayName: 'Lab' })
  })

  test('Device details renames self and members; Settings Home has no name field', () => {
    const detail = readFileSync(join(here, '../views/DeviceDetailView.vue'), 'utf8')
    expect(detail).toContain('saveDeviceName')
    expect(detail).toContain('canRename')
    expect(detail).toContain('canFetchDeviceWorkloads')
    expect(detail).toContain('startRename')
    expect(detail).toContain('await devices.fetchHealth()')
    expect(detail).toContain('Rename')
    expect(detail).toContain('saveDeviceName(name, row)')

    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    const homeStart = settings.indexOf('v-if="tab === \'home\'"')
    const pairingStart = settings.indexOf('v-if="isPairingTab(tab)"')
    const homeBlock = settings.slice(homeStart, pairingStart > homeStart ? pairingStart : undefined)
    expect(homeStart).toBeGreaterThan(-1)
    expect(homeBlock).toContain('Device URL')
    expect(homeBlock).toContain('Advertised hosts')
    expect(homeBlock).not.toContain('What you can do on this Home')
    expect(homeBlock).not.toContain('Device name')
    expect(homeBlock).not.toContain('deviceNameDraft')
    expect(settings).not.toContain('getDeviceName')
    expect(settings).not.toContain('saveDeviceName')
    expect(settings).not.toContain('deviceNameDraft')
  })
})
