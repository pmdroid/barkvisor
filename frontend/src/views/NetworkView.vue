<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import api from '../api/client'
import type { Network, HostInterface, BridgeInfo } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import AppModal from '../components/ui/AppModal.vue'
import { useToastStore } from '../stores/toast'

const toast = useToastStore()

// Data
const networks = ref<Network[]>([])
const hostInterfaces = ref<HostInterface[]>([])
const bridges = ref<BridgeInfo[]>([])

// Network form
const showCreate = ref(false)
const editingId = ref<string | null>(null)
const newName = ref('')
const newMode = ref<'nat' | 'bridged'>('nat')
const newBridge = ref('')
const newDns = ref('')
const loading = ref(false)
const error = ref('')

// Bridge management
const showBridges = ref(false)
const bridgeLoading = ref<string | null>(null)

// Delete
const deleteTarget = ref<{ id: string; name: string } | null>(null)
const deleting = ref(false)

// Helpers
function getBridgeStatus(ifaceName: string): BridgeInfo | undefined {
  return bridges.value.find(b => b.interface === ifaceName)
}

function getBridgeStatusForNetwork(n: Network): string | null {
  if (n.mode !== 'bridged' || !n.bridge) return null
  const info = getBridgeStatus(n.bridge)
  return info?.status || 'not_configured'
}

function bridgeBadgeClass(status: string): string {
  if (status === 'active') return 'badge-green'
  if (status === 'installed') return 'badge-accent'
  return 'badge-gray'
}

function bridgeBadgeLabel(status: string): string {
  if (status === 'active') return 'active'
  if (status === 'installed') return 'installed'
  return 'no bridge'
}

const selectedInterfaceBridge = computed(() => {
  if (!newBridge.value) return null
  return getBridgeStatus(newBridge.value)
})

const usedBridgeInterfaces = computed(() => {
  const used = new Map<string, string>()
  for (const n of networks.value) {
    if (n.mode === 'bridged' && n.bridge) {
      if (editingId.value && n.id === editingId.value) continue
      used.set(n.bridge, n.name)
    }
  }
  return used
})

const selectedInterfaceNeedsBridge = computed(() => {
  if (!newBridge.value) return false
  const info = selectedInterfaceBridge.value
  return !info || info.status === 'not_configured'
})

function interfaceIp(ifaceName: string): string {
  const iface = hostInterfaces.value.find(i => i.name === ifaceName)
  return iface?.ipAddress || ''
}

// Fetch data
async function fetchNetworks() {
  const { data } = await api.get('/networks')
  networks.value = data
}

async function fetchInterfaces() {
  try {
    const { data } = await api.get('/system/interfaces')
    hostInterfaces.value = data
  } catch {}
}

async function fetchBridges() {
  try {
    const { data } = await api.get('/system/bridges')
    bridges.value = data
  } catch {}
}

async function fetchAll() {
  await Promise.all([fetchNetworks(), fetchInterfaces(), fetchBridges()])
}

let bridgePoll: number | undefined

onMounted(() => {
  fetchAll()
})

watch(showBridges, (open) => {
  if (open) {
    fetchInterfaces()
    fetchBridges()
    bridgePoll = window.setInterval(fetchBridges, 7000)
  } else if (bridgePoll) {
    clearInterval(bridgePoll)
    bridgePoll = undefined
  }
})

onUnmounted(() => {
  if (bridgePoll) clearInterval(bridgePoll)
})

// Network CRUD
function resetForm() {
  newName.value = ''
  newMode.value = 'nat'
  newBridge.value = ''
  newDns.value = ''
  error.value = ''
  editingId.value = null
}

function openCreate() {
  resetForm()
  showCreate.value = true
  fetchInterfaces()
  fetchBridges()
}

function openEdit(n: Network) {
  editingId.value = n.id
  newName.value = n.name
  newMode.value = n.mode
  newBridge.value = n.bridge || ''
  newDns.value = n.dnsServer || ''
  error.value = ''
  showCreate.value = true
  fetchInterfaces()
  fetchBridges()
}

async function saveNetwork() {
  error.value = ''
  if (!newName.value.trim()) { error.value = 'Name required'; return }
  if (newMode.value === 'bridged' && !newBridge.value) { error.value = 'Bridge interface required for bridged mode'; return }
  loading.value = true
  try {
    const body: any = {
      name: newName.value.trim(),
      mode: newMode.value,
      bridge: newMode.value === 'bridged' ? newBridge.value : undefined,
      dnsServer: newMode.value === 'nat' ? (newDns.value || (editingId.value ? '' : undefined)) : undefined,
    }
    if (editingId.value) {
      await api.patch(`/networks/${editingId.value}`, body)
    } else {
      await api.post('/networks', body)
    }
    showCreate.value = false
    resetForm()
    await fetchNetworks()
  } catch (e: any) { error.value = e.response?.data?.reason || e.message }
  finally { loading.value = false }
}

