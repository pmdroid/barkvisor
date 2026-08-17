/** Home Workload detail routes (PAS-202).
 *  Self stays /vms/:id. Members open /devices/:hostId/vms/:id. Key is hostId:vmId. */

export type WorkloadOpenTarget = {
  hostId: string
  role?: string | null
  vm: { id: string }
}

export function workloadRowKey(row: Pick<WorkloadOpenTarget, 'hostId'> & { vm: { id: string } }): string {
  return `${row.hostId}:${row.vm.id}`
}

/** Path for a list/dashboard row click. Self never uses a Device card. */
export function workloadDetailPath(row: WorkloadOpenTarget): string {
  if (!row.hostId || row.role === 'self') {
    return `/vms/${encodeURIComponent(row.vm.id)}`
  }
  return `/devices/${encodeURIComponent(row.hostId)}/vms/${encodeURIComponent(row.vm.id)}`
}

export function openWorkloadRow(
  push: (path: string) => void,
  row: WorkloadOpenTarget,
): void {
  push(workloadDetailPath(row))
}

/** Home's /networks inventory is this process only — never resolve a member from it. */
export function localNetworkForDetail<T extends { id: string; isDefault?: boolean }>(
  isMemberDetail: boolean,
  networkId: string | null | undefined,
  networks: T[],
): T | null {
  if (isMemberDetail) return null
  if (!networkId) return networks.find((n) => n.isDefault) ?? null
  return networks.find((n) => n.id === networkId) ?? null
}

/** Member overview has no member network inventory; never claim Default NAT. */
export function memberNetworkCaption(networkId: string | null | undefined): string {
  return networkId ? networkId : 'Unknown'
}

/** Member-restricted chrome only after role is known (or load settled with no self). */
export function isMemberWorkloadDetail(input: {
  hostId: string
  role?: string | null
  loadSettled?: boolean
}): boolean {
  if (!input.hostId) return false
  if (input.role === 'self') return false
  if (input.role) return true
  return Boolean(input.loadSettled)
}

export type WorkloadDetailVmSource = 'local' | 'member' | 'pending'

/** Until role is known, do not bind a cached VM — self hostId would look like a member. */
export function workloadDetailVmSource(input: {
  hostId: string
  role?: string | null
}): WorkloadDetailVmSource {
  if (!input.hostId || input.role === 'self') return 'local'
  if (input.role) return 'member'
  return 'pending'
}
