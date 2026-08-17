import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  guestAgentInstallCommands,
  guestAgentInstallOpenId,
  guestResizeCommands,
  shouldShowGuestAgentInstall,
} from './guestAgentInstall'

const here = dirname(fileURLToPath(import.meta.url))

describe('guestAgentInstall (PAS-215)', () => {
  test('shows only while running and the agent is not available', () => {
    expect(shouldShowGuestAgentInstall({ running: true, guestAvailable: false })).toBe(true)
    expect(shouldShowGuestAgentInstall({ running: true, guestAvailable: null })).toBe(true)
    expect(shouldShowGuestAgentInstall({ running: true })).toBe(true)
    expect(shouldShowGuestAgentInstall({ running: true, guestAvailable: true })).toBe(false)
    expect(shouldShowGuestAgentInstall({ running: false, guestAvailable: false })).toBe(false)
    expect(shouldShowGuestAgentInstall({ running: false, guestAvailable: true })).toBe(false)
  })

  test('unreachable members do not claim the agent is missing', () => {
    expect(shouldShowGuestAgentInstall({
      running: true,
      guestAvailable: false,
      memberUnreachable: true,
    })).toBe(false)
    expect(shouldShowGuestAgentInstall({
      running: true,
      guestAvailable: false,
      memberUnreachable: false,
    })).toBe(true)
  })

  test('pre-opens Windows or a known distro; generic linux stays collapsed', () => {
    expect(guestAgentInstallOpenId({ vmType: 'windows-amd64' })).toBe('windows')
    expect(guestAgentInstallOpenId({ vmType: 'windows-arm64' })).toBe('windows')
    expect(guestAgentInstallOpenId({ vmType: 'linux-amd64' })).toBeNull()
    expect(guestAgentInstallOpenId({ vmType: 'linux-arm64', imageName: 'ubuntu-24.04.iso' })).toBe('ubuntu')
    expect(guestAgentInstallOpenId({ osId: 'fedora' })).toBe('rhel')
    expect(guestAgentInstallOpenId({ osName: 'Alpine Linux' })).toBe('alpine')
    expect(guestAgentInstallOpenId({})).toBeNull()
  })

  test('install groups cover the disk-resize OS set plus Windows', () => {
    const ids = guestAgentInstallCommands.map((group) => group.id)
    expect(ids).toEqual(['ubuntu', 'alpine', 'arch', 'rhel', 'suse', 'windows'])
    expect(guestAgentInstallCommands.find((group) => group.id === 'ubuntu')?.commands).toContain('qemu-guest-agent')
    expect(guestAgentInstallCommands.find((group) => group.id === 'windows')?.commands).toContain('virtio-win-guest-tools.exe')
    expect(guestResizeCommands.map((group) => group.id)).toEqual(['ubuntu', 'alpine', 'arch', 'rhel', 'suse', 'lvm'])
  })

  test('Overview and Disks reuse the accordion', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const disks = readFileSync(join(here, '../views/DiskView.vue'), 'utf8')
    expect(detail).toContain("from '../utils/guestAgentInstall'")
    expect(detail).toContain('shouldShowGuestAgentInstall')
    expect(detail).toContain('GuestCommandAccordion')
    expect(detail).toContain('guestAgentInstallCommands')
    expect(detail).toContain('Install the guest agent inside this Workload')
    expect(detail).toContain('spice-vdagent')
    expect(disks).toContain('GuestCommandAccordion')
    expect(disks).toContain('guestResizeCommands')
    expect(disks).not.toContain('class="guest-cmds"')
    expect(detail).not.toContain('class="guest-cmds"')
  })
})
