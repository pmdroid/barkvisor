export const DASHBOARD_WIDGETS_STORAGE_KEY = 'barkvisor.dashboardWidgets'

export const DASHBOARD_MODULES = [
  'attention',
  'needs',
  'running',
  'stopped',
  'failed',
  'meters',
  'devices',
] as const

export type DashboardModuleId = (typeof DASHBOARD_MODULES)[number]

export type DashboardModule = {
  id: DashboardModuleId
  on: boolean
}

export const DASHBOARD_MODULE_META: Record<DashboardModuleId, { title: string; hint: string }> = {
  attention: { title: 'Attention', hint: 'Only appears when something needs you' },
  needs: { title: 'Needs you', hint: 'Failed workloads and unreachable Devices' },
  running: { title: 'Running', hint: 'Running workloads' },
  stopped: { title: 'Stopped', hint: 'Stopped workloads' },
  failed: { title: 'Failed', hint: 'Failed workloads as a list' },
  meters: { title: 'This Device', hint: 'CPU, memory, storage, temperature' },
  devices: { title: 'Home', hint: 'Every Device in this Home' },
}

export const DASHBOARD_FEED_MODULES: readonly DashboardModuleId[] = [
  'needs',
  'running',
  'failed',
  'stopped',
]

export const DASHBOARD_SIDE_MODULES: readonly DashboardModuleId[] = ['meters', 'devices']

export const DEFAULT_LAYOUT: DashboardModule[] = [
  { id: 'attention', on: true },
  { id: 'needs', on: true },
  { id: 'running', on: true },
  { id: 'stopped', on: true },
  { id: 'failed', on: false },
  { id: 'meters', on: true },
  { id: 'devices', on: true },
]

const MODULE_IDS = new Set<string>(DASHBOARD_MODULES)

export function isDashboardModuleId(value: string): value is DashboardModuleId {
  return MODULE_IDS.has(value)
}

export function resetDashboardLayout(): DashboardModule[] {
  return DEFAULT_LAYOUT.map((row) => ({ ...row }))
}

export function parseDashboardLayout(raw: string | null): DashboardModule[] {
  if (raw == null || raw.trim() === '') return resetDashboardLayout()
  try {
    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) return resetDashboardLayout()
    const seen = new Set<DashboardModuleId>()
    const layout: DashboardModule[] = []
    for (const item of parsed) {
      if (!item || typeof item !== 'object') continue
      const row = item as { id?: unknown; on?: unknown }
      if (typeof row.id !== 'string' || !isDashboardModuleId(row.id) || seen.has(row.id)) continue
      seen.add(row.id)
      layout.push({ id: row.id, on: row.on !== false })
    }
    for (const id of DASHBOARD_MODULES) {
      if (!seen.has(id)) {
        const fallback = DEFAULT_LAYOUT.find((row) => row.id === id)
        layout.push({ id, on: fallback?.on ?? false })
      }
    }
    if (layout.length === 0) return resetDashboardLayout()
    return layout
  } catch {
    return resetDashboardLayout()
  }
}

export function isModuleOn(layout: readonly DashboardModule[], id: DashboardModuleId): boolean {
  return layout.find((row) => row.id === id)?.on === true
}

export function toggleModule(
  layout: readonly DashboardModule[],
  id: DashboardModuleId,
): DashboardModule[] {
  return layout.map((row) => (row.id === id ? { ...row, on: !row.on } : { ...row }))
}

export function moveModule(
  layout: readonly DashboardModule[],
  index: number,
  delta: number,
): DashboardModule[] {
  const next = layout.map((row) => ({ ...row }))
  const dest = index + delta
  if (dest < 0 || dest >= next.length) return next
  const current = next[index]
  const other = next[dest]
  if (!current || !other) return next
  next[index] = other
  next[dest] = current
  return next
}

export function loadDashboardLayout(): DashboardModule[] {
  if (typeof localStorage === 'undefined') return resetDashboardLayout()
  return parseDashboardLayout(localStorage.getItem(DASHBOARD_WIDGETS_STORAGE_KEY))
}

export function saveDashboardLayout(layout: readonly DashboardModule[]): void {
  localStorage.setItem(DASHBOARD_WIDGETS_STORAGE_KEY, JSON.stringify(layout))
}
