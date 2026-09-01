<script setup lang="ts">
import AppSelect from '../ui/AppSelect.vue'
import CapabilityGate from '../ui/CapabilityGate.vue'
import UnsupportedHint from '../ui/UnsupportedHint.vue'
import type { Network, PortForwardRule, HostUSBDevice, USBPassthroughDevice } from '../../api/types'
import { useFeature } from '../../composables/useFeature'
import { usbCanPersist, usbPersistHint } from '../../composables/useUSBPicker'

const usb = useFeature('usbPassthrough')
const bridged = useFeature('bridgedNetworking')

defineProps<{
  networks: Network[]
  selectedNetworkId: string
  selectedNetwork: Network | null
  isNAT: boolean
  portForwards: PortForwardRule[]
  newPFProto: 'tcp' | 'udp'
  newPFHostPort: number | null
  newPFGuestPort: number | null
  selectedUSBDevices: USBPassthroughDevice[]
  showUSBPicker: boolean
  hostUSBDevices: HostUSBDevice[]
  isUSBSelected: (dev: HostUSBDevice) => boolean
  isAgent?: boolean
}>()

const emit = defineEmits<{
  'update:selectedNetworkId': [value: string]
  'update:newPFProto': [value: 'tcp' | 'udp']
  'update:newPFHostPort': [value: number | null]
  'update:newPFGuestPort': [value: number | null]
  'update:showUSBPicker': [value: boolean]
  addPortForward: []
  removePortForward: [index: number]
  removeUSBDevice: [dev: USBPassthroughDevice]
  toggleUSBDevice: [dev: HostUSBDevice]
  openUSBPicker: []
}>()
</script>

