<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import type { HomeDeviceHealthSnapshot, VM } from '../api/types'
import AppButton from '../components/ui/AppButton.vue'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceWorkloadsStore, type HomeWorkloadRow } from '../stores/deviceWorkloads'
import { useVMStore } from '../stores/vms'
import {
  DASHBOARD_FEED_MODULES,
  DASHBOARD_MODULE_META,
  DASHBOARD_SIDE_MODULES,
  type DashboardModule,
  type DashboardModuleId,
  isModuleOn,
  loadDashboardLayout,
  moveModule,
  resetDashboardLayout,
  saveDashboardLayout,
  toggleModule,
} from '../utils/dashboardWidgets'
import { scopeRows } from '../utils/deviceScope'
import { formatCores, formatMemoryMB } from '../utils/format'
import { isReachabilityOk, reachabilityHint, reachabilityLabel } from '../utils/homeDeviceHealth'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { openWorkloadRow } from '../utils/workloadDetail'
import { opsStatusLabel, vmHealth } from '../utils/workloadHealth'

const router = useRouter()
const store = useVMStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const homeWorkloads = useDeviceWorkloadsStore()
const layout = ref<DashboardModule[]>(loadDashboardLayout())
const customizeOpen = ref(false)

const scopedDevices = computed(() => scopeRows(devices.devices, deviceScope.selectedHostId))

const homeRows = computed(() => {
  const list = devices.devices
  const rows = list.length > 0
    ? homeWorkloads.homeRows(list)
    : store.vms.map((vm) => ({
        vm,
        hostId: devices.selfDevice?.hostId || '',
        label: '',
        role: 'self',
        reachable: true,
      }))
  return scopeRows(rows, deviceScope.selectedHostId)
})

type BoardBucket = 'running' | 'failed' | 'stopped'

function bucketOf(vm: VM): BoardBucket {
  const health = vmHealth(vm)
  if (health === 'running' || health === 'guest_ready' || health === 'starting') return 'running'
  if (health === 'failed' || health === 'degraded') return 'failed'
  return 'stopped'
}

const runningRows = computed(() => homeRows.value.filter((row) => bucketOf(row.vm) === 'running'))
const failedRows = computed(() => homeRows.value.filter((row) => bucketOf(row.vm) === 'failed'))
const stoppedRows = computed(() => homeRows.value.filter((row) => bucketOf(row.vm) === 'stopped'))
const unreachableDevices = computed(() =>
  scopedDevices.value.filter((row) => !isReachabilityOk(row.reachability)),
)

const workloadTotal = computed(() => {
  if (!deviceScope.isAll) {
    return scopedDevices.value[0]?.workloadCount ?? homeRows.value.length
  }
  return devices.totals?.workloadCount ?? homeRows.value.length
})

const toolbarSub = computed(() => {
  const n = scopedDevices.value.length
  const running = runningRows.value.length
  const total = workloadTotal.value
  const failed = failedRows.value.length
  const down = unreachableDevices.value.length
  const parts = [
    `${n} ${n === 1 ? DEVICE_LABEL : DEVICE_LABEL + 's'}`,
    total ? `${running} of ${total} workloads running` : 'No workloads',
  ]
  if (failed) parts.push(`${failed} failed`)
  if (down) parts.push(`${down} unreachable`)
  return parts.join(' · ')
})

const feedModules = computed(() =>
  layout.value.filter((row) => row.on && (DASHBOARD_FEED_MODULES as readonly string[]).includes(row.id)),
)
const sideModules = computed(() =>
  layout.value.filter((row) => row.on && (DASHBOARD_SIDE_MODULES as readonly string[]).includes(row.id)),
)

const showAttention = computed(() =>
  isModuleOn(layout.value, 'attention')
  && (failedRows.value.length > 0 || unreachableDevices.value.length > 0),
)

function persist(next: DashboardModule[]) {
  layout.value = next
  saveDashboardLayout(next)
}

function onToggle(id: DashboardModuleId) {
  persist(toggleModule(layout.value, id))
}

function onMove(index: number, delta: number) {
  persist(moveModule(layout.value, index, delta))
}

function onReset() {
  persist(resetDashboardLayout())
}

