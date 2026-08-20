import { normalizeImageArch, type ImageArch } from './imageArch'

/**
 * Guest profile table. Keep rows and IDs in lockstep with
 * `GuestProfiles` in Sources/BarkVisorCore/Platform/GuestProfile.swift.
 * Wizard / API / spec all resolve through `resolveGuestType`.
 */
export type GuestOsFamily = 'linux' | 'windows'

export type GuestProfileRow = {
  id: string
  arch: ImageArch
  qemuArch: 'aarch64' | 'x86_64'
  machine: 'virt' | 'q35'
  osFamily: GuestOsFamily
  defaultTPMEnabled: boolean
}

export const GUEST_PROFILES: readonly GuestProfileRow[] = Object.freeze([
  {
    id: 'linux-arm64',
    arch: 'arm64',
    qemuArch: 'aarch64',
    machine: 'virt',
    osFamily: 'linux',
    defaultTPMEnabled: false,
  },
  {
    id: 'windows-arm64',
    arch: 'arm64',
    qemuArch: 'aarch64',
    machine: 'virt',
    osFamily: 'windows',
    defaultTPMEnabled: true,
  },
  {
    id: 'linux-amd64',
    arch: 'x86_64',
    qemuArch: 'x86_64',
    machine: 'q35',
    osFamily: 'linux',
    defaultTPMEnabled: false,
  },
  {
    id: 'linux-x86_64',
    arch: 'x86_64',
    qemuArch: 'x86_64',
    machine: 'q35',
    osFamily: 'linux',
    defaultTPMEnabled: false,
  },
  {
    id: 'windows-amd64',
    arch: 'x86_64',
    qemuArch: 'x86_64',
    machine: 'q35',
    osFamily: 'windows',
    defaultTPMEnabled: true,
  },
])

const byID: Record<string, GuestProfileRow> = Object.fromEntries(
  GUEST_PROFILES.map((row) => [row.id, row]),
)

export function guestProfile(id: string | null | undefined): GuestProfileRow | undefined {
  if (!id) return undefined
  return byID[id]
}

function defaultLinuxID(arch: ImageArch): string {
  return arch === 'x86_64' ? 'linux-amd64' : 'linux-arm64'
}

function defaultWindowsID(arch: ImageArch): string {
  return arch === 'x86_64' ? 'windows-amd64' : 'windows-arm64'
}

export function resolveGuestType(input: {
  guestType?: string | null
  osFamily?: string | null
  arch?: string | null
  defaultArch?: string | null
}): string {
  const explicit = (input.guestType ?? '').trim()
  if (explicit) {
    const profile = byID[explicit]
    if (!profile) {
      throw new Error(`Unknown VM type: ${explicit}`)
    }
    const imageArch = normalizeImageArch(input.arch)
    if (imageArch && imageArch !== profile.arch) {
      throw new Error(
        `arch ${imageArch} does not match guestType ${explicit} (${profile.arch})`,
      )
    }
    return profile.id
  }
  const imageArch = normalizeImageArch(input.arch) ?? normalizeImageArch(input.defaultArch)
  if (!imageArch) {
    throw new Error('guest type resolve needs arch')
  }
  const family = (input.osFamily ?? 'linux').trim().toLowerCase()
  if (family === 'windows') return defaultWindowsID(imageArch)
  if (family && family !== 'linux') {
    throw new Error('osFamily must be linux or windows')
  }
  return defaultLinuxID(imageArch)
}