<template>
  <div>
    <h3 class="step-title">Network</h3>
    <div class="form-group">
      <label>Network</label>
      <AppSelect
        :modelValue="selectedNetworkId"
        @update:modelValue="emit('update:selectedNetworkId', $event as string)"
      >
        <option v-for="n in networks" :key="n.id" :value="n.id">
          {{ n.name }} ({{ n.mode }})
        </option>
      </AppSelect>
      <span style="font-size:11px;color:var(--text-dim);margin-top:4px;display:block">
        <template v-if="isAgent">
          Agent cage: NAT out to the WAN only (WAN yes, house no). Isolated is opt-in.
          Bridged, USB, and host ports are off.
        </template>
        <template v-else>
          NAT: internet via this device (also used when no network is selected).
          Bridged (Home Network): LAN IP.
          Isolated (Private): no host, LAN, or internet.
          Publish a service with NAT plus port forwards — not a separate mode.
        </template>
        Manage networks under <router-link to="/networks"><strong>Networks</strong></router-link>.
      </span>
      <UnsupportedHint v-if="!bridged.available" :text="bridged.explanation" />
    </div>
    <div v-if="selectedNetworkId && selectedNetwork" style="margin-top:12px;font-size:12px;color:var(--text-secondary)">
      <div style="margin-bottom:4px;font-weight:500">{{ selectedNetwork.name }} &mdash; {{ selectedNetwork.mode }}</div>
      <p v-if="selectedNetwork.mode === 'bridged'" style="margin:8px 0 0;font-size:11px;color:var(--text-dim)">
        Bridged Workloads use LAN DHCP by default. Set a static IPv4 on a cloud-init Workload, or paste the Workload MAC into your router. Installer ISOs are not configured by BarkVisor.
      </p>
    </div>

    <!-- Port Forwarding (NAT only; Agent class forbids hostfwd) -->
    <div v-if="isNAT && !isAgent" style="margin-top:16px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
        <label style="margin:0">Port Forwarding</label>
      </div>
      <div v-if="portForwards.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
        <div
          v-for="(pf, i) in portForwards"
          :key="i"
          style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;border-bottom:1px solid var(--border-subtle)"
        >
          <span class="mono">{{ pf.protocol.toUpperCase() }} {{ pf.hostPort }} &rarr; {{ pf.guestPort }}</span>
          <button class="btn-ghost btn-sm" style="color:var(--red);flex-shrink:0;margin-left:8px" @click="emit('removePortForward', i)">Remove</button>
        </div>
      </div>
      <div style="display:flex;gap:6px;align-items:end">
        <div style="width:70px">
          <label style="font-size:11px;color:var(--text-dim)">Proto</label>
          <AppSelect
            :modelValue="newPFProto"
            size="sm"
            @update:modelValue="emit('update:newPFProto', $event as 'tcp' | 'udp')"
          >
            <option value="tcp">TCP</option>
            <option value="udp">UDP</option>
          </AppSelect>
        </div>
        <div style="flex:1">
          <label style="font-size:11px;color:var(--text-dim)">Host Port</label>
          <input
            :value="newPFHostPort ?? ''"
            type="number"
            min="1"
            max="65535"
            placeholder="8080"
            style="font-size:12px"
            @input="emit('update:newPFHostPort', ($event.target as HTMLInputElement).value === '' ? null : Number(($event.target as HTMLInputElement).value))"
          />
        </div>
        <div style="flex:1">
          <label style="font-size:11px;color:var(--text-dim)">Guest Port</label>
          <input
            :value="newPFGuestPort ?? ''"
            type="number"
            min="1"
            max="65535"
            placeholder="80"
            style="font-size:12px"
            @input="emit('update:newPFGuestPort', ($event.target as HTMLInputElement).value === '' ? null : Number(($event.target as HTMLInputElement).value))"
          />
        </div>
        <button
          class="btn-ghost btn-sm"
          style="margin-bottom:1px"
          :disabled="!newPFHostPort || !newPFGuestPort"
          @click="emit('addPortForward')"
        >
          Add
        </button>
      </div>
      <span style="font-size:11px;color:var(--text-dim);margin-top:6px;display:block">
        Forward traffic from a host port to a port inside the VM.
      </span>
    </div>

    <!-- USB Passthrough (Agent class forbids USB) -->
    <CapabilityGate v-if="!isAgent" feature="usbPassthrough" v-slot="{ available }" style="margin-top:16px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
        <label style="margin:0">USB Passthrough</label>
        <button class="btn-ghost btn-sm" :disabled="!available" @click="emit('openUSBPicker')">
          <span style="display:flex;align-items:center;gap:4px">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            Add
          </span>
        </button>
      </div>
      <div v-if="selectedUSBDevices.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
        <div
          v-for="dev in selectedUSBDevices"
          :key="dev.deviceId || `${dev.vendorId}:${dev.productId}:${dev.serialNumber || ''}`"
          style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;border-bottom:1px solid var(--border-subtle)"
        >
          <span>{{ dev.label || `${dev.vendorId}:${dev.productId}` }} <span class="badge badge-gray" style="font-size:10px;margin-left:4px">{{ dev.deviceId || `${dev.vendorId}:${dev.productId}` }}</span></span>
          <button class="btn-ghost btn-sm" style="color:var(--red);flex-shrink:0;margin-left:8px" @click="emit('removeUSBDevice', dev)">Remove</button>
        </div>
      </div>
      <span v-else-if="available" style="font-size:11px;color:var(--text-dim);display:block">
        No USB devices selected. Pass physical USB devices from this device to the VM.
      </span>
    </CapabilityGate>

    <Teleport to="body">
    <div
      v-if="usb.available && showUSBPicker"
      class="modal-overlay stack"
      @click.self="emit('update:showUSBPicker', false)"
    >
      <div class="modal" style="max-width:480px">
        <h2>Select USB Devices</h2>
        <div v-if="hostUSBDevices.length === 0" class="empty" style="padding:24px 0">
          <p>No USB devices detected on this device.</p>
        </div>
        <div v-else style="background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden">
          <table>
            <thead><tr><th></th><th>Device</th><th>IDs</th></tr></thead>
            <tbody>
              <tr
                v-for="dev in hostUSBDevices"
                :key="dev.id || `${dev.vendorId}:${dev.productId}:${dev.serialNumber || ''}`"
                :style="!usbCanPersist(dev) ? 'opacity:0.5' : 'cursor:pointer'"
                @click="usbCanPersist(dev) && emit('toggleUSBDevice', dev)"
              >
                <td style="width:32px;text-align:center">
                  <input
                    type="checkbox"
                    :checked="isUSBSelected(dev)"
                    :disabled="!usbCanPersist(dev)"
                    @click.stop="usbCanPersist(dev) && emit('toggleUSBDevice', dev)"
                  />
                </td>
                <td>
                  <div style="font-weight:500">{{ dev.productName || dev.name }}</div>
                  <div v-if="dev.manufacturer" style="font-size:11px;color:var(--text-dim)">{{ dev.manufacturer }}</div>
                  <div v-if="dev.claimedByVMId" style="font-size:11px;color:var(--red)">In use by {{ dev.claimedByVMName }}</div>
                  <div v-else-if="dev.attachable === false" style="font-size:11px;color:var(--text-dim)">{{ dev.excludedReason }}</div>
                  <div v-else-if="usbPersistHint(dev)" style="font-size:11px;color:var(--text-dim)">{{ usbPersistHint(dev) }}</div>
                </td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:10px">{{ dev.id || `${dev.vendorId}:${dev.productId}` }}</span></td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="modal-actions">
          <button class="btn-ghost" @click="emit('update:showUSBPicker', false)">Done</button>
        </div>
      </div>
    </div>
    </Teleport>
  </div>
</template>

<style scoped>
.step-title {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 16px;
  color: var(--text);
}
</style>
