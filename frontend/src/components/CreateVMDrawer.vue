<script setup lang="ts">
import { ref, onMounted, computed, watch } from 'vue'
import { useVMStore } from '../stores/vms'
import { useImageStore } from '../stores/images'
import { useToastStore } from '../stores/toast'
import api, { getWSTicket } from '../api/client'
import type { Network, Disk, PortForwardRule, HostUSBDevice, USBPassthroughDevice } from '../api/types'
import { useSSHKeyStore } from '../stores/sshKeys'
import FolderPicker from './FolderPicker.vue'
import CloudInitEditor from './CloudInitEditor.vue'
import AppSelect from './ui/AppSelect.vue'

const emit = defineEmits(['close', 'created'])

const vmStore = useVMStore()
const imageStore = useImageStore()
const toast = useToastStore()
const sshKeyStore = useSSHKeyStore()

// Wizard step
const step = ref(1)

// Step 1: OS & Name
const name = ref('')
const osType = ref<'linux' | 'windows'>('linux')
const vmType = computed(() => osType.value === 'windows' ? 'windows-arm64' : 'linux-arm64')

// Step 2: Hardware
const cpuCount = ref(2)
const memoryMB = ref(1024)
const displayResolution = ref('1280x800')
const uefi = ref(true)
const tpmEnabled = computed(() => osType.value === 'windows')

function selectOS(os: 'linux' | 'windows') {
  osType.value = os
  selectedImageId.value = ''
  if (os === 'windows') {
    cpuCount.value = 4
    memoryMB.value = 4096
    diskSizeGB.value = 64
    uefi.value = true
    mode.value = 'iso'
  } else {
    cpuCount.value = 2
    memoryMB.value = 1024
    diskSizeGB.value = 10
  }
}

// Step 3: Image
const mode = ref<'iso' | 'cloud'>('iso')
const selectedImageId = ref('')
const selectedSSHKeyId = ref('')
const showCloudInit = ref(false)
const cloudUserData = ref('')

// VirtIO Windows Drivers (conditional step for Windows)
const virtioWinAvailable = ref(false)
const virtioWinImageId = ref<string | null>(null)
const virtioWinDownloading = ref(false)
const virtioWinProgress = ref(0)
const virtioWinStatus = ref<string>('')
const virtioWinError = ref('')

// Dynamic step mapping: returns the "logical" step labels and total count
const needsDriverStep = computed(() => osType.value === 'windows' && !virtioWinAvailable.value)
const totalSteps = computed(() => needsDriverStep.value ? 7 : 6)

// Map logical step number to step content
// Without driver step: 1=OS, 2=HW, 3=Image, 4=Storage, 5=Network, 6=Summary
// With driver step:    1=OS, 2=HW, 3=Image, 4=Drivers, 5=Storage, 6=Network, 7=Summary
const stepLabels = computed(() => {
  const base = ['OS', 'Hardware', 'Image']
  if (needsDriverStep.value) base.push('Drivers')
  base.push('Storage', 'Network', 'Summary')
  return base
})

function stepContent(s: number): string {
  return stepLabels.value[s - 1] || ''
}

// Check virtio-win status when OS type changes
watch(osType, async (os) => {
  if (os === 'windows') {
    await checkVirtioWinStatus()
  }
})

async function checkVirtioWinStatus() {
  try {
    const { data } = await api.get('/system/virtio-win/status')
    virtioWinAvailable.value = data.available
    virtioWinImageId.value = data.imageId || null
  } catch {
    virtioWinAvailable.value = false
  }
}

async function startVirtioWinDownload() {
  virtioWinError.value = ''
  virtioWinDownloading.value = true
  virtioWinProgress.value = 0
  virtioWinStatus.value = 'downloading'

  try {
    const { data } = await api.post('/system/virtio-win/download')
    virtioWinImageId.value = data.imageId

    // Subscribe to SSE progress
    const ticket = await getWSTicket()
    const es = new EventSource(`/api/images/${data.imageId}/progress?ticket=${ticket}`)

    es.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)
        virtioWinProgress.value = msg.percent ?? 0
        virtioWinStatus.value = msg.status ?? 'downloading'

        if (msg.status === 'ready') {
          virtioWinAvailable.value = true
          virtioWinDownloading.value = false
          es.close()
          imageStore.fetchAll()
        } else if (msg.status === 'error') {
          virtioWinError.value = msg.error || 'Download failed'
          virtioWinDownloading.value = false
          es.close()
        }
      } catch {}
    }

    es.onerror = () => {
      // SSE disconnected — check final status
      es.close()
      if (virtioWinStatus.value !== 'ready') {
        virtioWinDownloading.value = false
        checkVirtioWinStatus()
      }
    }
  } catch (e: any) {
    virtioWinError.value = e.response?.data?.reason || e.message
    virtioWinDownloading.value = false
  }
}

