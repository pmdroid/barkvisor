import type { CurrentHostCapabilities } from '../api/types'
import { gpuPassthroughSupported } from './gpuPassthrough'

function normalizePciClass(raw: string): string {
  let value = raw.trim().toLowerCase()
  if (value.startsWith('0x')) value = value.slice(2)
  return value.replace(/[^0-9a-f]/g, '')
}

function pciBaseClass(classHex?: string | null): string {
  const hex = normalizePciClass(classHex ?? '')
  return hex.length >= 2 ? hex.slice(0, 2) : ''
}

/** PCI base-class label. Unknown codes stay "Class xx", not a guessed device. */
export function pciClassLabel(classHex: string): string {
  switch (pciBaseClass(classHex)) {
    case '01':
      return 'Mass storage'
    case '02':
      return 'Network'
    case '03':
      return 'Display'
    case '04':
      return 'Multimedia'
    case '05':
      return 'Memory'
    case '06':
      return 'Bridge'
    case '07':
      return 'Communication'
    case '08':
      return 'System'
    case '0c':
      return 'Serial bus'
    case '0d':
      return 'Wireless'
    case '12':
      return 'Processing accelerator'
    default: {
      const base = pciBaseClass(classHex)
      return base ? `Class ${base}` : 'PCI'
    }
  }
}

export function isDisplayPciClass(classHex?: string | null): boolean {
  return pciBaseClass(classHex) === '03'
}

/** Stored GPU attachments before pciClass existed count as display. */
export function isDisplayPassthrough(pciClass?: string | null): boolean {
  if (!pciClass) return true
  return isDisplayPciClass(pciClass)
}

/** Linux VFIO PCI picker. Hidden on macOS. */
export function pciPassthroughSupported(
  caps: CurrentHostCapabilities | null | undefined,
): boolean {
  if (!caps) return false
  if ((caps.platform || '').toLowerCase() === 'macos') return false
  if (gpuPassthroughSupported(caps)) return true
  if (caps.supportsVFIO === true) return true
  return caps.details?.find((row) => row.code === 'vfio')?.supported === true
}
