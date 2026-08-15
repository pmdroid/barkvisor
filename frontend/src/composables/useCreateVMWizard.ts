import { ref, computed, watch, onMounted } from 'vue'
import { useVMStore } from '../stores/vms'
import { useImageStore } from '../stores/images'
import { useToastStore } from '../stores/toast'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useCapabilitiesStore } from '../stores/capabilities'
import {
  capabilitiesArchRunnable,
  defaultCapabilities,
  parseSystemCapabilities,
} from '../utils/capabilitiesParse'
import { networksUsableOnHost } from './useFeature'
import api from '../api/client'
import type {
  PortForwardRule,
  HostUSBDevice,
  USBPassthroughDevice,
  CreateVMRequest,
  CurrentHostCapabilities,
  Disk,
  Image,
  Network,
  SSHKey,
} from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { useImageProgress } from './useTicketedEventSource'
import { useTaskPoller } from './useTaskPoller'
import { useNetworkStore } from '../stores/networks'
import { useDiskStore } from '../stores/disks'
import { useDevicesStore } from '../stores/devices'
import { hostArchToImageArch } from '../utils/imageArch'
import {
  architectureIsProblem,
  architectureLabel,
  defaultMachineType,
  readAlwaysShowArchitectureDetails,
  shouldRevealArchitectureDetails,
  writeAlwaysShowArchitectureDetails,
} from '../utils/architectureDetails'
import {
  createVMIncompatibilityReasons,
  toPickOption,
  type DevicePickOption,
} from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  defaultPickedHostId,
  deviceCapabilitiesPath,
  devicePath,
  deviceTaskPath,
  isSelfDevice,
  resolveSelectedDevice,
  selectedHostIsLive,
  usesLocalDeviceInventory,
} from '../utils/homeDeviceApi'

