import { parseWorkloadClass, type WorkloadClassName } from './workloadClass'

/** Missing or false: do not start after Device boot (House default). */
export function parseStartOnBoot(
  raw: { startOnBoot?: boolean | null; status?: { startOnBoot?: boolean | null } } | null | undefined,
): boolean {
  return raw?.startOnBoot === true || raw?.status?.startOnBoot === true
}

export function startOnBootLabel(): string {
  return 'Start when this Device boots'
}

export function startOnBootFooter(klass: WorkloadClassName): string {
  if (klass === 'agent') {
    return 'Starts after a Device reboot. The Agent cage stays on. A BarkVisor restart does not start it.'
  }
  return 'Off unless you turn it on. House appliances stay stopped after a Device reboot until you start them.'
}

export function startOnBootFooterFromWorkload(
  raw: { workloadClass?: string | null; spec?: { spec?: { workloadClass?: string | null } } } | null | undefined,
): string {
  return startOnBootFooter(parseWorkloadClass(raw?.workloadClass ?? raw?.spec?.spec?.workloadClass))
}
