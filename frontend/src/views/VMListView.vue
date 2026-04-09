<script setup lang="ts">
import { onMounted, onUnmounted, ref, reactive } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useVMStore } from '../stores/vms'
import { useToastStore } from '../stores/toast'
import api from '../api/client'
import type { SystemStats, GuestInfo, Network, PortForwardRule } from '../api/types'
import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import AppIcon from '../components/ui/AppIcon.vue'
import { pct } from '../utils/format'

const store = useVMStore()
const toast = useToastStore()
const router = useRouter()
const route = useRoute()
const showCreate = ref(false)
const stats = ref<SystemStats | null>(null)
const guestInfoMap = reactive<Record<string, GuestInfo>>({})
const networkMap = reactive<Record<string, Network>>({})
const actionLoading = reactive<Record<string, boolean>>({})
const copied = reactive<Record<string, boolean>>({})

async function fetchStats() {
  try {
    const { data } = await api.get('/system/stats')
    stats.value = data
  } catch { /* ignore */ }
}

async function fetchGuestInfo() {
  for (const vm of store.vms) {
    if (vm.state === 'running') {
      try {
        const { data } = await api.get(`/vms/${vm.id}/guest-info`)
        guestInfoMap[vm.id] = data
      } catch { /* ignore */ }
    } else {
      delete guestInfoMap[vm.id]
    }
  }
}

async function fetchNetworks() {
  try {
    const { data } = await api.get('/networks')
    for (const n of data as Network[]) {
      networkMap[n.id] = n
    }
  } catch { /* ignore */ }
}

function vmPortForwards(vm: typeof store.vms[0]): PortForwardRule[] {
  return vm.portForwards ?? []
}

function isNatVM(vm: typeof store.vms[0]): boolean {
  if (!vm.networkId) return true
  const net = networkMap[vm.networkId]
  return !net || net.mode === 'nat'
}

let pollTimer: number
onMounted(async () => {
  await store.fetchAll()
  fetchStats()
  fetchGuestInfo()
  fetchNetworks()
  pollTimer = window.setInterval(() => {
    fetchStats()
    store.fetchAll().then(fetchGuestInfo)
  }, 5000)
  if (route.query.create) {
    showCreate.value = true
    router.replace({ path: '/vms' })
  }
})
onUnmounted(() => clearInterval(pollTimer))

function osLabel(vm: typeof store.vms[0]) {
  const gi = guestInfoMap[vm.id]
  if (gi?.osName) {
    return gi.osVersion ? `${gi.osName} ${gi.osVersion}` : gi.osName
  }
  return vm.vmType.startsWith('windows') ? 'Windows' : 'Linux'
}


function primaryIp(vm: typeof store.vms[0]): string | null {
  const gi = guestInfoMap[vm.id]
  if (!gi?.ipAddresses?.length) return null
  return gi.ipAddresses[0]
}

async function copyText(key: string, text: string) {
  try {
    await navigator.clipboard.writeText(text)
    copied[key] = true
    setTimeout(() => { copied[key] = false }, 1500)
  } catch { /* ignore */ }
}

async function doStart(id: string) {
  actionLoading[id] = true
  try {
    await store.start(id)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    actionLoading[id] = false
  }
}

const restartLoading = reactive<Record<string, boolean>>({})

async function doRestart(id: string) {
  restartLoading[id] = true
  try {
    await store.restart(id)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    restartLoading[id] = false
  }
}

const stopConfirm = ref<{ id: string; name: string; method: 'acpi' | 'force' } | null>(null)

function requestStop(id: string, method: 'acpi' | 'force') {
  const vm = store.vms.find(v => v.id === id)
  stopConfirm.value = { id, name: vm?.name || id, method }
}

async function doStop() {
  if (!stopConfirm.value) return
  const { id, method } = stopConfirm.value
  actionLoading[id] = true
  try {
    await store.stop(id, { method })
    stopConfirm.value = null
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    actionLoading[id] = false
  }
}

</script>

