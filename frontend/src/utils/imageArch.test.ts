import { describe, expect, test } from 'bun:test'
import {
  detectImageArch,
  hostArchToImageArch,
  imageArchSupportedOnHost,
  normalizeImageArch,
  resolveImageArch,
  runnableImageArches,
} from './imageArch'

describe('detectImageArch', () => {
  const x86 = [
    'Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso',
    'Fedora-Server-dvd-x86_64-40-1.14.iso',
    'ubuntu-24.04.1-live-server-amd64.iso',
    'ubuntu-24.04-desktop-amd64.iso',
    'debian-12.7.0-amd64-netinst.iso',
    'debian-12.0.0-amd64-DVD-1.iso',
    'Rocky-9.4-x86_64-minimal.iso',
    'AlmaLinux-9-latest-x86_64-boot.iso',
    'CentOS-Stream-9-latest-x86_64-dvd1.iso',
    'rhel-9.4-x86_64-dvd.iso',
    'openSUSE-Leap-15.6-DVD-x86_64-Media.iso',
    'openSUSE-Tumbleweed-DVD-x86_64-Current.iso',
    'archlinux-2024.07.01-x86_64.iso',
    'manjaro-kde-24.0-240513-linux69-x86_64.iso',
    'alpine-standard-3.20.0-x86_64.iso',
    'FreeBSD-14.1-RELEASE-amd64-disc1.iso',
    'Win11_22H2_English_x64.iso',
    'virtio-win-0.1.240.iso', // no arch → null later
    'https://download.fedoraproject.org/pub/fedora/linux/releases/40/Server/x86_64/iso/Fedora-Server-dvd-x86_64-40-1.14.iso',
    'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
    'haos_ova-12.4.qcow2', // no arch token
  ]

  const arm = [
    'ubuntu-24.04.1-live-server-arm64.iso',
    'ubuntu-24.04-minimal-cloudimg-arm64.img',
    'debian-12.7.0-arm64-netinst.iso',
    'Fedora-Server-dvd-aarch64-40-1.14.iso',
    'Rocky-9.4-aarch64-minimal.iso',
    'AlmaLinux-9-latest-aarch64-boot.iso',
    'alpine-virt-3.20.0-aarch64.iso',
    'rhel-9.4-aarch64-dvd.iso',
    'openSUSE-Leap-15.6-DVD-aarch64-Media.iso',
    '2024-07-04-raspios-bookworm-arm64.img.xz',
    'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img',
    'https://dl.fedoraproject.org/.../Fedora-Cloud-Base-AmazonEC2.aarch64-40-1.14.raw.xz',
  ]

  for (const name of x86) {
    if (name.includes('virtio-win') || name.includes('haos_ova')) {
      test(`no arch: ${name}`, () => {
        expect(detectImageArch(name).arch).toBeNull()
      })
      continue
    }
    test(`x86_64: ${name}`, () => {
      expect(detectImageArch(name).arch).toBe('x86_64')
    })
  }

  for (const name of arm) {
    test(`arm64: ${name}`, () => {
      expect(detectImageArch(name).arch).toBe('arm64')
    })
  }

  test('rightmost token wins when both appear', () => {
    // Unlikely but prefer trailing arch (common packaging style)
    expect(detectImageArch('something-arm64-converted-x86_64.iso').arch).toBe('x86_64')
    expect(detectImageArch('mirror-x86_64/ubuntu-24.04-arm64.iso').arch).toBe('arm64')
  })

  test('empty / junk', () => {
    expect(detectImageArch('').arch).toBeNull()
    expect(detectImageArch(null).arch).toBeNull()
    expect(detectImageArch('random-file.iso').arch).toBeNull()
  })
})

describe('hostArchToImageArch / resolveImageArch', () => {
  test('host mapping', () => {
    expect(hostArchToImageArch('x86_64')).toBe('x86_64')
    expect(hostArchToImageArch('amd64')).toBe('x86_64')
    expect(hostArchToImageArch('arm64')).toBe('arm64')
    expect(hostArchToImageArch('aarch64')).toBe('arm64')
  })

  test('resolve prefers detection', () => {
    expect(resolveImageArch('Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso', 'arm64')).toBe('x86_64')
    expect(resolveImageArch('ubuntu-24.04-arm64.iso', 'x86_64')).toBe('arm64')
    expect(resolveImageArch('mystery.iso', 'x86_64')).toBe('x86_64')
    expect(resolveImageArch('mystery.iso', 'arm64')).toBe('arm64')
  })
})

describe('normalizeImageArch / imageArchSupportedOnHost (PAS-48)', () => {
  test('strict normalize does not coerce unknown to arm64', () => {
    expect(normalizeImageArch('amd64')).toBe('x86_64')
    expect(normalizeImageArch('aarch64')).toBe('arm64')
    expect(normalizeImageArch('x64')).toBe('x86_64')
    expect(normalizeImageArch('X86_64')).toBe('x86_64')
    expect(normalizeImageArch('AMD64')).toBe('x86_64')
    expect(normalizeImageArch(' AArch64 ')).toBe('arm64')
    expect(normalizeImageArch('armhf')).toBeNull()
    expect(normalizeImageArch('riscv64')).toBeNull()
    expect(normalizeImageArch('')).toBeNull()
    expect(normalizeImageArch(null)).toBeNull()
  })

  test('catalog support uses strict image labels', () => {
    expect(imageArchSupportedOnHost('amd64', 'x86_64')).toBe(true)
    expect(imageArchSupportedOnHost('x86_64', 'arm64')).toBe(false)
    expect(imageArchSupportedOnHost('armhf', 'arm64')).toBe(false)
    expect(imageArchSupportedOnHost('', 'arm64')).toBe(false)
  })

  test('unknown host is fail-closed (PAS-37)', () => {
    expect(imageArchSupportedOnHost('arm64', '')).toBe(false)
    expect(imageArchSupportedOnHost('arm64', null)).toBe(false)
    expect(imageArchSupportedOnHost('x86_64', undefined)).toBe(false)
    expect(imageArchSupportedOnHost('arm64', 'riscv64')).toBe(false)
  })
})

describe('runnableImageArches (PAS-48 / PAS-37)', () => {
  test('is host arch only', () => {
    expect([...runnableImageArches('arm64')]).toEqual(['arm64'])
    expect([...runnableImageArches('x86_64')]).toEqual(['x86_64'])
    expect([...runnableImageArches('amd64')]).toEqual(['x86_64'])
  })

  test('unknown host yields no runnable arches', () => {
    expect([...runnableImageArches('')]).toEqual([])
    expect([...runnableImageArches(null)]).toEqual([])
    expect([...runnableImageArches('riscv64')]).toEqual([])
  })
})
