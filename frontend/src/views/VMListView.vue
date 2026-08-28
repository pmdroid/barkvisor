<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { onMounted, onUnmounted, ref, reactive, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useVMStore } from '../stores/vms'
import { useToastStore } from '../stores/toast'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import type { HomeWorkloadRow } from '../stores/deviceWorkloads'
import { useCreateProgressStore } from '../stores/createProgress'
import api from '../api/client'
import type { GuestInfo, WorkloadHealth } from '../api/types'
import { healthLabel, vmHealth, vmListEmptyKind } from '../utils/workloadHealth'
import {
  isPendingCreateId,
  workloadListHealthBucket,
  workloadListStatusClass,
  workloadListStatusLabel,
  workloadListStatusSub,
} from '../utils/workloadListStatus'
import { listBackendBadge, vmBackend } from '../utils/workloadBackend'

import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import { scopeRows } from '../utils/deviceScope'
import { DEVICE_LABEL } from '../utils/terminology'
import { openWorkloadRow, workloadRowKey } from '../utils/workloadDetail'
import {
  guestInfoFetchPath,
  guestInfoIfRunning,
  guestOsLabel,
} from '../utils/guestHome'
import { formatCores, formatMemoryMB, formatPortForwards } from '../utils/format'

const store = useVMStore()
const homeWorkloads = useDeviceWorkloadsStore()
const createProgress = useCreateProgressStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const toast = useToastStore()
const router = useRouter()
const route = useRoute()
const showCreate = ref(false)
const healthFilter = ref<WorkloadHealth | 'all'>('all')
const guestInfoMap = reactive<Record<string, GuestInfo>>({})
const actionLoading = reactive<Record<string, boolean>>({})


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
  return scopeRows(createProgress.mergeInto(rows), deviceScope.selectedHostId)
})

const visibleRows = computed(() => {
  if (healthFilter.value === 'all') return homeRows.value
  return homeRows.value.filter((row) => workloadListHealthBucket(row) === healthFilter.value)
})

const listKind = computed(() =>
  vmListEmptyKind(homeRows.value.length, visibleRows.value.length, healthFilter.value),
)

const filteredEmptySubtitle = computed(() => {
  const filter = healthFilter.value
  if (filter === 'all') return 'No matching VMs on Home.'
  return `No ${healthLabel(filter)} VMs on Home.`
})

const healthStrip = computed(() => {
  const counts = { running: 0, failed: 0, stopped: 0 }
  for (const row of homeRows.value) {
    counts[workloadListHealthBucket(row)] += 1
  }
  return (['running', 'failed', 'stopped'] as const).map((key) => ({
    key,
    count: counts[key],
    label: healthLabel(key),
  }))
})

const healthTotal = computed(() => homeRows.value.length)

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