// Step 4/5: Storage
const diskSource = ref<'new' | 'existing'>('new')
const diskSizeGB = ref(10)
const existingDiskId = ref('')
const availableDisks = ref<Disk[]>([])
const sharedPaths = ref<string[]>([])
const showFolderPicker = ref(false)

// USB passthrough
const hostUSBDevices = ref<HostUSBDevice[]>([])
const selectedUSBDevices = ref<USBPassthroughDevice[]>([])
const showUSBPicker = ref(false)

async function fetchUSBDevices() {
  try {
    const { data } = await api.get('/system/usb-devices')
    hostUSBDevices.value = data
  } catch { hostUSBDevices.value = [] }
}

function toggleUSBDevice(dev: HostUSBDevice) {
  const idx = selectedUSBDevices.value.findIndex(d => d.vendorId === dev.vendorId && d.productId === dev.productId)
  if (idx >= 0) {
    selectedUSBDevices.value.splice(idx, 1)
  } else {
    selectedUSBDevices.value.push({ vendorId: dev.vendorId, productId: dev.productId, label: dev.name })
  }
}

function isUSBSelected(dev: HostUSBDevice): boolean {
  return selectedUSBDevices.value.some(d => d.vendorId === dev.vendorId && d.productId === dev.productId)
}

function removeUSBDevice(dev: USBPassthroughDevice) {
  selectedUSBDevices.value = selectedUSBDevices.value.filter(d => !(d.vendorId === dev.vendorId && d.productId === dev.productId))
}

// Step 5/6: Network
const networks = ref<Network[]>([])
const selectedNetworkId = ref('')
const portForwards = ref<PortForwardRule[]>([])
const newPFProto = ref<'tcp' | 'udp'>('tcp')
const newPFHostPort = ref<number | null>(null)
const newPFGuestPort = ref<number | null>(null)

function addPortForward() {
  if (!newPFHostPort.value || !newPFGuestPort.value) return
  portForwards.value.push({
    protocol: newPFProto.value,
    hostPort: newPFHostPort.value,
    guestPort: newPFGuestPort.value,
  })
  newPFHostPort.value = null
  newPFGuestPort.value = null
}

function removePortForward(i: number) {
  portForwards.value.splice(i, 1)
}

const isNAT = computed(() => {
  if (!selectedNetworkId.value) return false
  const net = networks.value.find(n => n.id === selectedNetworkId.value)
  return net?.mode === 'nat'
})

// State
const error = ref('')
const loading = ref(false)
const showQemuCmd = ref(false)