function vmOs(vm: VM): string {
  return vm.vmType.startsWith('windows') ? 'Windows' : 'Linux'
}

function vmSpecs(vm: VM): string {
  return `${vmOs(vm)} · ${formatCores(vm.cpuCount)} · ${formatMemoryMB(vm.memoryMB)}`
}

function vmError(row: HomeWorkloadRow): string {
  return row.vm.status?.healthError || 'failed'
}

function rowDeviceLabel(row: HomeWorkloadRow): string {
  if (row.label) return row.label
  const device = devices.deviceByHostId(row.hostId)
  return device ? devices.deviceLabel(device) : DEVICE_LABEL
}

function deviceMeta(row: HomeDeviceHealthSnapshot): string {
  const os = row.platform?.os
  const arch = row.platform?.arch
  const platform = os && arch ? `${os} · ${arch}` : os || arch || ''
  return [platform, reachabilityLabel(row.reachability)].filter(Boolean).join(' · ')
}

function unreachableIncidentText(row: HomeDeviceHealthSnapshot): string {
  const stopped = row.healthCounts?.stopped ?? 0
  if (stopped === 1) return `1 stopped workload still on that ${DEVICE_LABEL}`
  if (stopped > 1) return `${stopped} stopped workloads still on that ${DEVICE_LABEL}`
  return reachabilityHint(row) || 'Unreachable'
}

function homeDevSub(row: HomeDeviceHealthSnapshot): string {
  const os = row.platform?.os
  const arch = row.platform?.arch
  const bits = [os, arch].filter(Boolean)
  if (!isReachabilityOk(row.reachability)) bits.push('unreachable')
  else if ((row.healthCounts?.failed ?? 0) > 0) bits.push(`${row.healthCounts?.failed} failed`)
  return bits.join(' · ')
}

function openVm(row: HomeWorkloadRow) {
  openWorkloadRow((path) => { router.push(path) }, row)
}

function openDevice(row: HomeDeviceHealthSnapshot) {
  router.push({ name: 'device-detail', params: { hostId: row.hostId } })
}

let homeRefreshInFlight = false
async function refreshHomeWorkloads() {
  if (homeRefreshInFlight) return
  homeRefreshInFlight = true
  try {
    await devices.fetchHealth().catch(() => {})
    const list = devices.devices
    if (list.length === 0) {
      await store.fetchAll()
      return
    }
    await homeWorkloads.fetchHomeAll(list)
  } finally {
    homeRefreshInFlight = false
  }
}

let pollTimer: number
function onKey(event: KeyboardEvent) {
  if (event.key === 'Escape') customizeOpen.value = false
}

