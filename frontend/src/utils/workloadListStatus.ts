import type { VM, WorkloadHealth } from '../api/types'
import { healthLabel, vmHealth } from './workloadHealth'

export type CreateListPhase = 'downloading' | 'decompressing' | 'provisioning' | 'error'

export const PENDING_CREATE_ID_PREFIX = 'pending:'

export function isPendingCreateId(id: string): boolean {
  return id.startsWith(PENDING_CREATE_ID_PREFIX)
}

export type WorkloadListStatusRow = {
  vm: Pick<VM, 'state' | 'health' | 'status'>
  reachable?: boolean
  createPhase?: CreateListPhase
  createDetail?: string
  createPercent?: number | null
}

export function workloadListStatusLabel(row: WorkloadListStatusRow): string {
  if (row.createPhase === 'downloading') return 'Downloading'
  if (row.createPhase === 'decompressing') return 'Decompressing'
  if (row.createPhase === 'provisioning' || row.vm.state === 'provisioning') return 'Provisioning'
  if (row.createPhase === 'error' || row.vm.state === 'error') return 'Failed'
  if (row.vm.state === 'starting') return 'Starting'
  if (row.vm.state === 'stopping') return 'Stopping'
  if (row.vm.state === 'deleting') return 'Deleting'
  const health = vmHealth(row.vm)
  if (health === 'guest_ready' || health === 'running' || health === 'degraded') return 'Running'
  if (health === 'failed') return 'Failed'
  if (health === 'stopped') return 'Stopped'
  if (health === 'starting') return 'Starting'
  return healthLabel(health)
}

export function workloadListStatusSub(row: WorkloadListStatusRow): string {
  if (row.createDetail) {
    if (row.createPhase === 'downloading' && row.createPercent != null) {
      return `${row.createDetail} · ${row.createPercent}%`
    }
    return row.createDetail
  }
  if (row.reachable === false) return 'Device unreachable'
  const health = vmHealth(row.vm)
  if (health === 'guest_ready') return 'guest ready'
  if (health === 'failed') return row.vm.status?.healthError || ''
  return ''
}

export function workloadListStatusClass(row: WorkloadListStatusRow): 'ok' | 'bad' | 'off' | 'warn' {
  if (row.createPhase === 'error' || row.vm.state === 'error') return 'bad'
  if (
    row.createPhase === 'downloading'
    || row.createPhase === 'decompressing'
    || row.createPhase === 'provisioning'
    || row.vm.state === 'provisioning'
    || row.vm.state === 'starting'
    || row.vm.state === 'stopping'
    || row.vm.state === 'deleting'
  ) {
    return 'warn'
  }
  const health = vmHealth(row.vm)
  if (health === 'failed') return 'bad'
  if (health === 'stopped' || health === 'unknown') return 'off'
  return 'ok'
}

export function workloadListHealthBucket(
  row: WorkloadListStatusRow,
): 'running' | 'failed' | 'stopped' {
  const cls = workloadListStatusClass(row)
  if (cls === 'bad') return 'failed'
  if (cls === 'off') return 'stopped'
  return 'running'
}

export function createPhaseHealth(phase: CreateListPhase | undefined): WorkloadHealth {
  if (phase === 'error') return 'failed'
  if (phase === 'downloading' || phase === 'decompressing' || phase === 'provisioning') {
    return 'starting'
  }
  return 'unknown'
}