<template>
  <div class="page-header">
    <h1>Virtual Machines</h1>
    <AppButton variant="primary" icon="plus" @click="showCreate = true">Create VM</AppButton>
  </div>

  <!-- System Stats -->
  <div v-if="stats" class="stats-row">
    <div class="stat-card">
      <div class="stat-label">Host CPU</div>
      <div class="stat-value">{{ stats.hostCpuPercent.toFixed(0) }}%</div>
      <div class="stat-bar"><div class="stat-bar-fill" :style="{ width: Math.min(stats.hostCpuPercent, 100) + '%', background: 'var(--accent)' }" /></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Host Memory</div>
      <div class="stat-value">{{ (stats.hostMemoryUsedMB / 1024).toFixed(1) }} / {{ (stats.hostMemoryTotalMB / 1024).toFixed(0) }} GB</div>
      <div class="stat-bar"><div class="stat-bar-fill" :style="{ width: pct(stats.hostMemoryUsedMB, stats.hostMemoryTotalMB) + '%', background: '#34d399' }" /></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">VM CPU Usage</div>
      <div class="stat-value">{{ stats.vmCpuPercent.toFixed(1) }}%</div>
      <div class="stat-bar"><div class="stat-bar-fill" :style="{ width: Math.min(stats.vmCpuPercent, 100) + '%', background: '#fbbf24' }" /></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">VM Memory</div>
      <div class="stat-value">{{ stats.vmMemoryMB >= 1024 ? (stats.vmMemoryMB / 1024).toFixed(1) + ' GB' : stats.vmMemoryMB + ' MB' }}</div>
      <div class="stat-sub">{{ stats.runningVMs }} of {{ stats.totalVMs }} VMs running</div>
    </div>
  </div>

  <EmptyState v-if="store.vms.length === 0 && !store.loading" icon="monitor" title="No virtual machines yet">
    <AppButton variant="primary" @click="showCreate = true">Create your first VM</AppButton>
  </EmptyState>

  <DataTable v-else :columns="[
    { key: 'name', label: 'Name' },
    { key: 'os', label: 'OS' },
    { key: 'resources', label: 'Resources' },
    { key: 'ip', label: 'IP / Ports' },
    { key: 'status', label: 'Status' },
    { key: 'actions', label: '' },
  ]">
        <tr v-for="vm in store.vms" :key="vm.id" class="vm-row" @click="router.push(`/vms/${vm.id}`)">
          <td>
            <div style="font-weight:500">{{ vm.name }}</div>
            <div v-if="vm.description" style="font-size:12px;color:var(--text-dim);margin-top:2px">{{ vm.description }}</div>
          </td>
          <td>
            <span style="font-size:13px">{{ osLabel(vm) }}</span>
          </td>
          <td>
            <span style="font-size:12px;color:var(--text-secondary)">{{ vm.cpuCount }} CPU &middot; {{ vm.memoryMB >= 1024 ? (vm.memoryMB / 1024).toFixed(vm.memoryMB % 1024 === 0 ? 0 : 1) + ' GB' : vm.memoryMB + ' MB' }}</span>
          </td>
          <td>
            <!-- Bridged: show IP:port links or plain IP -->
            <template v-if="!isNatVM(vm) && primaryIp(vm)">
              <div v-if="vmPortForwards(vm).length > 0" style="display:flex;flex-wrap:wrap;gap:4px">
                <div v-for="(pf, i) in vmPortForwards(vm)" :key="i" style="display:flex;align-items:center;gap:6px">
                  <a :href="(pf.guestPort === 443 || pf.guestPort === 9443 ? 'https://' : 'http://') + primaryIp(vm) + (pf.guestPort === 80 || pf.guestPort === 443 ? '' : ':' + pf.guestPort)" target="_blank" class="ip-text" style="text-decoration:none;color:var(--accent)" @click.stop>{{ primaryIp(vm) }}{{ pf.guestPort === 80 || pf.guestPort === 443 ? '' : ':' + pf.guestPort }}</a>
                  <button class="ip-copy" @click.stop="copyText(`${vm.id}-${pf.guestPort}`, `${primaryIp(vm)}${pf.guestPort === 80 || pf.guestPort === 443 ? '' : ':' + pf.guestPort}`)" :title="copied[`${vm.id}-${pf.guestPort}`] ? 'Copied!' : 'Copy address'">
                    <AppIcon v-if="!copied[`${vm.id}-${pf.guestPort}`]" name="copy" :size="13" style="stroke-width:2" />
                    <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                  </button>
                </div>
              </div>
              <div v-else style="display:flex;align-items:center;gap:6px">
                <code class="ip-text">{{ primaryIp(vm) }}</code>
                <button class="ip-copy" @click.stop="copyText(vm.id, primaryIp(vm)!)" :title="copied[vm.id] ? 'Copied!' : 'Copy IP'">
                  <AppIcon v-if="!copied[vm.id]" name="copy" :size="13" style="stroke-width:2" />
                  <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                </button>
              </div>
            </template>
            <!-- NAT: show port forwards -->
            <template v-else-if="isNatVM(vm) && vmPortForwards(vm).length > 0">
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                <div v-for="(pf, i) in vmPortForwards(vm)" :key="i" style="display:flex;align-items:center;gap:6px">
                  <code class="ip-text">localhost:{{ pf.hostPort }}</code>
                  <button class="ip-copy" @click.stop="copyText(`${vm.id}-${pf.hostPort}`, `localhost:${pf.hostPort}`)" :title="copied[`${vm.id}-${pf.hostPort}`] ? 'Copied!' : 'Copy address'">
                    <AppIcon v-if="!copied[`${vm.id}-${pf.hostPort}`]" name="copy" :size="13" style="stroke-width:2" />
                    <AppIcon v-else name="check" :size="13" style="color:var(--green)" />
                  </button>
                </div>
              </div>
            </template>
            <span v-else style="color:var(--text-dim);font-size:12px">-</span>
          </td>
          <td>
            <div style="display:flex;align-items:center;gap:6px">
              <span class="status-pill" :class="vm.state">{{ vm.state }}</span>
              <span v-if="vm.pendingChanges && vm.state === 'running'" class="restart-badge" title="Restart required to apply changes">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
                Restart needed
              </span>
            </div>
          </td>
          <td>
            <div style="display:flex;gap:6px;justify-content:flex-end" @click.stop>
              <AppButton v-if="vm.state === 'stopped' || vm.state === 'error'" variant="primary" size="sm" :disabled="actionLoading[vm.id]" @click="doStart(vm.id)">{{ actionLoading[vm.id] ? 'Starting...' : 'Start' }}</AppButton>
              <template v-else-if="vm.state === 'running'">
                <AppButton v-if="vm.pendingChanges" variant="warning" size="sm" :disabled="restartLoading[vm.id]" @click="doRestart(vm.id)">{{ restartLoading[vm.id] ? 'Restarting...' : 'Restart' }}</AppButton>
                <StopButtonGroup size="sm" :loading="actionLoading[vm.id]" @stop="requestStop(vm.id, $event)" />
              </template>
            </div>
          </td>
        </tr>
  </DataTable>

  <ConfirmDialog
    v-if="stopConfirm"
    :title="stopConfirm.method === 'force' ? 'Force Stop VM' : 'Shutdown VM'"
    :message="`Are you sure you want to ${stopConfirm.method === 'force' ? 'force stop' : 'shut down'} ${stopConfirm.name}?${stopConfirm.method === 'force' ? ' This may cause data loss.' : ''}`"
    :confirm-label="stopConfirm.method === 'force' ? 'Force Stop' : 'Shutdown'"
    :danger="stopConfirm.method === 'force'"
    :loading="actionLoading[stopConfirm.id]"
    @confirm="doStop"
    @cancel="stopConfirm = null"
  />

  <CreateVMDrawer v-if="showCreate" @close="showCreate = false" @created="showCreate = false; store.fetchAll(); fetchStats()" />
</template>

<style scoped>
.stats-row {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
  margin-bottom: 24px;
}
.stat-card {
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 16px;
}
.stat-label {
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--text-dim);
  margin-bottom: 6px;
}
.stat-value {
  font-size: 18px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  margin-bottom: 8px;
}
.stat-sub {
  font-size: 12px;
  color: var(--text-dim);
}
.stat-bar {
  height: 4px;
  background: rgba(255,255,255,0.06);
  border-radius: 2px;
  overflow: hidden;
}
.stat-bar-fill {
  height: 100%;
  border-radius: 2px;
  transition: width 0.5s ease;
}
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

@media (max-width: 1024px) {
  .stats-row { grid-template-columns: repeat(2, 1fr); }
}

@media (max-width: 768px) {
  .stats-row { grid-template-columns: 1fr; gap: 8px; margin-bottom: 16px; }
}
</style>
