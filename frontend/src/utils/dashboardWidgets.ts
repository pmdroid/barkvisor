export const DASHBOARD_WIDGETS_STORAGE_KEY = 'barkvisor.dashboardWidgets'

export const DEFAULT_WIDGETS = [
  'devices',
  'health',
  'cpu',
  'memory',
  'storage',
  'temperature',
  'recent',
] as const

export type DashboardWidgetId = (typeof DEFAULT_WIDGETS)[number]

export const DASHBOARD_WIDGET_LABELS: Record<DashboardWidgetId, string> = {
  devices: 'Devices',
  health: 'Health',
  cpu: 'CPU',
  memory: 'Memory',
  storage: 'Storage',
  temperature: 'Temperature',
  recent: 'Recent Machines',
}

export const THIS_DEVICE_WIDGETS = [
  'cpu',
  'memory',
  'storage',
  'temperature',
] as const satisfies readonly DashboardWidgetId[]

export type ThisDeviceWidgetId = (typeof THIS_DEVICE_WIDGETS)[number]

const WIDGET_IDS = new Set<string>(DEFAULT_WIDGETS)
const THIS_DEVICE_WIDGET_IDS = new Set<string>(THIS_DEVICE_WIDGETS)

export function isDashboardWidgetId(value: string): value is DashboardWidgetId {
  return WIDGET_IDS.has(value)
}

export function isThisDeviceWidget(id: DashboardWidgetId): id is ThisDeviceWidgetId {
  return THIS_DEVICE_WIDGET_IDS.has(id)
}

export function resetDashboardLayout(): DashboardWidgetId[] {
  return [...DEFAULT_WIDGETS]
}

export function parseDashboardLayout(raw: string | null): DashboardWidgetId[] {
  if (raw == null || raw.trim() === '') return resetDashboardLayout()
  try {
    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) return resetDashboardLayout()
    const seen = new Set<DashboardWidgetId>()
    const layout: DashboardWidgetId[] = []
    for (const item of parsed) {
      if (typeof item !== 'string' || !isDashboardWidgetId(item) || seen.has(item)) continue
      seen.add(item)
      layout.push(item)
    }
    if (layout.length === 0 && parsed.length > 0) return resetDashboardLayout()
    return layout
  } catch {
    return resetDashboardLayout()
  }
}

export function isWidgetVisible(
  layout: readonly DashboardWidgetId[],
  id: DashboardWidgetId,
): boolean {
  return layout.includes(id)
}

export function toggleWidget(
  layout: readonly DashboardWidgetId[],
  id: DashboardWidgetId,
): DashboardWidgetId[] {
  if (layout.includes(id)) return layout.filter((item) => item !== id)
  const visible = new Set(layout)
  visible.add(id)
  return DEFAULT_WIDGETS.filter((item) => visible.has(item))
}