onMounted(() => {
  window.addEventListener('keydown', onKey)
  void refreshHomeWorkloads()
  pollTimer = window.setInterval(() => {
    void refreshHomeWorkloads()
  }, 5000)
})
onUnmounted(() => {
  window.removeEventListener('keydown', onKey)
  clearInterval(pollTimer)
})
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <h1>Dashboard</h1>
      <span class="ops-sub">{{ toolbarSub }}</span>
      <div class="ops-actions">
        <AppButton variant="ghost" icon="sliders" @click="customizeOpen = true">Customize</AppButton>
        <AppButton variant="primary" icon="plus" @click="router.push('/vms?create=1')">Create VM</AppButton>
      </div>
    </div>
    <div class="ops-body triage">
      <div v-if="showAttention" class="incidents">
        <div v-for="row in failedRows" :key="'fail-' + row.vm.id" class="incident">
          <span class="pill failed">Failed</span>
          <strong>{{ row.vm.name }}</strong>
          <span>{{ vmError(row) }} on {{ rowDeviceLabel(row) }}</span>
          <span class="spacer"></span>
          <AppButton @click="openVm(row)">Open</AppButton>
        </div>
        <div v-for="row in unreachableDevices" :key="'down-' + row.hostId" class="incident warn">
          <span class="pill unreach">Unreachable</span>
          <strong>{{ devices.deviceLabel(row) }}</strong>
          <span>{{ unreachableIncidentText(row) }}</span>
          <span class="spacer"></span>
          <AppButton @click="openDevice(row)">{{ DEVICE_LABEL }}</AppButton>
        </div>
      </div>

      <div class="triage-body" :class="{ full: !sideModules.length }">
        <section class="feed-col">
          <template v-for="mod in feedModules" :key="mod.id">
            <div v-if="mod.id === 'needs'" class="feed-block">
              <div class="section-label">Needs you</div>
              <div v-if="failedRows.length || unreachableDevices.length" class="feed">
                <article
                  v-for="row in failedRows"
                  :key="'need-' + row.vm.id"
                  class="row loud"
                  @click="openVm(row)"
                >
                  <div>
                    <h3>{{ row.vm.name }}</h3>
                    <div class="meta">{{ vmSpecs(row.vm) }}<template v-if="vmError(row)"> · {{ vmError(row) }}</template></div>
                  </div>
                  <span class="chip" :class="{ self: row.role === 'self' }">{{ rowDeviceLabel(row) }}</span>
                  <span class="pill failed">Failed</span>
                </article>
                <article
                  v-for="row in unreachableDevices"
                  :key="'need-dev-' + row.hostId"
                  class="row loud"
                  @click="openDevice(row)"
                >
                  <div>
                    <h3>{{ devices.deviceLabel(row) }}</h3>
                    <div class="meta">{{ deviceMeta(row) }}</div>
                  </div>
                  <span class="chip">{{ DEVICE_LABEL }}</span>
                  <span class="pill unreach">Unreachable</span>
                </article>
              </div>
              <div v-else class="empty">Nothing needs you</div>
            </div>
            <div v-else-if="mod.id === 'running'" class="feed-block">
              <div class="section-label">Running</div>
              <div v-if="runningRows.length" class="feed">
                <article
                  v-for="row in runningRows"
                  :key="row.hostId + row.vm.id"
                  class="row"
                  @click="openVm(row)"
                >
                  <div>
                    <h3>{{ row.vm.name }}</h3>
                    <div class="meta">{{ vmSpecs(row.vm) }}</div>
                  </div>
                  <span class="chip" :class="{ self: row.role === 'self' }">{{ rowDeviceLabel(row) }}</span>
                  <span class="pill running">{{ opsStatusLabel(vmHealth(row.vm)) }}</span>
                </article>
              </div>
              <div v-else class="empty">No running workloads</div>
            </div>
            <div v-else-if="mod.id === 'failed'" class="feed-block">
              <div class="section-label">Failed</div>
              <div v-if="failedRows.length" class="feed">
                <article
                  v-for="row in failedRows"
                  :key="'fl-' + row.hostId + row.vm.id"
                  class="row loud"
                  @click="openVm(row)"
                >
                  <div>
                    <h3>{{ row.vm.name }}</h3>
                    <div class="meta">{{ vmSpecs(row.vm) }}<template v-if="vmError(row)"> · {{ vmError(row) }}</template></div>
                  </div>
                  <span class="chip" :class="{ self: row.role === 'self' }">{{ rowDeviceLabel(row) }}</span>
                  <span class="pill failed">Failed</span>
                </article>
              </div>
              <div v-else class="empty">No failed workloads</div>
            </div>
            <div v-else-if="mod.id === 'stopped'" class="feed-block">
              <div class="section-label">Stopped</div>
              <div v-if="stoppedRows.length" class="feed">
                <article
                  v-for="row in stoppedRows"
                  :key="row.hostId + row.vm.id"
                  class="row"
                  @click="openVm(row)"
                >
                  <div>
                    <h3>{{ row.vm.name }}</h3>
                    <div class="meta">
                      {{ vmSpecs(row.vm) }}
                      <template v-if="!row.reachable"> · {{ DEVICE_LABEL }} is unreachable</template>
                    </div>
                  </div>
                  <span class="chip" :class="{ self: row.role === 'self' }">{{ rowDeviceLabel(row) }}</span>
                  <span class="pill stopped">Stopped</span>
                </article>
              </div>
              <div v-else class="empty">No stopped workloads</div>
            </div>
          </template>
        </section>

        <aside v-if="sideModules.length" class="side">
          <template v-for="mod in sideModules" :key="mod.id">
            <div v-if="mod.id === 'devices'" class="panel">
              <h2>{{ HOME_LABEL }}</h2>
              <button
                v-for="row in scopedDevices"
                :key="row.hostId"
                type="button"
                class="triage-home-dev"
                @click="openDevice(row)"
              >
                <div>
                  <b>{{ devices.deviceLabel(row) }}</b>
                  <small>{{ homeDevSub(row) }}</small>
                </div>
                <span class="side-dot" :class="isReachabilityOk(row.reachability) ? 'ok' : 'off'"></span>
              </button>
              <div v-if="!scopedDevices.length" class="empty">No {{ DEVICE_LABEL }}s in this {{ HOME_LABEL }} yet</div>
            </div>
          </template>
        </aside>
      </div>
    </div>

    <div v-if="customizeOpen" class="scrim" @click="customizeOpen = false"></div>
    <aside class="dash-drawer" :class="{ open: customizeOpen }" aria-label="Customize Home">
      <div class="d-head">
        <div>
          <h2>Customize Home</h2>
          <span class="hint">Show, hide, and reorder modules</span>
        </div>
        <button type="button" class="d-close" aria-label="Close" @click="customizeOpen = false">×</button>
      </div>
      <div class="d-list">
        <div v-for="(row, index) in layout" :key="row.id" class="drow" :class="{ off: !row.on }">
          <div class="d-move">
            <button type="button" :disabled="index === 0" aria-label="Move up" @click="onMove(index, -1)">▲</button>
            <button type="button" :disabled="index === layout.length - 1" aria-label="Move down" @click="onMove(index, 1)">▼</button>
          </div>
          <div class="d-info">
            <div class="d-name">{{ DASHBOARD_MODULE_META[row.id].title }}</div>
            <div class="d-desc">{{ DASHBOARD_MODULE_META[row.id].hint }}</div>
          </div>
          <label class="d-tog">
            <input type="checkbox" :checked="row.on" @change="onToggle(row.id)">
            <i></i>
          </label>
        </div>
      </div>
      <div class="d-foot">
        <AppButton variant="ghost" @click="onReset">Reset</AppButton>
        <AppButton variant="primary" @click="customizeOpen = false">Done</AppButton>
      </div>
    </aside>
  </div>
