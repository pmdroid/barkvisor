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
