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
  HomePlacementScoreResponse,
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
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
import { hostArchToImageArch, normalizeImageArch } from '../utils/imageArch'
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
import {
  applyRecommendedHostId,
  isRecommendedHost,
  placementReasonsForHost,
  scorePlacement,
} from '../utils/placement'

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
  const homeLibrary = useHomeLibraryStore()

  const selectedHostId = ref(opts.initialHostId ?? '')
  const userOverrodeHost = ref(!!opts.initialHostId)
  const placementScore = ref<HomePlacementScoreResponse | null>(null)
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

  // Step 1: Basics (name + OS). Zero arch / capability language.
  const name = ref('')
  const osType = ref<'linux' | 'windows'>('linux')
  /**
   * Windows guest profile exists only for arm64 today (`windows-arm64`).
   * Used as a Place-step / submit reason — never to grey the step-1 card (PAS-182).
   */
  const supportsWindows = computed(() => {
    if (!pickedHostArchKnown.value) return true
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
  const selectedImageId = ref('')

  /** Picked Device native arch — used for firmware/omit-vmType and “this pick cannot run…”. */
  const hostImageArch = computed(() => hostArchToImageArch(hostArch.value))

  const selectedImage = computed(() => {
    if (!selectedImageId.value) return null
    return homeLibrary.images.find((i) => i.libraryKey === selectedImageId.value)
      || homeLibrary.images.find((i) => i.id === selectedImageId.value)
      || deviceImages.value.find((i) => i.id === selectedImageId.value)
      || null
  })

  const selectedLibraryKey = computed(() => {
    if (!selectedImage.value) return selectedImageId.value
    return 'libraryKey' in selectedImage.value && selectedImage.value.libraryKey
      ? selectedImage.value.libraryKey
      : homeImageKey(selectedImage.value)
  })

  /**
   * Guest arch comes from the chosen image (or an explicit override).
   * Never default a guest from a Device row — that lectures before intent (PAS-182).
   */
  const effectiveGuestArch = computed(() => {
    if (guestArchOverride.value) return guestArchOverride.value
    const fromImage = normalizeImageArch(selectedImage.value?.arch) ?? selectedImage.value?.arch
    return fromImage || ''
  })

  const deviceOptions = computed<DevicePickOption[]>(() => {
    const rows = devicesStore.devices
    const list = rows.length > 0 ? rows : (devicesStore.selfDevice ? [devicesStore.selfDevice] : [])
    const guest = effectiveGuestArch.value || null
    return list.map((row) => {
      const local = createVMIncompatibilityReasons(row, {
        guestArch: guest,
        osType: osType.value,
        capabilities: row.hostId === selectedDevice.value?.hostId ? pickedCaps.value : undefined,
        hasImage: selectedLibraryKey.value
          ? homeLibrary.deviceHasLibraryImage(selectedLibraryKey.value, row)
          : undefined,
      })
      const scored = placementScore.value?.candidates.find((candidate) => candidate.hostId === row.hostId)
      const hard = (scored?.reasons ?? [])
        .filter((reason) => reason.kind === 'hard')
        .map((reason) => reason.message)
      const reasons = [...new Set([...local, ...hard])]
      return toPickOption(row, reasons, {
        recommended: isRecommendedHost(placementScore.value, row.hostId),
        recommendReasons: placementReasonsForHost(placementScore.value, row.hostId),
      })
    })
  })

  const vmType = computed(() => {
    const arch = effectiveGuestArch.value
    const archSuffix = arch === 'x86_64' ? 'amd64' : 'arm64'
    if (osType.value === 'windows') {
      // Never silently map Windows → Linux. windows-amd64 is PAS-184.
      return 'windows-arm64'
    }
    return `linux-${archSuffix}` as const
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
    const guest = effectiveGuestArch.value
    if (!guest) return false
    if (guestArchOverride.value) return guestArchOverride.value !== hostImageArch.value
    return !!hostImageArch.value && guest !== hostImageArch.value
  })
  const uefiCustomized = computed(() => uefi.value !== true)
  const tpmCustomized = computed(() => tpmOverride.value !== null)
  const archRunnable = computed(() => capabilitiesArchRunnable(pickedCaps.value, effectiveGuestArch.value))
  const imageArchKnown = computed(() => !!effectiveGuestArch.value)
  const archIsProblem = computed(() => {
    if (!pickedHostArchKnown.value || !imageArchKnown.value) return false
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
    osType.value = os
    selectedImageId.value = ''
    tpmOverride.value = null
    if (os === 'windows' && guestArchOverride.value === 'x86_64') {
      guestArchOverride.value = null
    }
    const maxCpu = pickedHostArchKnown.value ? hostCpuCount.value : (os === 'windows' ? 4 : 2)
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

  watch(hostCpuCount, (max) => {
    if (pickedHostArchKnown.value && cpuCount.value > max) cpuCount.value = max
  })

  // Step 2: Image (Home Library)
  const mode = ref<'iso' | 'cloud'>('iso')
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

  // Dynamic step mapping (PAS-182): Basics → Image → Place → Hardware → Drivers? → Storage → Network → Summary
  const needsDriverStep = computed(() => osType.value === 'windows' && !virtioWinAvailable.value)
  const totalSteps = computed(() => (needsDriverStep.value ? 8 : 7))

  const stepLabels = computed(() => {
    const base = ['Basics', 'Image', 'Place', 'Hardware']
    if (needsDriverStep.value) base.push('Drivers')
    base.push('Storage', 'Network', 'Summary')
    return base
  })

  function stepContent(s: number): string {
    return stepLabels.value[s - 1] || ''
  }

  const currentStepLabel = computed(() => stepContent(step.value))

  async function enterPlace() {
    await loadPickedDevice()
  }

  watch(osType, async (os) => {
    if (os === 'windows') {
      await checkVirtioWinStatus()
    }
  })

  let virtioCheckSeq = 0

  async function checkVirtioWinStatus() {
    const seq = ++virtioCheckSeq
    try {
      const target = selectedDevice.value
      if (selectedHostId.value && !target) {
        if (seq === virtioCheckSeq) virtioWinAvailable.value = false
        return
      }
      const path = target ? devicePath(target, '/system/virtio-win/status') : '/system/virtio-win/status'
      const { data } = await api.get(path)
      if (seq !== virtioCheckSeq) return
      virtioWinAvailable.value = data.available
      virtioWinImageId.value = data.imageId || null
    } catch {
      if (seq === virtioCheckSeq) virtioWinAvailable.value = false
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
  /** True while loadPickedDevice is in flight (Place step and Device switch). */
  const pickedDeviceLoading = ref(false)
  let pickedDeviceLoadSeq = 0

  function isCurrentPickedDeviceLoad(seq: number): boolean {
    return seq === pickedDeviceLoadSeq
  }

  async function applyLoadedResources(deviceIsSelf: boolean, seq: number) {
    if (!isCurrentPickedDeviceLoad(seq)) return
    if (deviceIsSelf) {
      deviceImages.value = imageStore.images
      deviceNetworks.value = networkStore.networks
      deviceDisks.value = diskStore.disks
      deviceSSHKeys.value = sshKeyStore.keys
      pickedCaps.value = { ...caps.currentHost }
      pickedHostArchKnown.value = caps.hostArchKnown
    }
    const keys = deviceSSHKeys.value
    if (!keys.some((k) => k.id === selectedSSHKeyId.value)) {
      const defaultKey = keys.find((k) => k.isDefault)
      selectedSSHKeyId.value = defaultKey?.id ?? ''
    }
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

  let placementScoreSeq = 0
  const placementRefreshing = ref(false)
  /** True while refreshPlacement assigns selectedHostId — not a user pick. */
  let applyingRecommendedHost = false

  function assignRecommendedHostId(hostId: string) {
    if (hostId === selectedHostId.value) return
    // Empty → first recommendation is not a user override; the watcher bails on !prev.
    if (selectedHostId.value) applyingRecommendedHost = true
    selectedHostId.value = hostId
  }

  async function refreshPlacement(applyRecommendation = true) {
    const seq = ++placementScoreSeq
    placementRefreshing.value = true
    try {
      const guest = effectiveGuestArch.value
      const data = await scorePlacement({
        declaredArchitectures: guest ? [guest] : [],
        minMemoryMB: memoryMB.value,
        requestedMemoryMB: memoryMB.value,
      })
      if (seq !== placementScoreSeq) return
      placementScore.value = data
    } catch {
      if (seq !== placementScoreSeq) return
      placementScore.value = null
    } finally {
      if (seq === placementScoreSeq) placementRefreshing.value = false
    }
    if (seq !== placementScoreSeq) return
    if (!applyRecommendation || userOverrodeHost.value) return
    const guest = effectiveGuestArch.value
    assignRecommendedHostId(applyRecommendedHostId({
      recommendedHostId: placementScore.value?.recommendedHostId,
      initialHostId: opts.initialHostId,
      selfHostId: devicesStore.selfDevice?.hostId,
      currentHostId: selectedHostId.value,
      hostAllowed: (hostId) => {
        const row = devicesStore.deviceByHostId(hostId)
        if (!row) return false
        return createVMIncompatibilityReasons(row, {
          guestArch: guest,
          osType: osType.value,
          hasImage: selectedLibraryKey.value
            ? homeLibrary.deviceHasLibraryImage(selectedLibraryKey.value, row)
            : undefined,
        }).length === 0
      },
    }))
  }

  watch([memoryMB, effectiveGuestArch, osType], () => {
    void refreshPlacement(false)
  })

  async function refreshHomeLibrary() {
    await devicesStore.fetchHealth().catch(() => {})
    await homeLibrary.fetchImages(devicesStore.devices).catch(() => {})
  }

  async function loadPickedDevice() {
    const seq = ++pickedDeviceLoadSeq
    pickedDeviceLoading.value = true
    try {
      await devicesStore.fetchHealth().catch(() => {})
      if (!isCurrentPickedDeviceLoad(seq)) return
      // Don't await: a slow peer Library must not block Place inventory or host switch.
      void homeLibrary.fetchImages(devicesStore.devices).catch(() => {})
      await refreshPlacement()
      if (!isCurrentPickedDeviceLoad(seq)) return
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
        if (!isCurrentPickedDeviceLoad(seq)) return
        await Promise.all([imageStore.fetchAll(), sshKeyStore.fetchAll(), networkStore.fetchAll(), diskStore.fetchAll()])
        if (!isCurrentPickedDeviceLoad(seq)) return
        await applyLoadedResources(true, seq)
        return
      }
      if (!canCallDeviceAPI(device)) {
        clearPickedInventory()
        error.value = 'Device is unreachable. Workloads on this Device keep running locally.'
        return
      }
      if (usesLocalDeviceInventory(device)) {
        await caps.fetchCapabilities().catch(() => {})
        if (!isCurrentPickedDeviceLoad(seq)) return
        await Promise.all([imageStore.fetchAll(), sshKeyStore.fetchAll(), networkStore.fetchAll(), diskStore.fetchAll()])
        if (!isCurrentPickedDeviceLoad(seq)) return
        await applyLoadedResources(true, seq)
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
        if (!isCurrentPickedDeviceLoad(seq)) return
        pickedCaps.value = parseSystemCapabilities(capsRes.data)
        pickedHostArchKnown.value = typeof capsRes.data?.hostArch === 'string' && capsRes.data.hostArch.length > 0
        deviceImages.value = Array.isArray(imagesRes.data) ? imagesRes.data : []
        deviceNetworks.value = Array.isArray(netsRes.data) ? netsRes.data : []
        deviceDisks.value = Array.isArray(disksRes.data) ? disksRes.data : []
        deviceSSHKeys.value = Array.isArray(keysRes.data) ? keysRes.data : []
        existingDiskId.value = ''
        selectedUSBDevices.value = []
        error.value = ''
        await applyLoadedResources(false, seq)
      } catch (e: unknown) {
        if (!isCurrentPickedDeviceLoad(seq)) return
        clearPickedInventory()
        error.value = apiErrorMessage(e, 'Could not load inventory from the picked Device.')
      }
    } finally {
      if (isCurrentPickedDeviceLoad(seq) && osType.value === 'windows') {
        await checkVirtioWinStatus()
      }
      if (isCurrentPickedDeviceLoad(seq)) pickedDeviceLoading.value = false
    }
  }

  onMounted(async () => {
    await refreshHomeLibrary()
    await sshKeyStore.fetchAll().catch(() => {})
  })

  watch(currentStepLabel, (label) => {
    if (label === 'Image') void refreshHomeLibrary()
  })

  watch(selectedHostId, async (next, prev) => {
    const programmatic = applyingRecommendedHost
    applyingRecommendedHost = false
    if (!prev || !next || next === prev) return
    if (!programmatic) userOverrodeHost.value = true
    existingDiskId.value = ''
    selectedUSBDevices.value = []
    // loadPickedDevice already continues with the new host after refreshPlacement.
    if (programmatic) return
    await loadPickedDevice()
  })

  const filteredImages = computed(() => {
    const type = mode.value === 'iso' ? 'iso' : 'cloud-image'
    return homeLibrary.images.filter((i) => i.imageType === type && i.status === 'ready')
  })
  const foreignArchImageCount = computed(() => 0)

  const selectedNetwork = computed(() => {
    if (!selectedNetworkId.value) return null
    return allNetworks.value.find((n) => n.id === selectedNetworkId.value) || null
  })

  function selectedDeviceSelectable(): boolean {
    if (!deviceOptions.value.length) return true
    return deviceOptions.value.some((o) => o.hostId === selectedHostId.value && o.reachable)
  }

  function selectedDeviceIncompatibility(): string | null {
    const option = deviceOptions.value.find((o) => o.hostId === selectedHostId.value)
    if (option && !option.compatible) {
      return option.reasons[0] || 'This Device is not recommended for this VM.'
    }
    return null
  }

  const placementStepReached = computed(() => {
    const label = currentStepLabel.value
    return label === 'Place' || label === 'Hardware' || label === 'Drivers'
      || label === 'Storage' || label === 'Network' || label === 'Summary'
  })

  function canProceed(): boolean {
    const content = stepContent(step.value)
    if (placementStepReached.value && (pickedDeviceLoading.value || placementRefreshing.value)) {
      return false
    }
    switch (content) {
      case 'Basics':
        return !!name.value.trim()
      case 'Image':
        return !!selectedImageId.value
      case 'Place':
        return selectedDeviceSelectable()
      case 'Hardware':
        return cpuCount.value >= 1 && memoryMB.value >= 128 && selectedDeviceSelectable()
      case 'Drivers':
        return virtioWinAvailable.value
      case 'Storage':
        return diskSource.value === 'existing' ? !!existingDiskId.value : diskSizeGB.value >= 1
      case 'Network':
        return true
      case 'Summary':
        return pickedDeviceStillLive() && selectedDeviceSelectable()
      default:
        return false
    }
  }

  function next() {
    if (!canProceed() || step.value >= totalSteps.value) return
    step.value++
    if (stepContent(step.value) === 'Place') void enterPlace()
  }

  function prev() {
    if (step.value > 1) step.value--
  }

  async function submit() {
    error.value = ''
    if (pickedDeviceLoading.value) return
    await refreshPlacement(false)
    if (!selectedDeviceSelectable()) {
      error.value = 'Pick a reachable Device to place this VM.'
      return
    }
    if (osType.value === 'windows' && !supportsWindows.value) {
      error.value = 'Windows VMs are not available on this device architecture.'
      return
    }
    if (selectedNetwork.value?.mode === 'bridged' && !bridged.value.available) {
      error.value = bridged.value.explanation || 'Bridged networking is not available on this device.'
      return
    }
    if (!pickedDeviceStillLive()) {
      error.value = 'The selected Device is no longer available. Pick a Device again.'
      return
    }
    const createImage = homeLibrary.resolveImageForCreate(
      selectedLibraryKey.value,
      selectedDevice.value,
      selectedImage.value,
    )
    if ((selectedLibraryKey.value || selectedImageId.value) && !createImage) {
      error.value = "Not in this Device's Library"
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
      const imageId = createImage?.id
      if (mode.value === 'iso') {
        if (imageId) req.isoId = imageId
      } else {
        if (imageId) req.cloudImageId = imageId
        const selectedKey = (deviceSSHKeys.value.length ? deviceSSHKeys.value : sshKeyStore.keys)
          .find((k) => k.id === selectedSSHKeyId.value)
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
    sshKeys: computed(() => (deviceSSHKeys.value.length > 0 ? deviceSSHKeys.value : sshKeyStore.keys)),
    selectedHostId,
    hostCpuCount,
    placementStepReached,
    placementScore,
    deviceOptions,
    selectedDevice,
    selectedDeviceIncompatibility,
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
    pickedDeviceLoading,
    submit,
    loadPickedDevice,
  }
}