async function refreshHomeWorkloads() {
  await devicesStore.fetchHealth().catch(() => {})
  const list = devicesStore.devices
  if (list.length === 0) {
    await store.fetchAll()
    return
  }
  await homeWorkloads.fetchHomeAll(list)
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
      if (isPendingCreateId(row.vm.id)) {
        delete guestInfoMap[key]
        continue
      }
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

function vmPortForwards(vm: typeof store.vms[0]) {
  return vm.portForwards ?? []
}

let pollTimer: number
onMounted(async () => {
  await refreshHomeWorkloads()
  fetchGuestInfo()
  pollTimer = window.setInterval(() => {
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
  return guestOsLabel(rowGuestInfo(row), row.vm.vmType, true)
}

function listStatusLabel(row: HomeWorkloadRow) {
  return workloadListStatusLabel(row)
}

function listStatusClass(row: HomeWorkloadRow) {
  return workloadListStatusClass(row)
}

function statusSub(row: HomeWorkloadRow) {
  if (row.createDetail) return workloadListStatusSub(row)
  if (!row.reachable) return 'Device unreachable'
  const health = vmHealth(row.vm)
  if (health === 'guest_ready') return 'guest ready'
  if (health === 'failed') {
    const err = row.vm.status?.healthError
    const emu = emuBadge(row.vm)
    return [err, emu?.label].filter(Boolean).join(' · ')
  }
  return workloadListStatusSub(row)
}

function emuBadge(vm: typeof store.vms[0]) {
  return listBackendBadge(vmBackend(vm))
}

function rowKey(row: HomeWorkloadRow) {
  return workloadRowKey(row)
}

function rowDevice(row: HomeWorkloadRow) {
  return devicesStore.deviceByHostId(row.hostId)
}

function openRow(row: HomeWorkloadRow) {
  if (isPendingCreateId(row.vm.id)) return
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
  <div class="health-strip filters">
    <button
      type="button"
      class="fchip"
      :class="{ on: healthFilter === 'all', active: healthFilter === 'all' }"
      @click="healthFilter = 'all'"
    >
      All <span class="n">{{ healthTotal }}</span>
    </button>
    <button
      v-for="row in healthStrip"
      :key="row.key"
      type="button"
      class="fchip"
      :class="{
        on: healthFilter === row.key,
        active: healthFilter === row.key,
        bad: row.key === 'failed',
      }"
      @click="healthFilter = healthFilter === row.key ? 'all' : row.key"
    >
      <span class="ops-dot" :class="[healthDotClass[row.key], row.key === 'failed' ? 'pulse' : '']"></span>{{ row.label }} <span class="n">{{ row.count }}</span>
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

  <div v-else class="sheet">
    <table>
      <thead>
        <tr>
          <th>Name</th>
          <th>Device</th>
          <th>OS</th>
          <th>CPU · Mem</th>
          <th>Ports</th>
          <th>Status</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="row in visibleRows"
          :key="rowKey(row)"
          class="vm-row"
          :class="{ failed: workloadListHealthBucket(row) === 'failed', pending: isPendingCreateId(row.vm.id) }"
          @click="openRow(row)"
        >
          <td>
            <div class="vm">{{ row.vm.name }}</div>
          </td>
          <td class="dev-cell">
            {{ row.label }}
            <span v-if="!row.reachable" class="tag-amber">Unreachable</span>
          </td>
          <td>{{ osLabel(row) }}</td>
          <td class="num">{{ formatCores(row.vm.cpuCount) }} · {{ formatMemoryMB(row.vm.memoryMB) }}</td>
          <td class="ports">{{ formatPortForwards(vmPortForwards(row.vm)) }}</td>
          <td>
            <span
              class="state status-pill"
              :class="[listStatusClass(row), workloadListHealthBucket(row)]"
              :title="row.vm.status?.healthError || row.createDetail || undefined"
            >
              <span class="ops-dot" :class="[listStatusClass(row) === 'ok' ? 'ok' : listStatusClass(row) === 'bad' ? 'bad pulse' : listStatusClass(row) === 'warn' ? 'warn' : 'off']"></span>
              {{ listStatusLabel(row) }}
            </span>
            <div
              v-if="statusSub(row)"
              class="row-sub"
              :class="{ 'ops-bad-text': workloadListHealthBucket(row) === 'failed', 'warn-text': !row.reachable }"
            >{{ statusSub(row) }}</div>
          </td>
          <td class="acts" @click.stop>
            <button
              v-if="row.reachable && (row.vm.state === 'stopped' || row.vm.state === 'error')"
              type="button"
              class="mini go"
              :disabled="actionLoading[rowKey(row)]"
              @click="doStart(row)"
            >{{ actionLoading[rowKey(row)] ? 'Starting...' : 'Start' }}</button>
            <template v-else-if="row.reachable && row.vm.state === 'running'">
              <button type="button" class="mini" :disabled="actionLoading[rowKey(row)]" @click="requestStop(row, 'acpi')">Stop</button>
              <button type="button" class="mini" :disabled="restartLoading[rowKey(row)]" @click="doRestart(row)">{{ restartLoading[rowKey(row)] ? 'Restarting...' : 'Restart' }}</button>
            </template>
            <button
              v-else-if="!row.reachable"
              type="button"
              class="mini"
              disabled
            >Start</button>
          </td>
        </tr>
      </tbody>
    </table>
  </div>

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
.vm-row.pending {
  cursor: default;
}
.health-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 12px;
}
.warn-text { color: var(--amber); }
.state.status-pill::before { display: none; }
</style>
