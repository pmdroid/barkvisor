<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { onMounted, onUnmounted, ref, reactive, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useVMStore } from '../stores/vms'
import { useToastStore } from '../stores/toast'
import { useNetworkStore } from '../stores/networks'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDeviceNetworksStore } from '../stores/deviceNetworks'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import type { HomeWorkloadRow } from '../stores/deviceWorkloads'
import api from '../api/client'
import type { GuestInfo, PortForwardRule, WorkloadHealth, WorkloadHealthSummary } from '../api/types'
import { filterRowsByHealth, healthLabel, healthPillClass, vmHealth, vmListEmptyKind } from '../utils/workloadHealth'
import { listBackendBadge, vmBackend } from '../utils/workloadBackend'
import { storeToRefs } from 'pinia'
import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import AppIcon from '../components/ui/AppIcon.vue'
import { scopeRows } from '../utils/deviceScope'
import { DEVICE_LABEL } from '../utils/terminology'
import { openWorkloadRow, workloadRowKey } from '../utils/workloadDetail'
import {
  guestInfoFetchPath,
  guestInfoIfRunning,
  guestIpPortsView,
  guestOsLabel,
  guestPrimaryIp,
} from '../utils/guestHome'
import {
  guestIpsReachableFromNetwork,
  guestListServiceChips,
  listDisplayGuestIp,
} from '../utils/guestListeningPorts'

const store = useVMStore()
const homeWorkloads = useDeviceWorkloadsStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const toast = useToastStore()
const networkStore = useNetworkStore()
const deviceNetworks = useDeviceNetworksStore()
const { byId: networkMap } = storeToRefs(networkStore)
const router = useRouter()
const route = useRoute()
const showCreate = ref(false)
const healthSummary = ref<WorkloadHealthSummary | null>(null)
const healthFilter = ref<WorkloadHealth | 'all'>('all')
const guestInfoMap = reactive<Record<string, GuestInfo>>({})
const actionLoading = reactive<Record<string, boolean>>({})
const copied = reactive<Record<string, boolean>>({})

const homeRows = computed(() => {
  const devices = devicesStore.devices
  const rows = devices.length > 0
    ? homeWorkloads.homeRows(devices)
    : store.vms.map((vm) => ({
        vm,
        hostId: devicesStore.selfDevice?.hostId || '',
        label: '',
        role: 'self',
        reachable: true,
      }))
  return scopeRows(rows, deviceScope.selectedHostId)
})

const visibleRows = computed(() => filterRowsByHealth(homeRows.value, healthFilter.value))

const listKind = computed(() =>
  vmListEmptyKind(homeRows.value.length, visibleRows.value.length, healthFilter.value),
)

const filteredEmptySubtitle = computed(() => {
  const filter = healthFilter.value
  if (filter === 'all') return 'No matching VMs on Home.'
  return `No ${healthLabel(filter)} VMs on Home.`
})

const healthStrip = computed(() => {
  const counts = healthSummary.value?.counts ?? {}
  return (['running', 'starting', 'degraded', 'failed', 'stopped'] as WorkloadHealth[])
    .map((key) => ({ key, count: counts[key] ?? 0, label: healthLabel(key) }))
})

const healthTotal = computed(() => healthStrip.value.reduce((sum, row) => sum + row.count, 0))

const homeDeviceCount = computed(() => new Set(homeRows.value.map((row) => row.hostId)).size)

const healthDotClass: Record<WorkloadHealth, string> = {
  unknown: 'off',
  running: 'ok',
  guest_ready: 'ok',
  starting: 'warn',
  degraded: 'warn',
  failed: 'bad',
  stopped: 'off',
}

async function fetchHealthSummary() {
  try {
    const { data } = await api.get<WorkloadHealthSummary>('/workloads/health-summary')
    healthSummary.value = data
  } catch { /* ignore */ }
}

async function refreshHomeWorkloads() {
  await devicesStore.fetchHealth().catch(() => {})
  const list = devicesStore.devices
  if (list.length === 0) {
    await store.fetchAll()
    return
  }
  await Promise.all([
    homeWorkloads.fetchHomeAll(list),
    Promise.all(list.map((device) => deviceNetworks.fetchFor(device))),
  ])
}

function guestDeviceForRow(row: HomeWorkloadRow) {
  return rowDevice(row) ?? {
    hostId: row.hostId,
    role: row.role,
    reachability: row.reachable ? 'ok' : 'unreachable',
  }
}

let guestInfoInFlight = false
async function fetchGuestInfo() {
  if (guestInfoInFlight) return
  guestInfoInFlight = true
  try {
    for (const row of homeRows.value) {
      const key = rowKey(row)
      const path = guestInfoFetchPath(guestDeviceForRow(row), row.vm.id, row.vm.state)
      if (!path) {
        delete guestInfoMap[key]
        continue
      }
      try {
        const { data } = await api.get(path)
        guestInfoMap[key] = data
      } catch { /* keep last-known */ }
    }
  } finally {
    guestInfoInFlight = false
  }
}

