export type WorkloadClassName = 'house' | 'agent'

export function parseWorkloadClass(raw: string | null | undefined): WorkloadClassName {
  return raw === 'agent' ? 'agent' : 'house'
}

export function isAgentWorkload(raw: { workloadClass?: string | null; spec?: { spec?: { workloadClass?: string | null } } } | null | undefined): boolean {
  const fromFlat = parseWorkloadClass(raw?.workloadClass)
  if (fromFlat === 'agent') return true
  return parseWorkloadClass(raw?.spec?.spec?.workloadClass) === 'agent'
}

export function workloadGrantCopy(klass: WorkloadClassName): string {
  return klass === 'agent' ? 'WAN yes, house no.' : 'House: LAN and USB allowed.'
}
