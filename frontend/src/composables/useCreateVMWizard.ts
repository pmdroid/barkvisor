import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
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
  CurrentHostCapabilities,
  Disk,
  Image,
  Network,
} from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { useTaskPoller } from './useTaskPoller'
import { useNetworkStore } from '../stores/networks'
import { useDiskStore } from '../stores/disks'
import { useDevicesStore } from '../stores/devices'
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
import { hostArchToImageArch, normalizeImageArch } from '../utils/imageArch'
import { guestProfile, resolveGuestType } from '../utils/guestType'
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
  guestTypesSupportWindows,
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
  isRecommendedHost,
  placementReasonsForHost,
} from '../utils/placement'
import { authorizedKeyForCloudInit } from '../utils/homeSSHKey'
import { usePlacement } from './usePlacement'
import { useVirtioDownload } from './useVirtioDownload'
import { useUSBPicker } from './useUSBPicker'
import { useCreateVMPayload } from './useCreateVMPayload'

export { cancelLivePlacementScores } from './usePlacement'

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
  const pickedCaps = ref<CurrentHostCapabilities>({ ...defaultCapabilities })
  const pickedHostArchKnown = ref(false)
  const deviceImages = ref<Image[]>([])
  const deviceNetworks = ref<Network[]>([])
  const deviceDisks = ref<Disk[]>([])

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
   * Windows is offered when the picked Device advertises a Windows guest profile.
   * Unknown inventory: do not grey the Basics card (PAS-182).
   */
  const supportsWindows = computed(() => {
    const types = guestTypes.value ?? []
    if (types.length === 0) return true
    return guestTypesSupportWindows(types)
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

  const selectedLibraryKey = computed((): string => {
    const img = selectedImage.value
    if (!img) return selectedImageId.value
    const key = 'libraryKey' in img ? img.libraryKey : undefined
    return typeof key === 'string' && key ? key : homeImageKey(img)
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

  const cpuCount = ref(2)
  const memoryMB = ref(1024)

  const placement = usePlacement({
    selectedHostId,
    userOverrodeHost,
    initialHostId: opts.initialHostId,
    effectiveGuestArch,
    memoryMB,
    osType,
    selectedLibraryKey,
  })
  const {
    placementScore,
    placementRefreshing,
    assignRecommendedHostId,
    consumeProgrammaticHostAssign,
    refreshPlacement,
  } = placement

  const virtio = useVirtioDownload({
    selectedHostId,
    selectedDevice,
    osType,
  })
  const {
    virtioWinAvailable,
    virtioWinDownloading,
    virtioWinProgress,
    virtioWinStatus,
    virtioWinError,
    checkVirtioWinStatus,
    startVirtioWinDownload,
  } = virtio

  const usbPicker = useUSBPicker({
    selectedHostId,
    selectedDevice,
  })
  const {
    hostUSBDevices,
    selectedUSBDevices,
    showUSBPicker,
    fetchUSBDevices,
    toggleUSBDevice,
    isUSBSelected,
    removeUSBDevice,
    clearUSBSelection,
  } = usbPicker

  const { buildCreateVMPayload } = useCreateVMPayload()

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

  const vmType = computed(() =>
    resolveGuestType({
      osFamily: osType.value,
      arch: effectiveGuestArch.value || hostImageArch.value,
      // Unknown image arch tokens must not throw during render; submit still
      // fail-closes via archIsProblem / place-anyway (PAS-241).
      defaultArch: hostImageArch.value,
    }),
  )

  // Step 2: Hardware
  const displayResolution = ref('1280x800')
  const uefi = ref(true)
  const tpmOverride = ref<boolean | null>(null)
  const tpmEnabled = computed(() =>
    tpmOverride.value ?? (guestProfile(vmType.value)?.defaultTPMEnabled ?? false),
  )
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

  // Step 4/5: Storage
  const diskSource = ref<'new' | 'existing'>('new')
  const diskSizeGB = ref(10)
  const existingDiskId = ref('')
  const sharedPaths = ref<string[]>([])
  const showFolderPicker = ref(false)

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

  function applyHomeSSHKeySelection() {
    const keys = sshKeyStore.keys
    if (!keys.some((k) => k.id === selectedSSHKeyId.value)) {
      selectedSSHKeyId.value = keys.find((k) => k.isDefault)?.id ?? ''
    }
  }

  async function applyLoadedResources(deviceIsSelf: boolean, seq: number) {
    if (!isCurrentPickedDeviceLoad(seq)) return
    if (deviceIsSelf) {
      deviceImages.value = imageStore.images
      deviceNetworks.value = networkStore.networks
      deviceDisks.value = diskStore.disks
      pickedCaps.value = { ...caps.currentHost }
      pickedHostArchKnown.value = caps.hostArchKnown
    }
    applyHomeSSHKeySelection()
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
  }

  async function refreshHomeLibrary() {
    await devicesStore.fetchHealth().catch(() => {})
    await homeLibrary.fetchImages(devicesStore.devices).catch(() => {})
  }

  async function loadPickedDevice() {
    const seq = ++pickedDeviceLoadSeq
    pickedDeviceLoading.value = true
    try {
      // Placement reads deviceHasLibraryImage — wait so auto-pick is not stale.
      await refreshHomeLibrary()
      if (!isCurrentPickedDeviceLoad(seq)) return
      await sshKeyStore.fetchAll().catch(() => {})
      if (!isCurrentPickedDeviceLoad(seq)) return
      applyHomeSSHKeySelection()
      await refreshPlacement()
      if (!isCurrentPickedDeviceLoad(seq)) return
      if (!selectedHostId.value) {
        assignRecommendedHostId(defaultPickedHostId(opts.initialHostId, devicesStore.selfDevice?.hostId))
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
        const [capsRes, imagesRes, netsRes, disksRes] = await Promise.all([
          api.get(deviceCapabilitiesPath(device)),
          api.get(devicePath(device, '/images')),
          api.get(devicePath(device, '/networks')),
          api.get(devicePath(device, '/disks')),
        ])
        if (!isCurrentPickedDeviceLoad(seq)) return
        pickedCaps.value = parseSystemCapabilities(capsRes.data)
        pickedHostArchKnown.value = typeof capsRes.data?.hostArch === 'string' && capsRes.data.hostArch.length > 0
        deviceImages.value = Array.isArray(imagesRes.data) ? imagesRes.data : []
        deviceNetworks.value = Array.isArray(netsRes.data) ? netsRes.data : []
        deviceDisks.value = Array.isArray(disksRes.data) ? disksRes.data : []
        existingDiskId.value = ''
        clearUSBSelection()
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
    applyHomeSSHKeySelection()
  })

  onUnmounted(() => {
    placement.cancelPlacementScore()
  })

  watch(currentStepLabel, (label) => {
    if (label === 'Image') void refreshHomeLibrary()
  })

  watch(selectedHostId, async (next, prev) => {
    const programmatic = consumeProgrammaticHostAssign()
    if (!next || next === prev) return
    if (!programmatic) userOverrodeHost.value = true
    existingDiskId.value = ''
    clearUSBSelection()
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

  /** Missing Library bytes block Place; arch/capacity still allow place-anyway. */
  function selectedDeviceBlocksPlacement(): boolean {
    const option = deviceOptions.value.find((o) => o.hostId === selectedHostId.value)
    if (!option || option.compatible) return false
    return !option.placeAnyway
  }

  function selectedDevicePlaceable(): boolean {
    return selectedDeviceSelectable() && !selectedDeviceBlocksPlacement()
  }

  const placementStepReached = computed(() => {
    const label = currentStepLabel.value
    return label === 'Place' || label === 'Hardware' || label === 'Drivers'
      || label === 'Storage' || label === 'Network' || label === 'Summary'
  })

  function canProceed(): boolean {
    const content = stepContent(step.value)
    if (placementStepReached.value && (
      pickedDeviceLoading.value
      || placementRefreshing.value
      || homeLibrary.imagesLoading
    )) {
      return false
    }
    switch (content) {
      case 'Basics':
        return !!name.value.trim()
      case 'Image':
        return !!selectedImageId.value
      case 'Place':
        return selectedDevicePlaceable()
      case 'Hardware':
        return cpuCount.value >= 1 && memoryMB.value >= 128 && selectedDevicePlaceable()
      case 'Drivers':
        return virtioWinAvailable.value
      case 'Storage':
        return diskSource.value === 'existing' ? !!existingDiskId.value : diskSizeGB.value >= 1
      case 'Network':
        return true
      case 'Summary':
        return pickedDeviceStillLive() && selectedDevicePlaceable()
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
    if (archIsProblem.value) {
      error.value = archProblemText.value
        || 'VM architecture is not compatible with this device.'
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
      const selectedKey = sshKeyStore.keys.find((k) => k.id === selectedSSHKeyId.value)
      const req = buildCreateVMPayload({
        name: name.value,
        osFamily: osType.value,
        cpuCount: cpuCount.value,
        memoryMB: memoryMB.value,
        archCustomized: archCustomized.value,
        vmType: vmType.value,
        uefiCustomized: uefiCustomized.value,
        uefi: uefi.value,
        tpmCustomized: tpmCustomized.value,
        tpmEnabled: tpmEnabled.value,
        diskSource: diskSource.value,
        existingDiskId: existingDiskId.value,
        diskSizeGB: diskSizeGB.value,
        mode: mode.value,
        imageId: createImage?.id,
        sshAuthorizedKeys: selectedKey ? [authorizedKeyForCloudInit(selectedKey)] : [],
        userData: cloudUserData.value,
        displayResolution: displayResolution.value,
        selectedNetworkId: selectedNetworkId.value,
        portForwards: portForwards.value,
        sharedPaths: sharedPaths.value,
        usbAvailable: usb.value.available,
        usbDevices: selectedUSBDevices.value,
      })

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
    sshKeyStore,
    sshKeys: computed(() => sshKeyStore.keys),
    selectedHostId,
    hostCpuCount,
    placementStepReached,
    placementScore,
    deviceOptions,
    selectedDevice,
    selectedDeviceIncompatibility,
    selectedDeviceBlocksPlacement,
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