export function useCreateVMWizard(
  emit: (e: 'created') => void,
  opts: { initialHostId?: string } = {},
) {
  const vmStore = useVMStore()
  const imageStore = useImageStore()
  const toast = useToastStore()
  const sshKeyStore = useSSHKeyStore()
  const caps = useCapabilitiesStore()
  const networkStore = useNetworkStore()
  const diskStore = useDiskStore()
  const devicesStore = useDevicesStore()

  const selectedHostId = ref(opts.initialHostId ?? '')
  const pickedCaps = ref<CurrentHostCapabilities>({ ...defaultCapabilities })
  const pickedHostArchKnown = ref(false)
  const deviceImages = ref<Image[]>([])
  const deviceNetworks = ref<Network[]>([])
  const deviceDisks = ref<Disk[]>([])
  const deviceSSHKeys = ref<SSHKey[]>([])

  const selectedDevice = computed(() =>
    resolveSelectedDevice(
      selectedHostId.value,
      (id) => devicesStore.deviceByHostId(id),
      devicesStore.selfDevice,
    ),
  )

  function pickedDeviceStillLive(): boolean {
    return selectedHostIsLive(selectedHostId.value, (id) => devicesStore.deviceByHostId(id))
  }

  const hostArch = computed(() => pickedCaps.value.hostArch)
  const guestTypes = computed(() => pickedCaps.value.guestTypes ?? [])
  const accelerator = computed(() => pickedCaps.value.accelerator)
  const hostCpuCount = computed(() => {
    const n = pickedCaps.value.hostCpuCount
    return typeof n === 'number' && n >= 1 ? n : 1
  })
  const usb = computed(() => ({
    available: pickedCaps.value.supportsUSBPassthrough,
  }))
  const bridged = computed(() => ({
    available: pickedCaps.value.supportsBridgedNetworking,
    explanation:
      pickedCaps.value.details?.find((d) => d.code === 'bridgedNetworking' && !d.supported)?.remediation
      || undefined,
  }))
  const allNetworks = computed(() => deviceNetworks.value)
  const networks = computed(() => networksUsableOnHost(allNetworks.value, bridged.value.available))
  const availableDisks = computed(() => deviceDisks.value.filter((d) => !d.vmId))

  // Wizard step
  const step = ref(1)

  // Step 1: OS & Name
  const name = ref('')
  const osType = ref<'linux' | 'windows'>('linux')
  /**
   * Windows guest profile exists only for arm64 today (`windows-arm64`).
   * Until hostArch is known, do not offer Windows (PAS-48 / PAS-37 fail-closed).
   */
  const supportsWindows = computed(() => {
    if (!pickedHostArchKnown.value) return false
    const host = hostArchToImageArch(hostArch.value)
    if (host !== 'arm64') return false
    const types = guestTypes.value ?? []
    if (types.length === 0) return true
    return types.some(
      (g) => g.id === 'windows-arm64' || (g.osFamily === 'windows' && g.arch === 'arm64'),
    )
  })

  /** Null means “use the host default” so a simple create can omit vmType (PAS-93). */
  const guestArchOverride = ref<string | null>(null)

  const hostImageArch = computed(() => hostArchToImageArch(hostArch.value))

  const effectiveGuestArch = computed(() => guestArchOverride.value ?? hostImageArch.value)

  const deviceOptions = computed<DevicePickOption[]>(() => {
    const rows = devicesStore.devices
    const list = rows.length > 0 ? rows : (devicesStore.selfDevice ? [devicesStore.selfDevice] : [])
    return list.map((row) =>
      toPickOption(
        row,
        createVMIncompatibilityReasons(row, {
          // Configured guest for this create — not each row's host arch.
          guestArch: effectiveGuestArch.value,
          osType: osType.value,
          capabilities: row.hostId === selectedDevice.value?.hostId ? pickedCaps.value : undefined,
        }),
      ),
    )
  })

  const vmType = computed(() => {
    const arch = effectiveGuestArch.value
    const archSuffix = arch === 'x86_64' ? 'amd64' : 'arm64'
    if (osType.value === 'windows') {
      // Never silently map Windows → Linux. Submit/canProceed require supportsWindows.
      return 'windows-arm64'
    }
    return `linux-${archSuffix}` as const
  })

  // If host turns out not to support Windows, drop a stale selection.
  watch(supportsWindows, (ok) => {
    if (!ok && osType.value === 'windows') {
      selectOS('linux')
    }
  })

  // Step 2: Hardware
  const cpuCount = ref(2)
  const memoryMB = ref(1024)
  const displayResolution = ref('1280x800')
  const uefi = ref(true)
  const tpmOverride = ref<boolean | null>(null)
  const tpmEnabled = computed(() => tpmOverride.value ?? osType.value === 'windows')
  const alwaysShowArchDetails = ref(readAlwaysShowArchitectureDetails())

  const archCustomized = computed(() => {
    const override = guestArchOverride.value
    return !!override && override !== hostImageArch.value
  })
  const uefiCustomized = computed(() => uefi.value !== true)
  const tpmCustomized = computed(() => tpmOverride.value !== null)
  const archRunnable = computed(() => capabilitiesArchRunnable(pickedCaps.value, effectiveGuestArch.value))
  const archIsProblem = computed(() => {
    if (!pickedHostArchKnown.value) return false
    return architectureIsProblem(effectiveGuestArch.value, archRunnable.value)
  })
  const archProblemText = computed(() => {
    if (!archIsProblem.value) return null
    const guest = effectiveGuestArch.value || 'selected'
    const host = hostImageArch.value || 'this device'
    if (osType.value === 'windows' && guest !== 'arm64') {
      return `Windows guests are not available on ${guest}. This device runs ${host}.`
    }
    return `VM architecture (${guest}) is not compatible with this device (${host}). Cross-architecture VMs are not supported.`
  })
  const revealArchOnSummary = computed(() =>
    shouldRevealArchitectureDetails({
      alwaysShow: alwaysShowArchDetails.value,
      customized: archCustomized.value || uefiCustomized.value || tpmCustomized.value,
      problem: archIsProblem.value,
    }),
  )
  const archOptions = computed(() => {
    const host = hostImageArch.value
    return [
      {
        value: 'arm64',
        label: host === 'arm64' ? 'ARM64 (this device)' : 'ARM64',
      },
      {
        value: 'x86_64',
        label: host === 'x86_64' ? 'x86_64 (this device)' : 'x86_64',
        disabled: osType.value === 'windows',
      },
    ]
  })
  const machineType = computed(() => {
    const fromCaps = (guestTypes.value ?? []).find((g) => g.id === vmType.value)?.machine
    return fromCaps || defaultMachineType(vmType.value)
  })
  const cpuModel = computed(() => {
    const accel = accelerator.value
    return accel === 'hvf' || accel === 'kvm' ? 'host' : accel ? 'max' : 'host default'
  })
  const archLabel = computed(() => architectureLabel(effectiveGuestArch.value))

  function setGuestArch(arch: string) {
    guestArchOverride.value = arch || null
  }

  function setAlwaysShowArchDetails(on: boolean) {
    alwaysShowArchDetails.value = on
    writeAlwaysShowArchitectureDetails(on)
  }

  function setTpmEnabled(on: boolean) {
    tpmOverride.value = on
  }

  function selectOS(os: 'linux' | 'windows') {
    if (os === 'windows' && !supportsWindows.value) return
    osType.value = os
    selectedImageId.value = ''
    tpmOverride.value = null
    if (os === 'windows' && guestArchOverride.value === 'x86_64') {
      guestArchOverride.value = null
    }
    const maxCpu = hostCpuCount.value
    if (os === 'windows') {
      cpuCount.value = Math.min(4, maxCpu)
      memoryMB.value = 4096
      diskSizeGB.value = 64
      uefi.value = true
      mode.value = 'iso'
    } else {
      cpuCount.value = Math.min(2, maxCpu)
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

  // Dynamic step mapping
  const needsDriverStep = computed(() => osType.value === 'windows' && !virtioWinAvailable.value)
  const totalSteps = computed(() => (needsDriverStep.value ? 7 : 6))

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

  const currentStepLabel = computed(() => stepContent(step.value))

  watch(osType, async (os) => {
    if (os === 'windows') {
      await checkVirtioWinStatus()
    }
  })

  async function checkVirtioWinStatus() {
    try {
      const target = selectedDevice.value
      if (selectedHostId.value && !target) {
        virtioWinAvailable.value = false
        return
      }
      const path = target ? devicePath(target, '/system/virtio-win/status') : '/system/virtio-win/status'
      const { data } = await api.get(path)
      virtioWinAvailable.value = data.available
      virtioWinImageId.value = data.imageId || null
    } catch {
      virtioWinAvailable.value = false
    }
  }

  const virtioProgress = useImageProgress()

  async function startVirtioWinDownload() {
    virtioWinError.value = ''
    virtioWinDownloading.value = true
    virtioWinProgress.value = 0
    virtioWinStatus.value = 'downloading'
    virtioProgress.stop()

    try {
      const target = selectedDevice.value
      if (selectedHostId.value && !target) {
        virtioWinError.value = 'The selected Device is no longer available. Pick a Device again.'
        virtioWinDownloading.value = false
        return
      }
      const path = target ? devicePath(target, '/system/virtio-win/download') : '/system/virtio-win/download'
      const { data } = await api.post(path)
      virtioWinImageId.value = data.imageId
      if (target && !isSelfDevice(target)) {
        // No SSE cross-device — poll the member image until ready.
        const { poll } = useTaskPoller()
        if (data.taskID) {
          const event = await poll(data.taskID, { path: deviceTaskPath(target, data.taskID) })
          if (event.status === 'completed') {
            virtioWinAvailable.value = true
            virtioWinDownloading.value = false
            return
          }
          virtioWinError.value = event.error || 'Download failed'
          virtioWinDownloading.value = false
          return
        }
        virtioWinAvailable.value = false
        virtioWinDownloading.value = false
        virtioWinError.value = 'Download started on the Device. Refresh this step shortly.'
        return
      }

      virtioProgress.start(data.imageId, {
        onProgress: (msg) => {
          virtioWinProgress.value = msg.percent ?? 0
          virtioWinStatus.value = msg.status ?? 'downloading'
        },
        onReady: () => {
          virtioWinAvailable.value = true
          virtioWinDownloading.value = false
          imageStore.fetchAll()
        },
        onError: (msg) => {
          virtioWinError.value = msg?.error || 'Download failed'
          virtioWinDownloading.value = false
          if (virtioWinStatus.value !== 'ready') {
            checkVirtioWinStatus()
          }
        },
      })
    } catch (e: any) {
      virtioWinError.value = apiErrorMessage(e)
      virtioWinDownloading.value = false
    }
  }

  // Step 4/5: Storage
  const diskSource = ref<'new' | 'existing'>('new')
  const diskSizeGB = ref(10)
  const existingDiskId = ref('')
  const sharedPaths = ref<string[]>([])
  const showFolderPicker = ref(false)

  // USB passthrough (shown on Network step, gated by capabilities)
  const hostUSBDevices = ref<HostUSBDevice[]>([])
  const selectedUSBDevices = ref<USBPassthroughDevice[]>([])
  const showUSBPicker = ref(false)

  async function fetchUSBDevices() {
    try {
      const target = selectedDevice.value
      if (selectedHostId.value && !target) {
        hostUSBDevices.value = []
        return
      }
      const path = target ? devicePath(target, '/system/usb-devices') : '/system/usb-devices'
      const { data } = await api.get(path)
      hostUSBDevices.value = data
    } catch {
      hostUSBDevices.value = []
    }
  }

  function usbDeviceKey(dev: { deviceId?: string | null; vendorId: string; productId: string; serialNumber?: string | null; id?: string }) {
    if ('id' in dev && dev.id) return dev.id
    return dev.deviceId
      || (dev.serialNumber ? `${dev.vendorId}:${dev.productId}:${dev.serialNumber}` : `${dev.vendorId}:${dev.productId}`)
  }

  function toggleUSBDevice(dev: HostUSBDevice) {
    if (dev.attachable === false || dev.claimedByVMId) return
    const key = usbDeviceKey(dev)
    const idx = selectedUSBDevices.value.findIndex((d) => usbDeviceKey(d) === key)
    if (idx >= 0) {
      selectedUSBDevices.value.splice(idx, 1)
    } else {
      selectedUSBDevices.value.push({
        vendorId: dev.vendorId,
        productId: dev.productId,
        label: dev.productName || dev.name,
        serialNumber: dev.serialNumber,
        deviceId: usbDeviceKey(dev),
      })
    }
  }

  function isUSBSelected(dev: HostUSBDevice): boolean {
    const key = usbDeviceKey(dev)
    return selectedUSBDevices.value.some((d) => usbDeviceKey(d) === key)
  }

  function removeUSBDevice(dev: USBPassthroughDevice) {
    const key = usbDeviceKey(dev)
    selectedUSBDevices.value = selectedUSBDevices.value.filter((d) => usbDeviceKey(d) !== key)
  }

  // Step 5/6: Network (list from shared store)
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
    // Missing selection is implicit NAT (PAS-67).
    if (!selectedNetworkId.value) return true
    const net = allNetworks.value.find((n) => n.id === selectedNetworkId.value)
    return !net || net.mode === 'nat'
  })

  watch(isNAT, (nat) => {
    if (!nat) portForwards.value = []
  })

  watch([() => bridged.value.available, allNetworks], () => {
    const current = allNetworks.value.find((n) => n.id === selectedNetworkId.value)
    if (current && current.mode === 'bridged' && !bridged.value.available) {
      const fallback =
        allNetworks.value.find((n) => n.mode === 'nat' && n.isDefault)
        ?? allNetworks.value.find((n) => n.mode === 'nat')
        ?? null
      selectedNetworkId.value = fallback?.id ?? ''
    }
  })

  // State
  const error = ref('')
  const loading = ref(false)
  /** True while loadPickedDevice is in flight (initial mount and Device switch). */
  const pickedDeviceLoading = ref(true)
  let pickedDeviceLoadSeq = 0

  async function applyLoadedResources(deviceIsSelf: boolean) {
    if (deviceIsSelf) {
      deviceImages.value = imageStore.images
      deviceNetworks.value = networkStore.networks
      deviceDisks.value = diskStore.disks
      deviceSSHKeys.value = sshKeyStore.keys
      pickedCaps.value = { ...caps.currentHost }
      pickedHostArchKnown.value = caps.hostArchKnown
    }
    const defaultKey = deviceSSHKeys.value.find((k) => k.isDefault)
    if (defaultKey) selectedSSHKeyId.value = defaultKey.id
    const defaultNet =
      deviceNetworks.value.find((n) => n.mode === 'nat' && n.isDefault)
      ?? networks.value.find((n) => n.isDefault)
      ?? null
    selectedNetworkId.value = defaultNet?.id ?? ''
  }

  function clearPickedInventory() {
    pickedCaps.value = { ...defaultCapabilities }
    pickedHostArchKnown.value = false
    deviceImages.value = []
    deviceNetworks.value = []
    deviceDisks.value = []
    deviceSSHKeys.value = []
  }

  async function loadPickedDevice() {
    const seq = ++pickedDeviceLoadSeq
    pickedDeviceLoading.value = true
    try {
      await devicesStore.fetchHealth().catch(() => {})
      if (!selectedHostId.value) {
        selectedHostId.value = defaultPickedHostId(opts.initialHostId, devicesStore.selfDevice?.hostId)
      }
      if (!pickedDeviceStillLive()) {
        clearPickedInventory()
        error.value = 'The selected Device is no longer available. Pick a Device again.'
        return
      }
      const device = selectedDevice.value
      if (!device) {
        await caps.fetchCapabilities().catch(() => {})
        await Promise.all([imageStore.fetchAll(), sshKeyStore.fetchAll(), networkStore.fetchAll(), diskStore.fetchAll()])
        await applyLoadedResources(true)
        return
      }
      if (!canCallDeviceAPI(device)) {
        clearPickedInventory()
        error.value = 'Device is unreachable. Workloads on this Device keep running locally.'
        return
      }
      if (usesLocalDeviceInventory(device)) {
        await caps.fetchCapabilities().catch(() => {})
        await Promise.all([imageStore.fetchAll(), sshKeyStore.fetchAll(), networkStore.fetchAll(), diskStore.fetchAll()])
        await applyLoadedResources(true)
        return
      }
      try {
        const [capsRes, imagesRes, netsRes, disksRes, keysRes] = await Promise.all([
          api.get(deviceCapabilitiesPath(device)),
          api.get(devicePath(device, '/images')),
          api.get(devicePath(device, '/networks')),
          api.get(devicePath(device, '/disks')),
          api.get(devicePath(device, '/ssh-keys')),
        ])
        pickedCaps.value = parseSystemCapabilities(capsRes.data)
        pickedHostArchKnown.value = typeof capsRes.data?.hostArch === 'string' && capsRes.data.hostArch.length > 0
        deviceImages.value = Array.isArray(imagesRes.data) ? imagesRes.data : []
        deviceNetworks.value = Array.isArray(netsRes.data) ? netsRes.data : []
        deviceDisks.value = Array.isArray(disksRes.data) ? disksRes.data : []
        deviceSSHKeys.value = Array.isArray(keysRes.data) ? keysRes.data : []
        selectedImageId.value = ''
        existingDiskId.value = ''
        selectedUSBDevices.value = []
        error.value = ''
        await applyLoadedResources(false)
      } catch (e: unknown) {
        clearPickedInventory()
        error.value = apiErrorMessage(e, 'Could not load inventory from the picked Device.')
      }
    } finally {
      if (seq === pickedDeviceLoadSeq) pickedDeviceLoading.value = false
    }
  }

  onMounted(async () => {
    await loadPickedDevice()
  })

  watch(selectedHostId, async (next, prev) => {
    if (!prev || !next || next === prev) return
    selectedImageId.value = ''
    existingDiskId.value = ''
    selectedUSBDevices.value = []
    await loadPickedDevice()
    if (osType.value === 'windows') await checkVirtioWinStatus()
  })

  /** Local ready images of the current mode, unfiltered by arch. */
  function readyImagesForMode(imageType: 'iso' | 'cloud-image') {
    return deviceImages.value.filter((i) => i.imageType === imageType && i.status === 'ready')
  }

  /** Match host-runnable arch; empty arch allowed (e.g. virtio drivers). */
  function localImageMatchesHost(arch: string | null | undefined): boolean {
    if (!arch) return true
    return capabilitiesArchRunnable(pickedCaps.value, arch)
  }

  const isoImages = computed(() =>
    readyImagesForMode('iso').filter((i) => localImageMatchesHost(i.arch)),
  )
  const cloudImages = computed(() =>
    readyImagesForMode('cloud-image').filter((i) => localImageMatchesHost(i.arch)),
  )
  const filteredImages = computed(() =>
    mode.value === 'iso' ? isoImages.value : cloudImages.value,
  )
  /** Ready images hidden solely because of host arch mismatch (PAS-48 empty-state copy). */
  const foreignArchImageCount = computed(() => {
    if (!pickedHostArchKnown.value) return 0
    const type = mode.value === 'iso' ? 'iso' : 'cloud-image'
    return readyImagesForMode(type).filter((i) => i.arch && !localImageMatchesHost(i.arch)).length
  })

  const selectedImage = computed(() => {
    if (!selectedImageId.value) return null
    return deviceImages.value.find((i) => i.id === selectedImageId.value) || null
  })

  const selectedNetwork = computed(() => {
    if (!selectedNetworkId.value) return null
    return allNetworks.value.find((n) => n.id === selectedNetworkId.value) || null
  })

  function canProceed(): boolean {
    if (pickedDeviceLoading.value) return false
    if (osType.value === 'windows' && !supportsWindows.value) return false
    const content = stepContent(step.value)
    switch (content) {
      case 'OS':
        return !!name.value.trim() && (!deviceOptions.value.length || deviceOptions.value.some((o) => o.hostId === selectedHostId.value && o.compatible))
      case 'Hardware':
        return cpuCount.value >= 1 && memoryMB.value >= 128 && !archIsProblem.value
      case 'Image':
        return !!selectedImageId.value
      case 'Drivers':
        return virtioWinAvailable.value
      case 'Storage':
        return diskSource.value === 'existing' ? !!existingDiskId.value : diskSizeGB.value >= 1
      case 'Network':
        return true
      case 'Summary':
        return !archIsProblem.value && pickedDeviceStillLive()
      default:
        return false
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
    if (pickedDeviceLoading.value) return
    if (osType.value === 'windows' && !supportsWindows.value) {
      error.value = 'Windows VMs are not available on this device architecture.'
      return
    }
    if (selectedNetwork.value?.mode === 'bridged' && !bridged.value.available) {
      error.value = bridged.value.explanation || 'Bridged networking is not available on this device.'
      return
    }
    if (archIsProblem.value) {
      error.value = archProblemText.value || 'This architecture is not supported on this device.'
      return
    }
    if (!pickedDeviceStillLive()) {
      error.value = 'The selected Device is no longer available. Pick a Device again.'
      return
    }
    loading.value = true
    try {
      // Simple path omits vmType / firmware so the server applies host defaults (PAS-93).
      const req: CreateVMRequest = {
        name: name.value.trim(),
        osFamily: osType.value,
        cpuCount: cpuCount.value,
        memoryMB: memoryMB.value,
      }
      if (archCustomized.value) req.vmType = vmType.value
      if (uefiCustomized.value) req.uefi = uefi.value
      if (tpmCustomized.value) req.tpmEnabled = tpmEnabled.value
      if (diskSource.value === 'existing') {
        req.existingDiskId = existingDiskId.value
      } else {
        req.diskSizeGB = diskSizeGB.value
      }
      if (mode.value === 'iso') {
        req.isoId = selectedImageId.value
      } else {
        req.cloudImageId = selectedImageId.value
        const selectedKey = deviceSSHKeys.value.find((k) => k.id === selectedSSHKeyId.value)
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
      if (usb.value.available && selectedUSBDevices.value.length > 0) {
        req.usbDevices = selectedUSBDevices.value
      }

      const target = selectedDevice.value
      const result = await vmStore.create(req, target ?? undefined)
      if (result.taskID && target && !isSelfDevice(target)) {
        toast.info(`VM "${name.value.trim()}" is provisioning on the picked Device...`)
        const { poll } = useTaskPoller()
        const event = await poll(result.taskID, { path: deviceTaskPath(target, result.taskID) })
        if (event.status !== 'completed') {
          error.value = event.error || 'Provisioning failed'
          return
        }
      } else if (result.taskID) {
        toast.info(`VM "${name.value.trim()}" is provisioning...`)
      }
      emit('created')
    } catch (e: any) {
      error.value = apiErrorMessage(e)
    } finally {
      loading.value = false
    }
  }

  function formatBytes(b: number) {
    if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB'
    if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB'
    return b + ' B'
  }

  return {
    // stores exposed for steps that need lists
    sshKeyStore: { keys: deviceSSHKeys },
    sshKeys: deviceSSHKeys,
    selectedHostId,
    deviceOptions,
    selectedDevice,
    hostArch,
    archLabel,
    revealArchOnSummary,
    archProblemText,

    // navigation
    step,
    totalSteps,
    stepLabels,
    stepContent,
    currentStepLabel,
    canProceed,
    next,
    prev,

    // OS
    name,
    osType,
    vmType,
    supportsWindows,
    selectOS,

    // Hardware
    cpuCount,
    memoryMB,
    displayResolution,
    uefi,
    tpmEnabled,
    effectiveGuestArch,
    archOptions,
    machineType,
    accelerator,
    cpuModel,
    alwaysShowArchDetails,
    setGuestArch,
    setAlwaysShowArchDetails,
    setTpmEnabled,

    // Image
    mode,
    selectedImageId,
    selectedSSHKeyId,
    showCloudInit,
    cloudUserData,
    filteredImages,
    foreignArchImageCount,
    hostImageArch,
    selectedImage,
    formatBytes,

    // Drivers
    virtioWinAvailable,
    virtioWinDownloading,
    virtioWinProgress,
    virtioWinStatus,
    virtioWinError,
    startVirtioWinDownload,

    // Storage
    diskSource,
    diskSizeGB,
    existingDiskId,
    availableDisks,
    sharedPaths,
    showFolderPicker,

    // USB
    hostUSBDevices,
    selectedUSBDevices,
    showUSBPicker,
    fetchUSBDevices,
    toggleUSBDevice,
    isUSBSelected,
    removeUSBDevice,

    // Network
    networks,
    selectedNetworkId,
    selectedNetwork,
    portForwards,
    newPFProto,
    newPFHostPort,
    newPFGuestPort,
    addPortForward,
    removePortForward,
    isNAT,

    // submit
    error,
    loading,
    submit,
  }
}