</template>

<style scoped>
.ops-body.triage {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.incidents {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.incident {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 14px;
  border-radius: var(--radius);
  border: 1px solid rgba(248,113,113,0.35);
  background: rgba(248,113,113,0.08);
  flex-wrap: wrap;
}
.incident.warn {
  border-color: rgba(251,191,36,0.4);
  background: rgba(251,191,36,0.08);
}
.incident strong { font-size: 13px; font-weight: 650; }
.incident span { color: var(--text-secondary); font-size: 13px; }
.incident .spacer { flex: 1; }
.pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 10px;
  border-radius: 2px;
  font-size: 12px;
  font-weight: 600;
}
.pill::before {
  content: "";
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: currentColor;
}
.pill.failed { background: var(--red-muted); color: var(--red); }
.pill.running { background: var(--green-muted); color: var(--green); }
.pill.stopped { background: var(--gray-muted); color: var(--gray); }
.pill.unreach { background: var(--red-muted); color: var(--red); }
.triage-body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 320px;
  gap: 24px;
  min-height: 0;
  flex: 1;
}
.triage-body.full { grid-template-columns: 1fr; }
.feed-col { min-width: 0; display: flex; flex-direction: column; gap: 22px; }
.section-label {
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--text-dim);
  margin-bottom: 10px;
}
.feed { display: flex; flex-direction: column; gap: 8px; }
.row {
  display: grid;
  grid-template-columns: 1fr auto auto;
  align-items: center;
  gap: 12px;
  padding: 12px 14px;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  cursor: pointer;
}
.row.loud { border-color: rgba(248,113,113,0.35); }
.row h3 { font-size: 14px; font-weight: 650; }
.row .meta { color: var(--text-dim); font-size: 12px; margin-top: 2px; }
.chip {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
  background: rgba(255,255,255,0.04);
  border: 1px solid var(--line);
  padding: 3px 8px;
  border-radius: 2px;
  white-space: nowrap;
}
.chip.self { color: var(--accent); border-color: rgba(0,144,248,0.3); }
.side { display: flex; flex-direction: column; gap: 18px; }
.panel {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 16px;
}
.panel h2 { font-size: 13px; font-weight: 700; margin-bottom: 12px; }
.triage-home-dev {
  display: flex;
  justify-content: space-between;
  align-items: center;
  width: 100%;
  text-align: left;
  font: inherit;
  color: var(--text);
  background: none;
  border: 0;
  border-top: 1px solid var(--line);
  padding: 10px 0;
  cursor: pointer;
}
.triage-home-dev:first-of-type { border-top: 0; padding-top: 0; }
.triage-home-dev b { font-weight: 650; }
.triage-home-dev small {
  display: block;
  color: var(--text-dim);
  font-size: 11px;
  font-weight: 500;
  margin-top: 2px;
}
.side-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); flex-shrink: 0; }
.side-dot.off { background: var(--red); }
.empty {
  border: 1px dashed var(--line);
  border-radius: var(--radius);
  padding: 14px 10px;
  text-align: center;
  color: var(--text-dim);
  font-size: 11.5px;
}
.scrim {
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.5);
  z-index: 65;
}
.dash-drawer {
  position: fixed;
  top: 0;
  right: 0;
  bottom: 0;
  width: 300px;
  background: var(--drawer-bg);
  border-left: 1px solid var(--line);
  transform: translateX(100%);
  transition: transform 0.18s ease;
  z-index: 80;
  display: flex;
  flex-direction: column;
}
.dash-drawer.open { transform: none; }
.d-head {
  display: flex;
  align-items: center;
  padding: 14px;
  border-bottom: 1px solid var(--line);
}
.d-head h2 { font-size: 13px; font-weight: 700; }
.d-head .hint { display: block; color: var(--text-dim); font-size: 11px; margin-top: 2px; font-weight: 400; }
.d-close {
  margin-left: auto;
  background: none;
  border: none;
  color: var(--text-dim);
  font-size: 18px;
  cursor: pointer;
  padding: 2px 6px;
}
.d-close:hover { color: var(--text); }
.d-list { flex: 1; overflow-y: auto; padding: 12px 14px; }
.drow {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  margin-bottom: 6px;
  background: var(--panel);
}
.drow.off { opacity: 0.5; }
.d-info { min-width: 0; flex: 1; }
.d-name { font-size: 12.5px; font-weight: 600; }
.d-desc { font-size: 10.5px; color: var(--text-dim); margin-top: 1px; }
.d-move { display: flex; flex-direction: column; gap: 2px; }
.d-move button {
  width: 18px;
  height: 14px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(255,255,255,0.05);
  border: 1px solid var(--line);
  border-radius: 2px;
  color: var(--text-dim);
  font-size: 8px;
  cursor: pointer;
  padding: 0;
  line-height: 1;
}
.d-move button:hover { color: var(--text); }
.d-move button:disabled { opacity: 0.3; cursor: default; }
.d-tog { position: relative; width: 26px; height: 15px; flex-shrink: 0; cursor: pointer; }
.d-tog input { position: absolute; opacity: 0; inset: 0; cursor: pointer; }
.d-tog i {
  position: absolute;
  inset: 0;
  border-radius: 8px;
  background: rgba(255,255,255,0.12);
  pointer-events: none;
}
.d-tog i::after {
  content: '';
  position: absolute;
  left: 2px;
  top: 2px;
  width: 11px;
  height: 11px;
  border-radius: 50%;
  background: var(--text-dim);
}
.d-tog input:checked + i { background: rgba(0,144,248,0.4); }
.d-tog input:checked + i::after { transform: translateX(11px); background: var(--accent); }
.d-foot {
  border-top: 1px solid var(--line);
  padding: 12px 14px;
  display: flex;
  gap: 8px;
}
.d-foot :deep(.app-btn) { flex: 1; justify-content: center; }

:global(:root[data-theme="light"]) .chip { background: rgba(0,0,0,0.04); }

@media (max-width: 900px) {
  .triage-body { grid-template-columns: 1fr; }
  .row { grid-template-columns: 1fr auto; }
  .row .pill { grid-column: 2; }
  .dash-drawer { width: min(320px, 92vw); }
}
</style>
