import { describe, expect, test } from 'bun:test'
import { buildCreateVMPayload, useCreateVMPayload } from './useCreateVMPayload'

const base = {
  name: '  desk-vm  ',
  osFamily: 'linux' as const,
  cpuCount: 2,
  memoryMB: 1024,
  archCustomized: false,
  vmType: 'linux-arm64',
  uefiCustomized: false,
  uefi: true,
  tpmCustomized: false,
  tpmEnabled: false,
  diskSource: 'new' as const,
  existingDiskId: '',
  diskSizeGB: 10,
  mode: 'iso' as const,
  imageId: 'img-1',
  sshAuthorizedKeys: [] as string[],
  userData: '',
  displayResolution: '1280x800',
  selectedNetworkId: '',
  portForwards: [] as { protocol: 'tcp' | 'udp'; hostPort: number; guestPort: number }[],
  sharedPaths: [] as string[],
  usbAvailable: false,
  usbDevices: [] as { vendorId: string; productId: string }[],
}

describe('useCreateVMPayload (PAS-240)', () => {
  test('simple create omits vmType and firmware so the server applies Device defaults', () => {
    const req = buildCreateVMPayload(base)
    expect(req.name).toBe('desk-vm')
    expect(req.osFamily).toBe('linux')
    expect(req.cpuCount).toBe(2)
    expect(req.memoryMB).toBe(1024)
    expect(req.diskSizeGB).toBe(10)
    expect(req.isoId).toBe('img-1')
    expect(req.vmType).toBeUndefined()
    expect(req.uefi).toBeUndefined()
    expect(req.tpmEnabled).toBeUndefined()
    expect(req.displayResolution).toBeUndefined()
    expect(req.networkId).toBeUndefined()
    expect(req.usbDevices).toBeUndefined()
    expect(req.workloadClass).toBeUndefined()
  })

  test('agent class strips USB, shares, and hostfwds', () => {
    const req = buildCreateVMPayload({
      ...base,
      usbAvailable: true,
      usbDevices: [{ vendorId: '0x1234', productId: '0x5678' }],
      sharedPaths: ['/tmp/share'],
      portForwards: [{ protocol: 'tcp', hostPort: 8080, guestPort: 80 }],
      workloadClass: 'agent',
    })
    expect(req.workloadClass).toBe('agent')
    expect(req.usbDevices).toBeUndefined()
    expect(req.sharedPaths).toBeUndefined()
    expect(req.portForwards).toBeUndefined()
  })

  test('guest-type is a call-site value, not resolved here', () => {
    const { buildCreateVMPayload: build } = useCreateVMPayload()
    const req = build({
      ...base,
      archCustomized: true,
      osFamily: 'windows',
      vmType: 'windows-amd64',
    })
    expect(req.vmType).toBe('windows-amd64')
    expect(req.osFamily).toBe('windows')
  })

  test('existing disk replaces diskSizeGB; cloud-init carries Home keys', () => {
    const req = buildCreateVMPayload({
      ...base,
      diskSource: 'existing',
      existingDiskId: 'disk-9',
      mode: 'cloud',
      imageId: 'cloud-1',
      sshAuthorizedKeys: ['ssh-ed25519 AAAA laptop'],
      userData: ' #cloud-config ',
      selectedNetworkId: 'net-1',
      portForwards: [{ protocol: 'tcp', hostPort: 2222, guestPort: 22 }],
      sharedPaths: ['/Users/me/share'],
      displayResolution: '1920x1080',
      uefiCustomized: true,
      uefi: false,
      tpmCustomized: true,
      tpmEnabled: true,
    })
    expect(req.existingDiskId).toBe('disk-9')
    expect(req.diskSizeGB).toBeUndefined()
    expect(req.cloudImageId).toBe('cloud-1')
    expect(req.isoId).toBeUndefined()
    expect(req.cloudInit).toEqual({
      sshAuthorizedKeys: ['ssh-ed25519 AAAA laptop'],
      userData: '#cloud-config',
    })
    expect(req.networkId).toBe('net-1')
    expect(req.portForwards).toEqual([{ protocol: 'tcp', hostPort: 2222, guestPort: 22 }])
    expect(req.sharedPaths).toEqual(['/Users/me/share'])
    expect(req.displayResolution).toBe('1920x1080')
    expect(req.uefi).toBe(false)
    expect(req.tpmEnabled).toBe(true)
  })

  test('USB devices are omitted unless the Device advertises passthrough', () => {
    const devices = [{ vendorId: '046d', productId: 'c52b', deviceId: 'usb-1' }]
    expect(buildCreateVMPayload({ ...base, usbAvailable: false, usbDevices: devices }).usbDevices).toBeUndefined()
    expect(buildCreateVMPayload({ ...base, usbAvailable: true, usbDevices: devices }).usbDevices).toEqual(devices)
    expect(buildCreateVMPayload({ ...base, usbAvailable: true, usbDevices: [] }).usbDevices).toBeUndefined()
  })
})
