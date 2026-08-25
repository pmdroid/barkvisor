import { describe, expect, test } from 'bun:test'
import { defaultCapabilities } from './capabilitiesParse'
import {
  isDisplayPassthrough,
  isDisplayPciClass,
  pciClassLabel,
  pciPassthroughSupported,
} from './pciPassthrough'

describe('pciClassLabel', () => {
  test('maps PCI base class hex to a readable name', () => {
    expect(pciClassLabel('0x020000')).toBe('Network')
    expect(pciClassLabel('020000')).toBe('Network')
    expect(pciClassLabel('0x010802')).toBe('Mass storage')
    expect(pciClassLabel('030000')).toBe('Display')
    expect(pciClassLabel('0x040300')).toBe('Multimedia')
    expect(pciClassLabel('0x060400')).toBe('Bridge')
    expect(pciClassLabel('0c0300')).toBe('Serial bus')
    expect(pciClassLabel('0x120000')).toBe('Processing accelerator')
    expect(pciClassLabel('0x0d0000')).toBe('Wireless')
    expect(pciClassLabel('')).toBe('PCI')
    expect(pciClassLabel('0x0a0000')).toBe('Class 0a')
  })

  test('display class is PCI base 03', () => {
    expect(isDisplayPciClass('0x030000')).toBe(true)
    expect(isDisplayPciClass('038000')).toBe(true)
    expect(isDisplayPciClass('0x020000')).toBe(false)
    expect(isDisplayPciClass(undefined)).toBe(false)
    expect(isDisplayPassthrough(undefined)).toBe(true)
    expect(isDisplayPassthrough('020000')).toBe(false)
    expect(isDisplayPassthrough('030000')).toBe(true)
  })
})

describe('pciPassthroughSupported', () => {
  test('hides the entry point on macOS', () => {
    expect(pciPassthroughSupported({
      ...defaultCapabilities,
      platform: 'macOS',
      supportsVFIO: true,
      supportsGPUPassthrough: true,
    })).toBe(false)
  })

  test('linux vfio or gpu passthrough shows the picker', () => {
    expect(pciPassthroughSupported({
      ...defaultCapabilities,
      platform: 'Linux',
      supportsVFIO: true,
    })).toBe(true)
    expect(pciPassthroughSupported({
      ...defaultCapabilities,
      platform: 'Linux',
      supportsGPUPassthrough: true,
    })).toBe(true)
    expect(pciPassthroughSupported({
      ...defaultCapabilities,
      platform: 'Linux',
    })).toBe(false)
  })
})