const qemuCommand = computed(() => {
  const win = vmType.value.startsWith('windows')
  const parts: string[] = ['qemu-system-aarch64']

  parts.push('-machine virt -accel hvf -cpu host')
  parts.push(`-smp ${cpuCount.value} -m ${memoryMB.value}M`)
  parts.push('-drive if=pflash,format=raw,readonly=on,file=<efi-code.fd>')
  parts.push('-drive if=pflash,format=raw,file=<efi-vars.fd>')
  parts.push('-device qemu-xhci')

  const diskLabel = diskSource.value === 'existing' ? '<existing-disk>' : `<${name.value || 'vm'}-disk.qcow2>`
  if (win) {
    parts.push(`-drive file=${diskLabel},format=qcow2,if=none,id=boot0,cache=writethrough`)
    parts.push('-device nvme,drive=boot0,serial=boot')
  } else {
    parts.push(`-drive file=${diskLabel},format=qcow2,if=none,id=boot0,cache=writethrough`)
    parts.push('-device virtio-blk-pci,drive=boot0,bootindex=0')
  }

  if (selectedImage.value && mode.value === 'iso') {
    const isoName = `<${selectedImage.value.name}.iso>`
    parts.push(`-drive file=${isoName},format=raw,if=none,id=cdrom0,readonly=on,media=cdrom`)
    parts.push('-device virtio-blk-pci,drive=cdrom0,bootindex=1')
  }

  if (tpmEnabled.value) {
    parts.push('-chardev socket,id=chrtpm,path=<tpm.sock>')
    parts.push('-tpmdev emulator,id=tpm0,chardev=chrtpm')
    parts.push('-device tpm-tis-device,tpmdev=tpm0')
  }

  parts.push('-netdev user,id=net0')
  parts.push('-device virtio-net-pci,netdev=net0')

  parts.push('-chardev socket,id=serial0,path=<serial.sock>,server=on,wait=off')
  parts.push('-serial chardev:serial0')
  parts.push(`-vnc 127.0.0.1:<display>`)
  parts.push('-monitor unix:<mon.sock>,server,nowait')
  parts.push('-qmp unix:<qmp.sock>,server,nowait')

  const res = displayResolution.value.split('x')
  parts.push('-device ramfb')
  parts.push(`-device virtio-gpu-pci,xres=${res[0]},yres=${res[1]}`)
  parts.push('-device usb-kbd')
  parts.push('-device usb-tablet')
  parts.push('-device virtio-balloon-pci')
  parts.push('-display none')

  return parts.join(' \\\n  ')
})

onMounted(async () => {
  imageStore.fetchAll()
  sshKeyStore.fetchAll().then(() => {
    if (sshKeyStore.defaultKey) selectedSSHKeyId.value = sshKeyStore.defaultKey.id
  })
  try {
    const { data } = await api.get('/networks')
    networks.value = data
    const defaultNet = data.find((n: Network) => n.isDefault)
    if (defaultNet) selectedNetworkId.value = defaultNet.id
  } catch {}
  try {
    const { data } = await api.get('/disks')
    availableDisks.value = data.filter((d: Disk) => !d.vmId)
  } catch {}
})

const isoImages = computed(() => imageStore.images.filter(i => i.imageType === 'iso' && i.status === 'ready'))
const cloudImages = computed(() => imageStore.images.filter(i => i.imageType === 'cloud-image' && i.status === 'ready'))
const filteredImages = computed(() => {
  const list = mode.value === 'iso' ? isoImages.value : cloudImages.value
  return list
})

const selectedImage = computed(() => {
  if (!selectedImageId.value) return null
  return imageStore.images.find(i => i.id === selectedImageId.value) || null
})

const selectedNetwork = computed(() => {
  if (!selectedNetworkId.value) return null
  return networks.value.find(n => n.id === selectedNetworkId.value) || null
})

function canProceed(): boolean {
  const content = stepContent(step.value)
  switch (content) {
    case 'OS': return !!name.value.trim()
    case 'Hardware': return cpuCount.value >= 1 && memoryMB.value >= 128
    case 'Image': return !!selectedImageId.value
    case 'Drivers': return virtioWinAvailable.value
    case 'Storage': return diskSource.value === 'existing' ? !!existingDiskId.value : diskSizeGB.value >= 1
    case 'Network': return true
    case 'Summary': return true
    default: return false
  }
}

function next() {
  if (canProceed() && step.value < totalSteps.value) step.value++
}

function prev() {
  if (step.value > 1) step.value--
}

async function submit() {
  error.value = ''
  loading.value = true
  try {
    const req: any = {
      name: name.value.trim(),
      vmType: vmType.value,
      cpuCount: cpuCount.value,
      memoryMB: memoryMB.value,
      uefi: uefi.value,
      tpmEnabled: tpmEnabled.value,
    }
    if (diskSource.value === 'existing') {
      req.existingDiskId = existingDiskId.value
    } else {
      req.diskSizeGB = diskSizeGB.value
    }
    if (mode.value === 'iso') {
      req.isoId = selectedImageId.value
    } else {
      req.cloudImageId = selectedImageId.value
      const selectedKey = sshKeyStore.keys.find(k => k.id === selectedSSHKeyId.value)
      const keys = selectedKey ? [selectedKey.publicKey] : []
      const userData = cloudUserData.value.trim()
      if (keys.length || userData) {
        req.cloudInit = {
          sshAuthorizedKeys: keys.length ? keys : undefined,
          userData: userData || undefined,
        }
      }
    }
    if (displayResolution.value !== '1280x800') req.displayResolution = displayResolution.value
    if (selectedNetworkId.value) req.networkId = selectedNetworkId.value
    if (portForwards.value.length > 0) req.portForwards = portForwards.value
    if (sharedPaths.value.length > 0) req.sharedPaths = sharedPaths.value
    if (selectedUSBDevices.value.length > 0) req.usbDevices = selectedUSBDevices.value

    const result = await vmStore.create(req)
    if (result.taskID) {
      toast.info(`VM "${name.value.trim()}" is provisioning...`)
    }
    emit('created')
  } catch (e: any) {
    error.value = e.response?.data?.reason || e.message
  } finally {
    loading.value = false
  }
}

