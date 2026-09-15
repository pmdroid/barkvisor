export type DetailTabKey =
  | 'overview'
  | 'console'
  | 'terminal'
  | 'vnc'
  | 'metrics'
  | 'logs'
  | 'environment'
  | 'volumes'

export type DetailTab = {
  key: DetailTabKey
  label: string
}

export type DetailTabContext = {
  isApp: boolean
  isAdmin: boolean
  isMemberDetail: boolean
  showMemberConnect: boolean
  running: boolean
}

const TAB_ORDER: DetailTabKey[] = [
  'overview',
  'console',
  'terminal',
  'vnc',
  'metrics',
  'logs',
  'environment',
  'volumes',
]

const LABELS: Record<DetailTabKey, string> = {
  overview: 'Overview',
  console: 'Console',
  terminal: 'Terminal',
  vnc: 'VNC',
  metrics: 'Metrics',
  logs: 'Logs',
  environment: 'Environment',
  volumes: 'Volumes',
}

export function detailTabKeys(ctx: DetailTabContext): DetailTabKey[] {
  const memberControls = ctx.isMemberDetail ? ctx.showMemberConnect : true
  return TAB_ORDER.filter((key) => {
    if (key === 'overview' || key === 'logs') return true
    if (key === 'metrics') return !ctx.isApp && ctx.running
    if (key === 'console' || key === 'vnc') return !ctx.isApp && memberControls
    if (key === 'terminal') {
      return ctx.isApp && (ctx.isMemberDetail ? ctx.showMemberConnect : ctx.isAdmin)
    }
    return ctx.isApp
  })
}

export function detailTabs(ctx: DetailTabContext): DetailTab[] {
  return detailTabKeys(ctx).map((key) => ({ key, label: LABELS[key] }))
}

export function adjacentDetailTabKey(
  keys: DetailTabKey[],
  current: string,
  key: string,
): DetailTabKey | null {
  if (!keys.length) return null
  if (key !== 'ArrowRight' && key !== 'ArrowLeft' && key !== 'Home' && key !== 'End') return null
  const index = keys.indexOf(current as DetailTabKey)
  const active = index < 0 ? 0 : index
  const next = key === 'ArrowRight'
    ? (active + 1) % keys.length
    : key === 'ArrowLeft'
      ? (active - 1 + keys.length) % keys.length
      : key === 'Home'
        ? 0
        : keys.length - 1
  return keys[next] ?? null
}