function vmPortForwards(vm: typeof store.vms[0]): PortForwardRule[] {
  return vm.portForwards ?? []
}

function isNatVM(vm: typeof store.vms[0]): boolean {
  if (!vm.networkId) return true
  const net = networkMap.value[vm.networkId]
  return !net || net.mode === 'nat'
}

let pollTimer: number
onMounted(async () => {
  await refreshHomeWorkloads()
  fetchHealthSummary()
  fetchGuestInfo()
  void networkStore.fetchAll()
  pollTimer = window.setInterval(() => {
    fetchHealthSummary()
    void refreshHomeWorkloads().then(fetchGuestInfo)
  }, 5000)
  if (route.query.create) {
    showCreate.value = true
    router.replace({ path: '/vms' })
  }
})
onUnmounted(() => clearInterval(pollTimer))

function rowGuestInfo(row: HomeWorkloadRow) {
  return guestInfoIfRunning(guestInfoMap[rowKey(row)], row.vm.state)
}

function osLabel(row: HomeWorkloadRow) {
  return guestOsLabel(
    rowGuestInfo(row),
    row.vm.vmType,
    row.reachable && row.vm.state === 'running',
  )
}

function ipPortsFor(row: HomeWorkloadRow) {
  return guestIpPortsView({
    reachable: row.reachable,
    isMember: row.role !== 'self',
    isLocalNat: row.role === 'self' && isNatVM(row.vm),
    guest: rowGuestInfo(row),
    portForwards: vmPortForwards(row.vm),
  })
}

function networkModeFor(row: HomeWorkloadRow) {
  if (!row.vm.networkId) return null
  const fromHost = deviceNetworks.networksFor(row.hostId).find((n) => n.id === row.vm.networkId)
  if (fromHost) return fromHost.mode
  // This Device only: Home /networks is local. Members never use that map.
  if (row.role === 'self') return networkMap.value[row.vm.networkId]?.mode ?? null
  return null
}

function serviceChipsFor(row: HomeWorkloadRow) {
  if (row.role !== 'self' && !row.reachable) return null
  const guest = rowGuestInfo(row)
  return guestListServiceChips({
    guest,
    isMember: row.role !== 'self',
    guestIpsReachable: guestIpsReachableFromNetwork(networkModeFor(row)),
    portForwards: vmPortForwards(row.vm),
  })
}

function listGuestIp(row: HomeWorkloadRow) {
  return listDisplayGuestIp(guestPrimaryIp(rowGuestInfo(row)), networkModeFor(row))
}

function emuBadge(vm: typeof store.vms[0]) {
  return listBackendBadge(vmBackend(vm))
}


async function copyText(key: string, text: string) {
  try {
    await navigator.clipboard.writeText(text)
    copied[key] = true
    setTimeout(() => { copied[key] = false }, 1500)
  } catch { /* ignore */ }
}

function rowKey(row: HomeWorkloadRow) {
  return workloadRowKey(row)
}

function rowDevice(row: HomeWorkloadRow) {
  return devicesStore.deviceByHostId(row.hostId)
}

function openRow(row: HomeWorkloadRow) {
  openWorkloadRow((path) => { router.push(path) }, row)
}

async function doStart(row: HomeWorkloadRow) {
  const device = rowDevice(row)
  if (!device || !row.reachable) return
  actionLoading[rowKey(row)] = true
  try {
    await homeWorkloads.start(device, row.vm.id)
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    actionLoading[rowKey(row)] = false
  }
}

const restartLoading = reactive<Record<string, boolean>>({})

async function doRestart(row: HomeWorkloadRow) {
  const device = rowDevice(row)
  if (!device || !row.reachable) return
  restartLoading[rowKey(row)] = true
  try {
    await homeWorkloads.restart(device, row.vm.id)
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    restartLoading[rowKey(row)] = false
  }
}

const stopConfirm = ref<{ key: string; hostId: string; id: string; name: string; method: 'acpi' | 'force' } | null>(null)

function requestStop(row: HomeWorkloadRow, method: 'acpi' | 'force') {
  stopConfirm.value = {
    key: rowKey(row),
    hostId: row.hostId,
    id: row.vm.id,
    name: row.vm.name,
    method,
  }
}

async function doStop() {
  if (!stopConfirm.value) return
  const { key, hostId, id, method } = stopConfirm.value
  const device = devicesStore.deviceByHostId(hostId)
  if (!device) return
  actionLoading[key] = true
  try {
    await homeWorkloads.stop(device, id, { method })
    stopConfirm.value = null
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    actionLoading[key] = false
  }
}

