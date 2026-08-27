export const HOST_CPU_RESERVE = 2
export const HOST_MEMORY_RESERVE_MB = 4096

export function hostCPUReserve(hostCpuCount: number): number {
  const host = typeof hostCpuCount === 'number' && hostCpuCount >= 1 ? hostCpuCount : 1
  if (host <= 1) return 0
  if (host < 4) return 1
  return HOST_CPU_RESERVE
}

export function vmCpuCap(hostCpuCount: number): number {
  const host = typeof hostCpuCount === 'number' && hostCpuCount >= 1 ? hostCpuCount : 1
  return Math.max(1, host - hostCPUReserve(host))
}

export function vmMemoryCapMB(hostMemoryMB: number | null | undefined): number | null {
  if (hostMemoryMB == null || hostMemoryMB < 128) return null
  return Math.max(128, hostMemoryMB - HOST_MEMORY_RESERVE_MB)
}

export type SizePreset = {
  id: string
  label: string
  cpu: number
  memGB: number
  diskGB: number
}

export const SIZE_PRESETS: SizePreset[] = [
  { id: 'small', label: 'Small', cpu: 2, memGB: 4, diskGB: 32 },
  { id: 'medium', label: 'Medium', cpu: 4, memGB: 8, diskGB: 64 },
  { id: 'large', label: 'Large', cpu: 8, memGB: 16, diskGB: 128 },
]

export function clampPreset(preset: SizePreset, cpuCap: number, memCapMB: number | null): SizePreset {
  const memCapGB = memCapMB != null ? Math.floor(memCapMB / 1024) : preset.memGB
  return {
    ...preset,
    cpu: Math.min(preset.cpu, cpuCap),
    memGB: Math.min(preset.memGB, Math.max(1, memCapGB)),
    diskGB: preset.diskGB,
  }
}

export function availableSizePresets(cpuCap: number, memCapMB: number | null): SizePreset[] {
  return SIZE_PRESETS.map((preset) => clampPreset(preset, cpuCap, memCapMB))
}

export function presetMatches(cpu: number, memGB: number, preset: SizePreset): boolean {
  return preset.cpu === cpu && preset.memGB === memGB
}