function formatBytes(b: number) {
  if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB'
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB'
  return b + ' B'
}
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal" style="max-width:520px">
      <h2>Create Virtual Machine</h2>

      <!-- Step indicator -->
      <div class="wizard-steps">
        <div v-for="s in totalSteps" :key="s" class="wizard-dot" :class="{ active: s === step, done: s < step }" @click="s < step ? step = s : null">
          {{ s }}
        </div>
      </div>

      <!-- Step: OS & Name -->
      <div v-if="stepContent(step) === 'OS'">
        <h3 class="step-title">Operating System</h3>
        <div class="form-group">
          <label>VM Name</label>
          <input v-model="name" placeholder="my-vm" @keyup.enter="next" autofocus />
        </div>
        <div class="form-group">
          <label>OS Type</label>
          <div class="os-grid">
            <div class="os-card" :class="{ selected: osType === 'linux' }" @click="selectOS('linux')">
              <span style="font-size:24px">&#x1f427;</span>
              <span>Linux</span>
            </div>
            <div class="os-card" :class="{ selected: osType === 'windows' }" @click="selectOS('windows')">
              <span style="font-size:24px">&#x1fa9f;</span>
              <span>Windows</span>
            </div>
            <div class="os-card disabled">
              <span style="font-size:24px">&#x1f34e;</span>
              <span>macOS</span>
              <span class="os-soon">soon</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Step: Hardware -->
      <div v-if="stepContent(step) === 'Hardware'">
        <h3 class="step-title">Hardware</h3>
        <div style="display:flex;gap:12px">
          <div class="form-group" style="flex:1">
            <label>CPU Cores</label>
            <input v-model.number="cpuCount" type="number" min="1" max="16" />
          </div>
          <div class="form-group" style="flex:1">
            <label>Memory (MB)</label>
            <input v-model.number="memoryMB" type="number" min="128" step="256" />
          </div>
        </div>
        <div class="form-group">
          <label>Display Resolution</label>
          <AppSelect v-model="displayResolution">
            <option value="1024x768">1024x768</option>
            <option value="1280x800">1280x800</option>
            <option value="1280x1024">1280x1024</option>
            <option value="1920x1080">1920x1080</option>
          </AppSelect>
        </div>
      </div>

      <!-- Step: Image -->
      <div v-if="stepContent(step) === 'Image'">
        <h3 class="step-title">Image</h3>
        <div style="display:flex;gap:8px;margin-bottom:16px">
          <button :class="mode === 'iso' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'" @click="mode = 'iso'; selectedImageId = ''">
            ISO Installer
          </button>
          <button v-if="osType === 'linux'" :class="mode === 'cloud' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'" @click="mode = 'cloud'; selectedImageId = ''">
            Cloud Image
          </button>
        </div>
        <div class="form-group">
          <label>{{ mode === 'iso' ? 'ISO Image' : 'Cloud Image' }}</label>
          <AppSelect v-model="selectedImageId">
            <option value="" disabled>Select an image...</option>
            <option v-for="img in filteredImages" :key="img.id" :value="img.id">
              {{ img.name }}{{ img.sizeBytes ? ` (${formatBytes(img.sizeBytes)})` : '' }}
            </option>
          </AppSelect>
          <div v-if="filteredImages.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
            No {{ mode === 'iso' ? 'ISO' : 'cloud' }} images available.
            Upload or download one in the Images section first.
          </div>
        </div>
        <div v-if="mode === 'cloud'" class="form-group">
          <label>SSH Key</label>
          <AppSelect v-model="selectedSSHKeyId">
            <option value="">None</option>
            <option v-for="sk in sshKeyStore.keys" :key="sk.id" :value="sk.id">
              {{ sk.name }}
            </option>
          </AppSelect>
          <div v-if="sshKeyStore.keys.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
            No SSH keys stored yet. Add keys in Settings first.
          </div>
        </div>
        <div v-if="mode === 'cloud'">
          <button class="btn-ghost btn-sm" style="margin-top:8px" @click="showCloudInit = !showCloudInit">
            {{ showCloudInit ? 'Hide' : 'Show' }} Cloud-Init Configuration
          </button>
          <div v-if="showCloudInit" class="form-group" style="margin-top:8px">
            <CloudInitEditor v-model="cloudUserData" />
          </div>
        </div>
      </div>

      <!-- Step: Drivers (Windows only, when virtio-win is missing) -->
      <div v-if="stepContent(step) === 'Drivers'">
        <h3 class="step-title">Windows Drivers</h3>
        <p style="font-size:13px;color:var(--text-secondary);margin-bottom:16px">
          Windows VMs require the VirtIO driver ISO for network, storage, and display drivers.
          This is a one-time download (~550 MB) from the Fedora project.
        </p>

        <div v-if="virtioWinAvailable" class="driver-status driver-ready">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--green)" stroke-width="2.5" stroke-linecap="round"><polyline points="20 6 9 17 4 12"/></svg>
          <span>VirtIO drivers are ready</span>
        </div>

        <div v-else-if="virtioWinDownloading" class="driver-status">
          <div style="width:100%">
            <div style="display:flex;justify-content:space-between;margin-bottom:6px;font-size:12px">
              <span>{{ virtioWinStatus === 'decompressing' ? 'Decompressing...' : 'Downloading VirtIO drivers...' }}</span>
              <span>{{ Math.round(virtioWinProgress) }}%</span>
            </div>
            <div class="progress-bar">
              <div class="progress-fill" :style="{ width: virtioWinProgress + '%' }"></div>
            </div>
          </div>
        </div>

        <div v-else>
          <button class="btn-primary" @click="startVirtioWinDownload" style="width:100%">
            Download VirtIO Drivers
          </button>
          <p v-if="virtioWinError" style="color:var(--red);font-size:12px;margin-top:8px">
            {{ virtioWinError }}
          </p>
        </div>

        <p style="font-size:11px;color:var(--text-dim);margin-top:12px">
          Source: fedorapeople.org/groups/virt/virtio-win
        </p>
      </div>

      <!-- Step: Storage -->
      <div v-if="stepContent(step) === 'Storage'">
        <h3 class="step-title">Storage</h3>
        <div style="display:flex;gap:8px;margin-bottom:16px">
          <button :class="diskSource === 'new' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'" @click="diskSource = 'new'">
            New Disk
          </button>
          <button :class="diskSource === 'existing' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'" @click="diskSource = 'existing'">
            Existing Disk
          </button>
        </div>

        <div v-if="diskSource === 'new'" class="form-group">
          <label>Disk Size (GB)</label>
          <input v-model.number="diskSizeGB" type="number" min="1" />
          <span style="font-size:11px;color:var(--text-dim);margin-top:4px;display:block">
            A QCOW2 virtual disk will be created. It grows dynamically — only used space is allocated on the host.
          </span>
        </div>

        <div v-if="diskSource === 'existing'" class="form-group">
          <label>Select Disk</label>
          <AppSelect v-model="existingDiskId">
            <option value="" disabled>Select a disk...</option>
            <option v-for="d in availableDisks" :key="d.id" :value="d.id">
              {{ d.name }} ({{ formatBytes(d.sizeBytes) }}, {{ d.format }})
            </option>
          </AppSelect>
          <div v-if="availableDisks.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
            No unattached disks available. Create one on the Disks page first.
          </div>
        </div>

        <div style="margin-top:16px">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
            <label style="margin:0">Shared Folders (optional)</label>
            <button class="btn-ghost btn-sm" @click="showFolderPicker = true">
              <span style="display:flex;align-items:center;gap:4px">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                Add
              </span>
            </button>
          </div>
          <div v-if="sharedPaths.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
            <div v-for="(p, i) in sharedPaths" :key="p" style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;font-family:var(--font-mono);border-bottom:1px solid var(--border-subtle)">
              <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ p }}</span>
              <button class="btn-ghost btn-sm" style="color:var(--red);flex-shrink:0;margin-left:8px" @click="sharedPaths.splice(i, 1)">Remove</button>
            </div>
          </div>
          <span style="font-size:11px;color:var(--text-dim);display:block">
            Host directories shared via virtio-9p. Mount inside guest: <code style="background:var(--bg);padding:1px 4px;border-radius:1px;font-size:10px">mount -t 9p -o trans=virtio hostshare /mnt/share</code>
          </span>
        </div>
      </div>

      <FolderPicker
        v-if="showFolderPicker"
        :modelValue="''"
        @update:modelValue="(p: string) => { if (!sharedPaths.includes(p)) sharedPaths.push(p) }"
        @close="showFolderPicker = false"
      />

      <!-- Step: Network -->
      <div v-if="stepContent(step) === 'Network'">
        <h3 class="step-title">Network</h3>
        <div class="form-group">
          <label>Network</label>
          <AppSelect v-model="selectedNetworkId">
            <option v-for="n in networks" :key="n.id" :value="n.id">
              {{ n.name }} ({{ n.mode }})
            </option>
          </AppSelect>
          <span style="font-size:11px;color:var(--text-dim);margin-top:4px;display:block">
            NAT provides internet access via the host. Bridged networks give the VM its own IP on the local network.
            Manage networks under <strong>Settings &rarr; Network</strong>.
          </span>
        </div>
        <div v-if="selectedNetworkId && selectedNetwork" style="margin-top:12px;font-size:12px;color:var(--text-secondary)">
          <div style="margin-bottom:4px;font-weight:500">{{ selectedNetwork.name }} &mdash; {{ selectedNetwork.mode }}</div>
        </div>

        <!-- Port Forwarding (NAT only) -->
        <div v-if="isNAT" style="margin-top:16px">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
            <label style="margin:0">Port Forwarding</label>
          </div>
          <div v-if="portForwards.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
            <div v-for="(pf, i) in portForwards" :key="i" style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;border-bottom:1px solid var(--border-subtle)">
              <span class="mono">{{ pf.protocol.toUpperCase() }} {{ pf.hostPort }} &rarr; {{ pf.guestPort }}</span>
              <button class="btn-ghost btn-sm" style="color:var(--red);flex-shrink:0;margin-left:8px" @click="removePortForward(i)">Remove</button>
            </div>
          </div>
          <div style="display:flex;gap:6px;align-items:end">
            <div style="width:70px">
              <label style="font-size:11px;color:var(--text-dim)">Proto</label>
              <AppSelect v-model="newPFProto" size="sm">
                <option value="tcp">TCP</option>
                <option value="udp">UDP</option>
              </AppSelect>
            </div>
            <div style="flex:1">
              <label style="font-size:11px;color:var(--text-dim)">Host Port</label>
              <input v-model.number="newPFHostPort" type="number" min="1" max="65535" placeholder="8080" style="font-size:12px" />
            </div>
            <div style="flex:1">
              <label style="font-size:11px;color:var(--text-dim)">Guest Port</label>
              <input v-model.number="newPFGuestPort" type="number" min="1" max="65535" placeholder="80" style="font-size:12px" />
            </div>
            <button class="btn-ghost btn-sm" :disabled="!newPFHostPort || !newPFGuestPort" @click="addPortForward" style="margin-bottom:1px">Add</button>
          </div>
          <span style="font-size:11px;color:var(--text-dim);margin-top:6px;display:block">
            Forward traffic from a host port to a port inside the VM.
          </span>
        </div>

        <!-- USB Passthrough -->
        <div style="margin-top:16px">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
            <label style="margin:0">USB Passthrough</label>
            <button class="btn-ghost btn-sm" @click="showUSBPicker = true; fetchUSBDevices()">
              <span style="display:flex;align-items:center;gap:4px">
                <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                Add
              </span>
            </button>
          </div>
          <div v-if="selectedUSBDevices.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
            <div v-for="dev in selectedUSBDevices" :key="`${dev.vendorId}:${dev.productId}`" style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;border-bottom:1px solid var(--border-subtle)">
              <span>{{ dev.label || `${dev.vendorId}:${dev.productId}` }} <span class="badge badge-gray" style="font-size:10px;margin-left:4px">{{ dev.vendorId }}:{{ dev.productId }}</span></span>
              <button class="btn-ghost btn-sm" style="color:var(--red);flex-shrink:0;margin-left:8px" @click="removeUSBDevice(dev)">Remove</button>
            </div>
          </div>
          <span v-else style="font-size:11px;color:var(--text-dim);display:block">
            No USB devices selected. Pass physical USB devices from your Mac to the VM.
          </span>
        </div>

        <!-- USB Device Picker Modal -->
        <div v-if="showUSBPicker" class="modal-overlay" @click.self="showUSBPicker = false" style="z-index:1100">
          <div class="modal" style="max-width:480px">
            <h2>Select USB Devices</h2>
            <div v-if="hostUSBDevices.length === 0" class="empty" style="padding:24px 0">
              <p>No USB devices detected on the host.</p>
            </div>
            <div v-else style="background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden">
              <table>
                <thead><tr><th></th><th>Device</th><th>IDs</th></tr></thead>
                <tbody>
                  <tr v-for="dev in hostUSBDevices" :key="`${dev.vendorId}:${dev.productId}`"
                      :style="dev.claimedByVMId ? 'opacity:0.5' : 'cursor:pointer'"
                      @click="!dev.claimedByVMId && toggleUSBDevice(dev)">
                    <td style="width:32px;text-align:center">
                      <input type="checkbox" :checked="isUSBSelected(dev)" :disabled="!!dev.claimedByVMId" @click.stop="!dev.claimedByVMId && toggleUSBDevice(dev)" />
                    </td>
                    <td>
                      <div style="font-weight:500">{{ dev.name }}</div>
                      <div v-if="dev.manufacturer" style="font-size:11px;color:var(--text-dim)">{{ dev.manufacturer }}</div>
                      <div v-if="dev.claimedByVMId" style="font-size:11px;color:var(--red)">In use by {{ dev.claimedByVMName }}</div>
                    </td>
                    <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:10px">{{ dev.vendorId }}:{{ dev.productId }}</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div class="modal-actions">
              <button class="btn-ghost" @click="showUSBPicker = false">Done</button>
            </div>
          </div>
        </div>
      </div>

      <!-- Step: Summary -->
      <div v-if="stepContent(step) === 'Summary'">
        <h3 class="step-title">Summary</h3>
        <div class="summary-grid">
          <div class="summary-row">
            <span class="summary-label">Name</span>
            <span>{{ name }}</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">OS</span>
            <span>{{ osType === 'linux' ? 'Linux' : 'Windows' }}</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Architecture</span>
            <span>ARM64</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">CPU</span>
            <span>{{ cpuCount }} cores</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Memory</span>
            <span>{{ memoryMB }} MB</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Display</span>
            <span>{{ displayResolution }}</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Firmware</span>
            <span>UEFI</span>
          </div>
          <div v-if="tpmEnabled" class="summary-row">
            <span class="summary-label">TPM</span>
            <span>TPM 2.0 (swtpm)</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Image</span>
            <span>
              <span class="badge badge-gray" style="margin-right:4px">{{ mode }}</span>
              {{ selectedImage?.name || '—' }}
            </span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Disk</span>
            <span v-if="diskSource === 'existing'">{{ availableDisks.find(d => d.id === existingDiskId)?.name || 'Selected disk' }}</span>
            <span v-else>{{ diskSizeGB }} GB (qcow2, new)</span>
          </div>
          <div v-if="sharedPaths.length" class="summary-row">
            <span class="summary-label">Shared</span>
            <span style="font-family:var(--font-mono);font-size:12px">{{ sharedPaths.join(', ') }}</span>
          </div>
          <div v-if="selectedUSBDevices.length" class="summary-row">
            <span class="summary-label">USB</span>
            <span style="font-size:12px">{{ selectedUSBDevices.map(d => d.label || `${d.vendorId}:${d.productId}`).join(', ') }}</span>
          </div>
          <div class="summary-row">
            <span class="summary-label">Network</span>
            <span>{{ selectedNetwork ? `${selectedNetwork.name} (${selectedNetwork.mode})` : 'Default NAT' }}</span>
          </div>
        </div>

        <div class="qemu-collapse" style="margin-top:16px">
          <button class="qemu-toggle" @click="showQemuCmd = !showQemuCmd">
            <svg :style="{ transform: showQemuCmd ? 'rotate(90deg)' : '' }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><polyline points="9 18 15 12 9 6"/></svg>
            QEMU Command Preview
          </button>
          <div v-if="showQemuCmd" class="qemu-cmd">
            <pre>{{ qemuCommand }}</pre>
          </div>
        </div>
      </div>

      <!-- Error -->
      <p v-if="error" style="color:var(--red);font-size:13px;margin-top:12px;background:var(--red-muted);padding:8px 12px;border-radius:var(--radius-xs)">{{ error }}</p>

      <!-- Navigation -->
      <div class="wizard-nav">
        <button class="btn-ghost" @click="step > 1 ? prev() : emit('close')">
          {{ step > 1 ? 'Back' : 'Cancel' }}
        </button>
        <div style="display:flex;gap:8px;align-items:center">
          <span style="font-size:12px;color:var(--text-dim)">Step {{ step }} of {{ totalSteps }}</span>
          <button v-if="step < totalSteps" class="btn-primary" :disabled="!canProceed()" @click="next">
            Next
          </button>
          <button v-else class="btn-primary" :disabled="loading || !canProceed()" @click="submit">
            {{ loading ? 'Creating...' : 'Create VM' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.wizard-steps {
  display: flex;
  gap: 8px;
  justify-content: center;
  margin-bottom: 20px;
}
.wizard-dot {
  width: 28px;
  height: 28px;
  border-radius: 2px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 600;
  border: 2px solid var(--border);
  color: var(--text-dim);
  transition: all 0.2s;
}
.wizard-dot.active {
  border-color: var(--accent);
  color: var(--accent);
  background: rgba(99, 102, 241, 0.1);
}
.wizard-dot.done {
  border-color: var(--green);
  background: var(--green);
  color: #fff;
  cursor: pointer;
}
.step-title {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 16px;
  color: var(--text);
}
.os-grid {
  display: flex;
  gap: 10px;
}
.os-card {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  padding: 16px 8px;
  border: 2px solid var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  transition: all 0.15s;
  position: relative;
  font-size: 13px;
  font-weight: 500;
}
.os-card:hover:not(.disabled) { border-color: var(--accent); }
.os-card.selected {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.08);
}
.os-card.disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.os-soon {
  position: absolute;
  top: 4px;
  right: 6px;
  font-size: 9px;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
.warning-box {
  background: rgba(245,158,11,0.1);
  padding: 10px 12px;
  border-radius: var(--radius-sm);
  font-size: 13px;
  color: var(--amber);
  margin-bottom: 8px;
}
.summary-grid {
  display: flex;
  flex-direction: column;
}
.summary-row {
  display: flex;
  padding: 10px 0;
  border-bottom: 1px solid var(--border-subtle);
  font-size: 13px;
}
.summary-row:last-child { border-bottom: none; }
.summary-label {
  width: 120px;
  flex-shrink: 0;
  font-weight: 600;
  color: var(--text-dim);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}
.wizard-nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid var(--border-subtle);
}
.qemu-collapse {
  border-top: 1px solid var(--border-subtle);
  padding-top: 12px;
}
.qemu-toggle {
  display: flex;
  align-items: center;
  gap: 6px;
  background: none;
  border: none;
  color: var(--text-dim);
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  cursor: pointer;
  padding: 0;
}
.qemu-toggle:hover { color: var(--text-secondary); }
.qemu-toggle svg { transition: transform 0.15s; }
.qemu-cmd {
  margin-top: 8px;
  background: var(--bg);
  border: 1px solid var(--border);
  padding: 12px;
  overflow-x: auto;
  max-height: 240px;
  overflow-y: auto;
}
.qemu-cmd pre {
  font-family: var(--font-mono);
  font-size: 11px;
  line-height: 1.6;
  color: var(--text-secondary);
  margin: 0;
  white-space: pre-wrap;
  word-break: break-all;
}

/* Driver download step */
.driver-status {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 16px;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  font-size: 13px;
}
.driver-ready {
  border-color: var(--green);
  background: rgba(34, 197, 94, 0.06);
  color: var(--green);
  font-weight: 500;
}
.progress-bar {
  width: 100%;
  height: 6px;
  background: var(--border);
  border-radius: 3px;
  overflow: hidden;
}
.progress-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 3px;
  transition: width 0.3s ease;
}
</style>
