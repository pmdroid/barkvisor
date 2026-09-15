/** Missing or false: do not start after Device boot. */
export function parseStartOnBoot(
  raw: { startOnBoot?: boolean | null; status?: { startOnBoot?: boolean | null } } | null | undefined,
): boolean {
  return raw?.startOnBoot === true || raw?.status?.startOnBoot === true
}

export function startOnBootLabel(): string {
  return 'Start when this Device boots'
}

export function startOnBootFooter(): string {
  return 'Off unless you turn it on. Workloads stay stopped after a Device reboot until you start them.'
}

export function startOnBootFooterFromWorkload(): string {
  return startOnBootFooter()
}