function deleteNetwork(id: string, name: string) {
  deleteTarget.value = { id, name }
}

async function doDeleteNetwork() {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    const { id } = deleteTarget.value
    await Promise.all([
      api.delete(`/networks/${id}`).then(() => fetchNetworks()),
      new Promise(r => setTimeout(r, 400))
    ])
  } catch (e: any) { toast.error(e.response?.data?.reason || e.message) }
  finally {
    deleting.value = false
    deleteTarget.value = null
  }
}

// Bridge management
async function setupBridge(ifaceName: string) {
  bridgeLoading.value = ifaceName
  try {
    await api.post('/system/bridges', { interface: ifaceName })
    toast.success(`Bridge installed for ${ifaceName}`)
    await Promise.all([fetchBridges(), fetchNetworks()])
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}

async function removeBridge(ifaceName: string) {
  bridgeLoading.value = ifaceName
  try {
    await api.delete(`/system/bridges/${ifaceName}`)
    toast.success(`Bridge removed for ${ifaceName}`)
    await fetchBridges()
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}

async function startBridge(ifaceName: string) {
  bridgeLoading.value = ifaceName
  try {
    await api.post(`/system/bridges/${ifaceName}/start`)
    toast.success(`Bridge started for ${ifaceName}`)
    await fetchBridges()
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}

async function stopBridge(ifaceName: string) {
  bridgeLoading.value = ifaceName
  try {
    await api.post(`/system/bridges/${ifaceName}/stop`)
    toast.success(`Bridge stopped for ${ifaceName}`)
    await fetchBridges()
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}

async function setupBridgeInline() {
  if (!newBridge.value) return
  bridgeLoading.value = newBridge.value
  try {
    await api.post('/system/bridges', { interface: newBridge.value })
    toast.success(`Bridge installed for ${newBridge.value}`)
    await Promise.all([fetchBridges(), fetchNetworks()])
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}
</script>

<template>
  <div class="page-header">
    <h1>Networks</h1>
    <div style="display:flex;gap:8px;align-items:center">
      <AppButton icon="settings" @click="showBridges = true">Manage Bridges</AppButton>
      <AppButton variant="primary" icon="plus" @click="openCreate">Create Network</AppButton>
    </div>
  </div>

  <EmptyState v-if="networks.length === 0" icon="globe" title="No networks configured. VMs use NAT networking by default." />

  <DataTable v-else :columns="[
    { key: 'name', label: 'Name' },
    { key: 'mode', label: 'Mode' },
    { key: 'bridge', label: 'Bridge' },
    { key: 'dns', label: 'DNS' },
    { key: 'actions', label: '', align: 'right' },
  ]">
    <tr v-for="n in networks" :key="n.id">
      <td style="font-weight:500">{{ n.name }}</td>
      <td><span class="badge" :class="n.mode === 'nat' ? 'badge-accent' : 'badge-blue'">{{ n.mode }}</span></td>
      <td>
        <template v-if="n.bridge">
          <span style="display:flex;align-items:center;gap:6px">
            {{ n.bridge }}
            <span v-if="interfaceIp(n.bridge)" class="mono" style="color:var(--text-secondary);font-size:12px">{{ interfaceIp(n.bridge) }}</span>
            <span v-if="getBridgeStatusForNetwork(n)" class="badge" :class="bridgeBadgeClass(getBridgeStatusForNetwork(n)!)">{{ bridgeBadgeLabel(getBridgeStatusForNetwork(n)!) }}</span>
          </span>
        </template>
        <template v-else>-</template>
      </td>
      <td class="mono" style="color:var(--text-secondary)">{{ n.dnsServer || '-' }}</td>
      <td style="text-align:right">
        <div v-if="!n.isDefault" style="display:flex;gap:4px;justify-content:flex-end">
          <AppButton size="sm" @click="openEdit(n)">Edit</AppButton>
          <AppButton size="sm" @click="deleteNetwork(n.id, n.name)">Delete</AppButton>
        </div>
      </td>
    </tr>
  </DataTable>

  <!-- Bridge Management Modal -->
  <AppModal v-if="showBridges" title="Manage Bridges" max-width="800px" @close="showBridges = false">
    <EmptyState v-if="hostInterfaces.length === 0" title="Loading interfaces..." style="padding:24px" />
    <DataTable v-else :columns="[
      { key: 'interface', label: 'Interface' },
      { key: 'ip', label: 'IP' },
      { key: 'status', label: 'Status' },
      { key: 'actions', label: '' },
    ]">
      <tr v-for="iface in hostInterfaces" :key="iface.name">
        <td style="font-weight:500">
          {{ iface.name }}
          <div v-if="iface.displayName !== iface.name" style="color:var(--text-secondary);font-size:11px">{{ iface.displayName }}</div>
        </td>
        <td class="mono" style="color:var(--text-secondary)">{{ iface.ipAddress || '-' }}</td>
        <td>
          <span class="badge" :class="bridgeBadgeClass(getBridgeStatus(iface.name)?.status || 'not_configured')">
            {{ bridgeBadgeLabel(getBridgeStatus(iface.name)?.status || 'not_configured') }}
          </span>
        </td>
        <td style="text-align:right">
          <template v-if="bridgeLoading === iface.name">
            <AppButton size="sm" disabled>Working...</AppButton>
          </template>
          <template v-else-if="getBridgeStatus(iface.name)?.status === 'active'">
            <div style="display:flex;gap:4px;justify-content:flex-end">
              <AppButton size="sm" @click="stopBridge(iface.name)">Stop</AppButton>
              <AppButton size="sm" variant="danger" @click="removeBridge(iface.name)">Remove</AppButton>
            </div>
          </template>
          <template v-else-if="getBridgeStatus(iface.name)?.status === 'installed'">
            <div style="display:flex;gap:4px;justify-content:flex-end">
              <AppButton size="sm" @click="startBridge(iface.name)">Start</AppButton>
              <AppButton size="sm" variant="danger" @click="removeBridge(iface.name)">Remove</AppButton>
            </div>
          </template>
          <template v-else>
            <AppButton size="sm" @click="setupBridge(iface.name)">Setup</AppButton>
          </template>
        </td>
      </tr>
    </DataTable>
    <template #actions>
      <AppButton @click="showBridges = false">Close</AppButton>
    </template>
  </AppModal>

  <!-- Create/Edit Network Modal -->
  <AppModal v-if="showCreate" :title="(editingId ? 'Edit' : 'Create') + ' Network'" @close="showCreate = false">
    <div class="form-group"><label>Name</label><input v-model="newName" placeholder="my-network" /></div>
    <div class="form-group">
      <label>Mode</label>
      <AppSelect v-model="newMode">
        <option value="nat">NAT</option>
        <option value="bridged">Bridged</option>
      </AppSelect>
    </div>
    <div v-if="newMode === 'bridged'" class="form-group">
      <label>Bridge Interface</label>
      <AppSelect v-model="newBridge">
        <option value="" disabled>Select interface...</option>
        <option v-for="iface in hostInterfaces" :key="iface.name" :value="iface.name"
          :disabled="usedBridgeInterfaces.has(iface.name)">
          {{ iface.name }}{{ iface.ipAddress ? ` (${iface.ipAddress})` : '' }}{{ usedBridgeInterfaces.has(iface.name) ? ` — used by "${usedBridgeInterfaces.get(iface.name)}"` : iface.bridgeStatus === 'active' ? ' — active' : iface.bridgeStatus === 'installed' ? ' — installed' : '' }}
        </option>
      </AppSelect>
      <div v-if="selectedInterfaceNeedsBridge" class="bridge-warning">
        <span style="color:var(--text-secondary);font-size:13px">No bridge configured for this interface.</span>
        <AppButton size="sm" style="margin-left:8px" :loading="bridgeLoading === newBridge" loading-text="Setting up..." @click="setupBridgeInline">Setup Bridge</AppButton>
      </div>
      <div v-else-if="selectedInterfaceBridge?.status === 'installed'" class="bridge-note">
        <span style="color:var(--text-secondary);font-size:13px">Bridge is installed but not currently running.</span>
        <AppButton size="sm" style="margin-left:8px" :loading="bridgeLoading === newBridge" loading-text="Starting..." @click="startBridge(newBridge)">Start Bridge</AppButton>
      </div>
    </div>
    <div v-if="newMode === 'nat'" class="form-group">
      <label>DNS Server</label>
      <input v-model="newDns" placeholder="8.8.8.8 (optional)" />
    </div>
    <FormError v-if="error" :message="error" />
    <template #actions>
      <AppButton @click="showCreate = false">Cancel</AppButton>
      <AppButton variant="primary" :loading="loading" :loading-text="'Saving...'" @click="saveNetwork">{{ editingId ? 'Save' : 'Create' }}</AppButton>
    </template>
  </AppModal>

  <ConfirmDialog
    v-if="deleteTarget"
    title="Delete Network"
    :message="`Delete network &quot;${deleteTarget.name}&quot;?`"
    confirm-label="Delete"
    :danger="true"
    :loading="deleting"
    @confirm="doDeleteNetwork"
    @cancel="deleteTarget = null"
  />
</template>

<style scoped>
.bridge-warning, .bridge-note {
  display: flex;
  align-items: center;
  margin-top: 6px;
  padding: 8px 10px;
  border-radius: var(--radius-xs);
}
.bridge-warning {
  background: var(--red-muted);
}
.bridge-note {
  background: var(--accent-muted);
}
</style>
