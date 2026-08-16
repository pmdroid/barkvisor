<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDevicesStore } from '../stores/devices'
import { useToastStore } from '../stores/toast'
import { canFetchDeviceWorkloads } from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import { openWorkloadRow } from '../utils/workloadDetail'
import { healthLabel, healthPillClass, vmHealth } from '../utils/workloadHealth'

const route = useRoute()
const router = useRouter()
const devices = useDevicesStore()
const workloads = useDeviceWorkloadsStore()
const toast = useToastStore()

const hostId = computed(() => String(route.params.hostId ?? ''))
const device = computed(() => devices.deviceByHostId(hostId.value))
const reachable = computed(() => device.value?.reachability === 'ok')
const title = computed(() => {
  if (!device.value) return hostId.value
  return devices.deviceLabel(device.value)
})
const platformLabel = computed(() => {
  const os = device.value?.platform?.os
  const arch = device.value?.platform?.arch
  if (os && arch) return `${os} · ${arch}`
  return os || arch || ''
})
const vms = computed(() => workloads.vmsFor(hostId.value))
const listError = computed(() => workloads.errorFor(hostId.value))
const loadingList = computed(() => workloads.isLoading(hostId.value))
const healthReady = computed(() => devices.report !== null || Boolean(devices.error))
const listSettled = computed(() => hostId.value in workloads.vmsByHost)
const showEmptyWorkloads = computed(() =>
  vms.value.length === 0 && !loadingList.value && !listError.value && listSettled.value,
)
const showLoadingWorkloads = computed(() =>
  !listSettled.value && loadingList.value && !listError.value && vms.value.length === 0,
)

const restartLoading = reactive<Record<string, boolean>>({})
const stopConfirm = ref<{ id: string; name: string; method: 'acpi' | 'force' } | null>(null)
const showCreate = ref(false)

function clearHostTransientState() {
  stopConfirm.value = null
  for (const id of Object.keys(restartLoading)) {
    delete restartLoading[id]
  }
}

async function refreshDevice(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row) return
  await workloads.fetchFor(row)
}

let refreshSeq = 0
async function refresh() {
  const seq = ++refreshSeq
  await devices.fetchHealth()
  if (seq !== refreshSeq) return
  await refreshDevice(devices.deviceByHostId(hostId.value))
}

let pollTimer: number
onMounted(() => {
  void refresh()
  pollTimer = window.setInterval(() => { void refresh() }, 5000)
})
onUnmounted(() => {
  refreshSeq += 1
  clearInterval(pollTimer)
})
watch(hostId, () => {
  clearHostTransientState()
  void refresh()
})