</script>

<template>
  <div class="ops-page">
  <div class="ops-toolbar">
    <h1>Virtual Machines</h1>
    <span class="ops-sub">{{ devicesStore.devices.length ? `${homeRows.length} across ${homeDeviceCount} ${homeDeviceCount === 1 ? DEVICE_LABEL : DEVICE_LABEL + 's'}` : `${homeRows.length} VMs` }}</span>
    <div class="ops-actions">
      <AppButton variant="primary" icon="plus" @click="showCreate = true">Create VM</AppButton>
    </div>
  </div>

  <div class="ops-body">
  <div v-if="healthSummary" class="health-strip">
    <button
      type="button"
      class="fchip"
      :class="{ active: healthFilter === 'all' }"
      @click="healthFilter = 'all'"
    >
      All <span class="n">{{ healthTotal }}</span>
    </button>
    <button
      v-for="row in healthStrip"
      :key="row.key"
      type="button"
      class="fchip"
      :class="{ active: healthFilter === row.key }"
      @click="healthFilter = healthFilter === row.key ? 'all' : row.key"
    >
      <span class="ops-dot" :class="healthDotClass[row.key]"></span>{{ row.label }} <span class="n">{{ row.count }}</span>
    </button>
  </div>

  <EmptyState v-if="listKind === 'none' && !store.loading && !devicesStore.loading" icon="monitor" title="No virtual machines yet">
    <AppButton variant="primary" @click="showCreate = true">Create your first VM</AppButton>
  </EmptyState>

  <EmptyState
    v-else-if="listKind === 'filtered'"
    icon="monitor"
    title="No matching VMs"
    :subtitle="filteredEmptySubtitle"
  />

  <DataTable v-else :columns="[
    { key: 'name', label: 'Name' },
    { key: 'device', label: 'Device' },
    { key: 'os', label: 'OS' },
    { key: 'resources', label: 'Resources' },
    { key: 'ip', label: 'IP / Ports' },
    { key: 'status', label: 'Status' },
    { key: 'actions', label: '' },
  ]">
        <tr v-for="row in visibleRows" :key="rowKey(row)" :class="['vm-row', { failed: vmHealth(row.vm) === 'failed' }]" @click="openRow(row)">
          <td>
            <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
              <span style="font-weight:500">{{ row.vm.name }}</span>
              <span
                v-if="emuBadge(row.vm)"
                class="badge badge-amber"
                :title="emuBadge(row.vm)!.title"
              >{{ emuBadge(row.vm)!.label }}</span>
            </div>
            <div v-if="row.vm.description" style="font-size:12px;color:var(--text-dim);margin-top:2px">{{ row.vm.description }}</div>
          </td>
          <td>
            <WorkloadDeviceChip
              :label="row.label"
              :self="row.role === 'self'"
              :reachable="row.reachable"
            />
          </td>
          <td>
            <span style="font-size:13px">{{ osLabel(row) }}</span>
          </td>
          <td>
            <span style="font-size:12px;color:var(--text-secondary)">{{ row.vm.cpuCount }} CPU &middot; {{ row.vm.memoryMB >= 1024 ? (row.vm.memoryMB / 1024).toFixed(row.vm.memoryMB % 1024 === 0 ? 0 : 1) + ' GB' : row.vm.memoryMB + ' MB' }}</span>
          </td>
          <td>
            <template v-if="serviceChipsFor(row)">
              <div style="display:flex;flex-wrap:wrap;gap:4px;align-items:center">
                <div v-if="listGuestIp(row)" style="display:flex;align-items:center;gap:6px">
                  <code class="ip-text">{{ listGuestIp(row) }}</code>
                  <button class="ip-copy" @click.stop="copyText(`${rowKey(row)}-ip`, listGuestIp(row)!)" :title="copied[`${rowKey(row)}-ip`] ? 'Copied!' : 'Copy address'">
                    <AppIcon v-if="!copied[`${rowKey(row)}-ip`]" name="copy" :size="13" style="stroke-width:2" />
                    <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                  </button>
                </div>
                <template v-for="chip in serviceChipsFor(row)" :key="chip.key">
                  <a
                    v-if="chip.href"
                    :href="chip.href"
                    target="_blank"
                    class="badge badge-accent"
                    style="text-decoration:none"
                    @click.stop
                  >{{ chip.label }}</a>
                  <span
                    v-else
                    class="badge badge-gray"
                    :title="chip.copyText !== chip.label ? chip.copyText : undefined"
                  >{{ chip.label }}</span>
                </template>
                <span
                  v-if="!listGuestIp(row) && serviceChipsFor(row)!.length === 0"
                  style="color:var(--text-dim);font-size:12px"
                >-</span>
              </div>
            </template>
            <template v-else-if="ipPortsFor(row).kind === 'bridged-ip'">
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                <div v-for="(link, i) in ipPortsFor(row).links" :key="i" style="display:flex;align-items:center;gap:6px">
                  <a v-if="link.href" :href="link.href" target="_blank" class="ip-text" style="text-decoration:none;color:var(--accent)" @click.stop>{{ link.label }}</a>
                  <code v-else class="ip-text">{{ link.label }}</code>
                  <button class="ip-copy" @click.stop="copyText(`${rowKey(row)}-${i}`, link.copyText)" :title="copied[`${rowKey(row)}-${i}`] ? 'Copied!' : 'Copy address'">
                    <AppIcon v-if="!copied[`${rowKey(row)}-${i}`]" name="copy" :size="13" style="stroke-width:2" />
                    <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                  </button>
                </div>
              </div>
            </template>
            <template v-else-if="ipPortsFor(row).kind === 'nat-localhost'">
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                <div v-for="port in ipPortsFor(row).hostPorts" :key="port" style="display:flex;align-items:center;gap:6px">
                  <code class="ip-text">localhost:{{ port }}</code>
                  <button class="ip-copy" @click.stop="copyText(`${rowKey(row)}-${port}`, `localhost:${port}`)" :title="copied[`${rowKey(row)}-${port}`] ? 'Copied!' : 'Copy address'">
                    <AppIcon v-if="!copied[`${rowKey(row)}-${port}`]" name="copy" :size="13" style="stroke-width:2" />
                    <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                  </button>
                </div>
              </div>
            </template>
            <template v-else-if="ipPortsFor(row).kind === 'port-map'">
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                <code v-for="label in ipPortsFor(row).labels" :key="label" class="ip-text">{{ label }}</code>
              </div>
            </template>
            <span v-else style="color:var(--text-dim);font-size:12px">-</span>
          </td>
          <td>
            <div style="display:flex;align-items:center;gap:6px">
              <span
                class="status-pill"
                :class="healthPillClass(vmHealth(row.vm))"
                :title="row.vm.status?.healthError || undefined"
              >{{ healthLabel(vmHealth(row.vm)) }}</span>
              <span v-if="row.vm.pendingChanges && row.vm.state === 'running'" class="restart-badge" title="Restart required to apply changes">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
                Restart needed
              </span>
            </div>
          </td>
          <td>
            <div style="display:flex;gap:6px;justify-content:flex-end" @click.stop>
              <AppButton v-if="row.reachable && (row.vm.state === 'stopped' || row.vm.state === 'error')" variant="primary" size="sm" :disabled="actionLoading[rowKey(row)]" @click="doStart(row)">{{ actionLoading[rowKey(row)] ? 'Starting...' : 'Start' }}</AppButton>
              <template v-else-if="row.reachable && row.vm.state === 'running'">
                <AppButton v-if="row.vm.pendingChanges" variant="warning" size="sm" :disabled="restartLoading[rowKey(row)]" @click="doRestart(row)">{{ restartLoading[rowKey(row)] ? 'Restarting...' : 'Restart' }}</AppButton>
                <StopButtonGroup size="sm" :loading="actionLoading[rowKey(row)]" @stop="requestStop(row, $event)" />
              </template>
            </div>
          </td>
        </tr>
  </DataTable>

  </div>

  <ConfirmDialog
    v-if="stopConfirm"
    :title="stopConfirm.method === 'force' ? 'Force Stop VM' : 'Shutdown VM'"
    :message="`Are you sure you want to ${stopConfirm.method === 'force' ? 'force stop' : 'shut down'} ${stopConfirm.name}?${stopConfirm.method === 'force' ? ' This may cause data loss.' : ''}`"
    :confirm-label="stopConfirm.method === 'force' ? 'Force Stop' : 'Shutdown'"
    :danger="stopConfirm.method === 'force'"
    :loading="actionLoading[stopConfirm.key]"
    @confirm="doStop"
    @cancel="stopConfirm = null"
  />

  <CreateVMDrawer
    v-if="showCreate"
    :initial-host-id="deviceScope.isAll ? undefined : deviceScope.selectedHostId"
    @close="showCreate = false"
    @created="showCreate = false; refreshHomeWorkloads()"
  />
  </div>
</template>

<style scoped>
.vm-row {
  cursor: pointer;
}
.vm-row:hover {
  background: var(--bg-hover);
}
.ip-text {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-secondary);
  background: var(--bg);
  padding: 2px 6px;
  font-variant-numeric: tabular-nums;
}
.ip-copy {
  background: none;
  border: none;
  padding: 2px;
  cursor: pointer;
  color: var(--text-dim);
  display: flex;
  align-items: center;
}
.ip-copy:hover {
  color: var(--text);
}
.restart-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  color: #fbbf24;
  white-space: nowrap;
}
.health-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 12px;
}
</style>
