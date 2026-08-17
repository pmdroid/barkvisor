/** Guest-agent install help (PAS-215).
 *  Shown on Workload Overview when qemu-guest-agent is not answering. */

export type GuestCommandGroup = {
  id: string
  label: string
  commands: string
}

export const guestAgentInstallCommands: GuestCommandGroup[] = [
  {
    id: 'ubuntu',
    label: 'Ubuntu / Debian',
    commands: 'sudo apt update && sudo apt install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent',
  },
  {
    id: 'alpine',
    label: 'Alpine Linux',
    commands: 'apk add qemu-guest-agent\nrc-update add qemu-guest-agent default\nrc-service qemu-guest-agent start',
  },
  {
    id: 'arch',
    label: 'Arch Linux',
    commands: 'sudo pacman -S qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent',
  },
  {
    id: 'rhel',
    label: 'RHEL / Fedora / CentOS',
    commands: 'sudo dnf install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent',
  },
  {
    id: 'suse',
    label: 'openSUSE / SLES',
    commands: 'sudo zypper install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent',
  },
  {
    id: 'windows',
    label: 'Windows',
    commands:
      'Attach the VirtIO ISO from Library (already downloaded when you created this Windows Workload).\n\nIn Console or Display, run virtio-win-guest-tools.exe\nor install the guest-agent MSI from the same ISO.',
  },
]

export const guestResizeCommands: GuestCommandGroup[] = [
  { id: 'ubuntu', label: 'Ubuntu / Debian', commands: 'sudo growpart /dev/vda 1\nsudo resize2fs /dev/vda1' },
  { id: 'alpine', label: 'Alpine Linux', commands: 'apk add growpart\ngrowpart /dev/vda 1\nresize2fs /dev/vda1' },
  { id: 'arch', label: 'Arch Linux', commands: 'sudo growpart /dev/vda 1\nsudo resize2fs /dev/vda1' },
  { id: 'rhel', label: 'RHEL / Fedora / CentOS', commands: 'sudo growpart /dev/vda 1\nsudo xfs_growfs /      # XFS (default)\nsudo resize2fs /dev/vda1  # ext4' },
  { id: 'suse', label: 'openSUSE / SLES', commands: 'sudo growpart /dev/vda 1\nsudo xfs_growfs /      # XFS\nsudo resize2fs /dev/vda1  # ext4' },
  { id: 'lvm', label: 'LVM (any distro)', commands: 'sudo growpart /dev/vda 2\nsudo pvresize /dev/vda2\nsudo lvextend -l +100%FREE /dev/mapper/vg0-root\nsudo resize2fs /dev/mapper/vg0-root  # ext4\nsudo xfs_growfs /                    # XFS' },
]

/** Install card: running Workload whose guest-info confirmed the agent is missing.
 *  Fetch errors / not-yet-loaded stay hidden — we do not claim the agent is missing.
 *  Unreachable members stay empty. */
export function shouldShowGuestAgentInstall(input: {
  running: boolean
  guestAvailable?: boolean | null
  guestInfoLoaded?: boolean
  memberUnreachable?: boolean
}): boolean {
  if (!input.running) return false
  if (input.memberUnreachable) return false
  if (input.guestInfoLoaded === false) return false
  return input.guestAvailable === false
}

/** Pre-open a group only when the guest OS is known. Generic linux stays collapsed. */
export function guestAgentInstallOpenId(input: {
  vmType?: string | null
  imageName?: string | null
  osId?: string | null
  osName?: string | null
}): string | null {
  const hay = [input.vmType, input.imageName, input.osId, input.osName]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
  if (!hay) return null
  if (hay.includes('windows')) return 'windows'
  if (hay.includes('ubuntu') || hay.includes('debian')) return 'ubuntu'
  if (hay.includes('alpine')) return 'alpine'
  if (/\barch\b/.test(hay) || hay.includes('archlinux')) return 'arch'
  if (
    hay.includes('fedora')
    || hay.includes('rhel')
    || hay.includes('centos')
    || hay.includes('rocky')
    || hay.includes('alma')
  ) {
    return 'rhel'
  }
  if (hay.includes('suse') || hay.includes('sles')) return 'suse'
  return null
}