async function doStart(id: string) {
  const row = device.value
  if (!row) return
  try {
    await workloads.start(row, id)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function doRestart(id: string) {
  const row = device.value
  if (!row) return
  restartLoading[id] = true
  try {
    await workloads.restart(row, id)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    restartLoading[id] = false
  }
}

function openWorkload(vm: (typeof vms.value)[number]) {
  if (!device.value) return
  openWorkloadRow((path) => { router.push(path) }, {
    hostId: device.value.hostId,
    role: device.value.role,
    vm,
  })
}

function requestStop(id: string, method: 'acpi' | 'force') {
  const vm = vms.value.find((row) => row.id === id)
  stopConfirm.value = { id, name: vm?.name || id, method }
}

async function doStop() {
  if (!stopConfirm.value || !device.value) return
  const { id, method } = stopConfirm.value
  try {
    await workloads.stop(device.value, id, { method })
    stopConfirm.value = null
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}
</script>

<template>
  <div class="device-detail">
    <button class="back-link" type="button" @click="router.push('/devices')">
      ← {{ DEVICE_LABEL }}s
    </button>

    <div v-if="!device && (devices.loading || !healthReady)" class="missing">
      <p>Loading {{ DEVICE_LABEL.toLowerCase() }}...</p>
    </div>

    <div v-else-if="!device" class="missing">
      <template v-if="devices.error">
        <h1>{{ DEVICE_LABEL }}s unavailable</h1>
        <p>
          Could not load {{ DEVICE_LABEL.toLowerCase() }} health.
          This {{ DEVICE_LABEL.toLowerCase() }} is still running.
        </p>
      </template>
      <template v-else>
        <h1>Device not found</h1>
        <p>This {{ DEVICE_LABEL.toLowerCase() }} is not in the Home list.</p>
      </template>
    </div>

    <template v-else-if="device">
      <div class="detail-header">
        <div>
          <h1>{{ title }}</h1>
          <p class="detail-meta">
            <span v-if="device.role === 'self'" class="device-chip self">This {{ DEVICE_LABEL }}</span>
            <span v-else class="device-chip">{{ DEVICE_LABEL }}</span>
            <span v-if="platformLabel">{{ platformLabel }}</span>
          </p>
        </div>
        <div class="detail-actions">
          <AppButton
            v-if="canFetchDeviceWorkloads(device)"
            variant="primary"
            icon="plus"
            @click="showCreate = true"
          >
            Create VM
          </AppButton>
          <span class="status-pill" :class="reachable ? 'running' : 'failed'">
            {{ reachable ? 'Reachable' : 'Unreachable' }}
          </span>
        </div>
      </div>

      <p v-if="!canFetchDeviceWorkloads(device)" class="unreachable-copy">
        This {{ DEVICE_LABEL.toLowerCase() }} did not answer. Workload counts are not shown.
        This {{ DEVICE_LABEL.toLowerCase() }} is still running locally.
      </p>

      <template v-else>
        <p v-if="listError" class="list-error">{{ listError }}</p>

        <EmptyState
          v-if="showEmptyWorkloads"
          icon="monitor"
          title="No workloads on this Device"
        />

        <p v-else-if="showLoadingWorkloads" class="list-loading">Loading workloads...</p>

        <DataTable
          v-else-if="listSettled || vms.length > 0"
          :columns="[
            { key: 'name', label: 'Workload' },
            { key: 'resources', label: 'Resources' },
            { key: 'status', label: 'Status' },
            { key: 'actions', label: '' },
          ]"
        >
          <tr v-for="vm in vms" :key="vm.id" class="vm-row" @click="openWorkload(vm)">
            <td>
              <div class="vm-name">{{ vm.name }}</div>
              <div v-if="vm.description" class="vm-desc">{{ vm.description }}</div>
            </td>
            <td class="vm-res">
              {{ vm.cpuCount }} CPU ·
              {{ vm.memoryMB >= 1024
                ? (vm.memoryMB / 1024).toFixed(vm.memoryMB % 1024 === 0 ? 0 : 1) + ' GB'
                : vm.memoryMB + ' MB' }}
            </td>
            <td>
              <span
                class="status-pill"
                :class="healthPillClass(vmHealth(vm))"
                :title="vm.status?.healthError || undefined"
              >{{ healthLabel(vmHealth(vm)) }}</span>
            </td>
            <td>
              <div class="vm-actions" @click.stop>
                <AppButton
                  v-if="vm.state === 'stopped' || vm.state === 'error'"
                  variant="primary"
                  size="sm"
                  :disabled="workloads.isActing(hostId, vm.id)"
                  @click="doStart(vm.id)"
                >
                  {{ workloads.isActing(hostId, vm.id) ? 'Starting...' : 'Start' }}
                </AppButton>
                <template v-else-if="vm.state === 'running'">
                  <AppButton
                    variant="warning"
                    size="sm"
                    :disabled="restartLoading[vm.id] || workloads.isActing(hostId, vm.id)"
                    @click="doRestart(vm.id)"
                  >
                    {{ restartLoading[vm.id] ? 'Restarting...' : 'Restart' }}
                  </AppButton>
                  <StopButtonGroup
                    size="sm"
                    :loading="workloads.isActing(hostId, vm.id)"
                    @stop="requestStop(vm.id, $event)"
                  />
                </template>
              </div>
            </td>
          </tr>
        </DataTable>
      </template>
    </template>

    <CreateVMDrawer
      v-if="showCreate && device"
      :initial-host-id="device.hostId"
      @close="showCreate = false"
      @created="showCreate = false; refresh()"
    />

    <ConfirmDialog
      v-if="stopConfirm"
      :title="stopConfirm.method === 'force' ? 'Force Stop Workload' : 'Stop Workload'"
      :message="`Are you sure you want to ${stopConfirm.method === 'force' ? 'force stop' : 'shut down'} ${stopConfirm.name}?${stopConfirm.method === 'force' ? ' This may cause data loss.' : ''}`"
      :confirm-label="stopConfirm.method === 'force' ? 'Force Stop' : 'Shutdown'"
      :danger="stopConfirm.method === 'force'"
      :loading="workloads.isActing(hostId, stopConfirm.id)"
      @confirm="doStop"
      @cancel="stopConfirm = null"
    />
  </div>
</template>

<style scoped>
.back-link {
  background: none;
  border: 0;
  padding: 0;
  margin: 0 0 16px;
  color: var(--text-dim);
  font-size: 13px;
  cursor: pointer;
}
.back-link:hover { color: var(--text-primary); }
.detail-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 20px;
}
.detail-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}
.detail-header h1 {
  margin: 0;
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.03em;
}
.detail-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin: 6px 0 0;
  color: var(--text-dim);
  font-size: 12px;
}
.device-chip {
  display: inline-flex;
  padding: 2px 8px;
  border-radius: 2px;
  background: var(--bg-hover);
  color: var(--text-secondary);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  font-size: 10px;
}
.device-chip.self {
  color: var(--green);
  background: var(--green-muted);
}
.unreachable-copy,
.list-error,
.list-loading,
.missing p {
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
.list-error,
.list-loading { margin: 0 0 16px; }
.missing h1 {
  margin: 0 0 8px;
  font-size: 28px;
}
.vm-row { cursor: pointer; }
.vm-row:hover { background: var(--bg-hover); }
.vm-name { font-weight: 500; }
.vm-desc {
  font-size: 12px;
  color: var(--text-dim);
  margin-top: 2px;
}
.vm-res {
  font-size: 12px;
  color: var(--text-secondary);
}
.vm-actions {
  display: flex;
  gap: 6px;
  justify-content: flex-end;
}

@media (max-width: 768px) {
  .detail-header h1,
  .missing h1 { font-size: 22px; }
}
</style>
