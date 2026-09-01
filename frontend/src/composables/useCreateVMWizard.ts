import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useVMStore } from '../stores/vms'
import { useImageStore } from '../stores/images'
import { useToastStore } from '../stores/toast'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useCapabilitiesStore } from '../stores/capabilities'
import {
  defaultCapabilities,
  parseSystemCapabilities,
} from '../utils/capabilitiesParse'
import { networksUsableOnHost } from './useFeature'
import api from '../api/client'
import type {
  PortForwardRule,
  CurrentHostCapabilities,
  DeployTemplateRequest,
  Disk,
  HostBlockDevice,
  Image,
  Network,
  SSHKey,
} from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { useNetworkStore } from '../stores/networks'
import { useDiskStore } from '../stores/disks'
import { useDevicesStore } from '../stores/devices'
import { homeImageKey, useHomeLibraryStore, type HomeTemplate } from '../stores/homeLibrary'
import { hostArchToImageArch, imageArchSupportedOnHost, normalizeImageArch } from '../utils/imageArch'
import { guestProfile, resolveGuestType } from '../utils/guestType'
import {
  createVMIncompatibilityReasons,
  DEVICE_IMAGE_UNFETCHABLE_REASON,
  guestTypesSupportWindows,
  templateIncompatibilityReasons,
  toPickOption,
  type DevicePickOption,
} from '../utils/deviceCompatibility'
import {
  availableSizePresets,
  SIZE_PRESETS,
  vmCpuCap,
  vmMemoryCapMB,
  type SizePreset,
} from '../utils/hostBuffer'
import { defaultVMNameFromLabel } from '../utils/hostnameFromVMName'
import { useTemplateStore } from '../stores/templates'
import { useCreateProgressStore } from '../stores/createProgress'
import {
  collectTemplateDeployInputs,
  natWebUILinks,
  templateDeclaresSshKeys,
  templateInputsComplete,
  visibleTemplateInputs,
  buildDeployRecipe,
  catalogImageForArch,
} from '../utils/templateDeploy'
import {
  deviceBlockDevicesPath,
  deviceDisksPath,
} from '../utils/homeDeviceApi'
import {
  canCallDeviceAPI,
  defaultPickedHostId,
  deviceCapabilitiesPath,
  devicePath,
  isSelfDevice,
  resolveSelectedDevice,
  selectedHostIsLive,
  usesLocalDeviceInventory,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import {
  isRecommendedHost,
  placementReasonsForHost,
} from '../utils/placement'
import { authorizedKeyForCloudInit } from '../utils/homeSSHKey'
import { usePlacement } from './usePlacement'
import { useCreateVMPayload } from './useCreateVMPayload'
import { nudgeBuiltInCatalogSync } from '../utils/catalogSyncOnOpen'
import { useRepositoryStore } from '../stores/repositories'
import { useVirtioDownload } from './useVirtioDownload'
import { useCreateVMImagePin } from './useCreateVMImagePin'
import {
  HOME_OLLAMA_GRANT_URL,
  isCodingAgentImage,
  mergeCodingAgentUserData,
  type OpenAIPreset,
} from '../utils/codingAgentImage'

export type GalleryKind = 'template' | 'windows' | 'custom' | 'coding-agent' | null

export const WIZARD_STEP_LABELS = ['Gallery', 'Configure', 'Disk'] as const

export { cancelLivePlacementScores } from './usePlacement'

function isLinuxDeviceOs(os: string | null | undefined): boolean {
  return (os ?? '').toLowerCase().includes('linux')
}

async function acquireImageOnDevice(device: DeviceApiTarget, img: Image): Promise<Image> {
  const { data } = await api.post(devicePath(device, '/images/acquire'), {
    sourceUrl: img.sourceUrl || undefined,
    sha256: img.sha256 || undefined,
    name: img.name,
    imageType: img.imageType,
    arch: img.arch,
  })
  const started = data as Image
  if (started.status === 'ready') return started
  const id = started.id
  for (let i = 0; i < 180; i++) {
    await new Promise((resolve) => setTimeout(resolve, 1000))
    const { data: row } = await api.get(devicePath(device, `/images/${id}`))
    const image = row as Image
    if (image.status === 'ready') return image
    if (image.status === 'error') {
      throw new Error(image.error || 'Image copy failed')
    }
  }
  throw new Error('Timed out copying the image to this Device')
}

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
  const createProgress = useCreateProgressStore()

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
  const hostMemoryMB = computed(() => {
    const n = pickedCaps.value.maxMemoryMB
    return typeof n === 'number' && n >= 128 ? n : null
  })
  const vmCpuCapValue = computed(() => vmCpuCap(hostCpuCount.value))
  const vmMemCapMB = computed(() => vmMemoryCapMB(hostMemoryMB.value))
  const vmMemCapGB = computed(() => {
    const cap = vmMemCapMB.value
    return cap != null ? Math.max(1, Math.floor(cap / 1024)) : 8
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
  const workloadClass = ref<'house' | 'agent'>('house')
  const isAgent = computed(() => workloadClass.value === 'agent')
  const allNetworks = computed(() => deviceNetworks.value)
  const networks = computed(() => {
    const usable = networksUsableOnHost(allNetworks.value, bridged.value.available)
    if (!isAgent.value) return usable
    return usable.filter((n) => n.mode !== 'bridged')
  })
  const availableDisks = computed(() => deviceDisks.value.filter((d) => !d.vmId))

  const templateStore = useTemplateStore()
  const galleryKind = ref<GalleryKind>(null)
  const selectedTemplateSlug = ref('')
  const dedicated = ref(true)
  const selectedPresetId = ref('medium')
  const blockDevices = ref<HostBlockDevice[]>([])
  const blockDevicePath = ref('')

  const step = ref(1)
  const totalSteps = computed(() => 3)
  const stepLabels = computed(() => [...WIZARD_STEP_LABELS])
  const currentStepLabel = computed(() => stepLabels.value[step.value - 1] || '')

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

  const hostImageArch = computed(() => hostArchToImageArch(hostArch.value))
  const selectedImageId = ref('')

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

  const selectedTemplate = computed(() =>
    homeLibrary.templates.find((t) => t.slug === selectedTemplateSlug.value) ?? null,
  )

  const resolvedTemplate = computed(() => {
    if (!selectedTemplate.value) return null
    return homeLibrary.resolveTemplateForDeploy(
      selectedTemplate.value.slug,
      selectedDevice.value,
      selectedTemplate.value,
    )
  })

  const galleryTemplates = computed(() => homeLibrary.templates)
  const showCodingAgentCard = computed(() =>
    homeLibrary.images.some((img) => img.status === 'ready' && isCodingAgentImage(img)),
  )

  const isCloudInitGuest = computed(() => {
    if (galleryKind.value === 'template' || galleryKind.value === 'coding-agent') return true
    if (galleryKind.value === 'custom') return mode.value === 'cloud'
    return false
  })

  const showHostnameHint = computed(() => isCloudInitGuest.value)

  /** Guest arch is always the picked Device arch in the magazine wizard. */
  const effectiveGuestArch = computed(() => hostImageArch.value)

  const cpuCount = ref(4)
  const memoryMB = ref(8192)

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

  const { buildCreateVMPayload } = useCreateVMPayload()
  const virtio = useVirtioDownload({
    selectedHostId,
    selectedDevice,
    osType,
  })
  const imagePin = useCreateVMImagePin({ hostArch })

  const sizePresets = computed(() =>
    availableSizePresets(vmCpuCapValue.value, vmMemCapMB.value),
  )

  const selectedPreset = computed(() =>
    sizePresets.value.find((p) => p.id === selectedPresetId.value)
    || sizePresets.value[1]
    || sizePresets.value[0],
  )

  const deviceOptions = computed<DevicePickOption[]>(() => {
    const rows = devicesStore.devices
    const list = rows.length > 0 ? rows : (devicesStore.selfDevice ? [devicesStore.selfDevice] : [])
    const template = selectedTemplate.value
    if (galleryKind.value === 'template' && template) {
      return list.map((row) => {
        const local = templateIncompatibilityReasons(row, template, {
          capabilities: row.hostId === selectedDevice.value?.hostId ? pickedCaps.value : undefined,
          hasTemplate: homeLibrary.deviceHasDeployableTemplate(template.slug, row),
          fetchable: !!catalogImageForArch(template, row.platform?.arch),
        })
        const scored = placementScore.value?.candidates.find((candidate) => candidate.hostId === row.hostId)
        const hard = (scored?.reasons ?? [])
          .filter((reason) => reason.kind === 'hard')
          .map((reason) => reason.message)
        return toPickOption(row, [...new Set([...local, ...hard])], {
          recommended: isRecommendedHost(placementScore.value, row.hostId),
          recommendReasons: placementReasonsForHost(placementScore.value, row.hostId),
        })
      })
    }
    const guest = effectiveGuestArch.value || null
    const selected = selectedImage.value
    const fetchable = !!(selected?.sourceUrl?.trim() || selected?.sha256?.trim())
    return list.map((row) => {
      const hasLocal = selectedLibraryKey.value
        ? homeLibrary.deviceHasLibraryImage(selectedLibraryKey.value, row)
        : undefined
      const local = createVMIncompatibilityReasons(row, {
        guestArch: guest,
        osType: osType.value,
        capabilities: row.hostId === selectedDevice.value?.hostId ? pickedCaps.value : undefined,
        hasImage: selectedLibraryKey.value ? hasLocal : undefined,
        fetchable: selectedLibraryKey.value && hasLocal === false ? fetchable : undefined,
      })
      const scored = placementScore.value?.candidates.find((candidate) => candidate.hostId === row.hostId)
      const hard = (scored?.reasons ?? [])
        .filter((reason) => reason.kind === 'hard')
        .map((reason) => reason.message)
      const reasons = [...new Set([...local, ...hard])]
      const hostArch = row.platform?.arch ?? null
      const willCopy = !!(
        selectedLibraryKey.value
        && hasLocal === false
        && fetchable
        && guest
        && hostArch
        && imageArchSupportedOnHost(guest, hostArch)
      )
      return toPickOption(row, reasons, {
        recommended: isRecommendedHost(placementScore.value, row.hostId),
        recommendReasons: placementReasonsForHost(placementScore.value, row.hostId),
        willCopy,
      })
    })
  })

  const vmType = computed(() =>
    resolveGuestType({
      osFamily: osType.value,
      arch: hostImageArch.value,
      defaultArch: hostImageArch.value,
    }),
  )

  const displayResolution = ref('1280x800')
  const uefi = ref(true)
  const tpmOverride = ref<boolean | null>(null)
  const tpmEnabled = computed(() =>
    tpmOverride.value ?? (osType.value === 'windows' || guestProfile(vmType.value)?.defaultTPMEnabled === true),
  )
  const uefiCustomized = computed(() => uefi.value !== true)
  const tpmCustomized = computed(() => tpmOverride.value !== null)

  function setTpmEnabled(on: boolean) {
    tpmOverride.value = on
  }

  function applyPreset(preset: SizePreset) {
    selectedPresetId.value = preset.id
    cpuCount.value = preset.cpu
    memoryMB.value = preset.memGB * 1024
    diskSizeGB.value = preset.diskGB
  }

  function applySizeFromPresetId(id: string) {
    const preset = sizePresets.value.find((p) => p.id === id)
    if (preset) applyPreset(preset)
  }

  const templateInputValues = ref<Record<string, string>>({})

  function seedTemplateInputs(template: HomeTemplate | null) {
    const values: Record<string, string> = {}
    for (const input of template?.inputs ?? []) {
      if (input.id === 'ssh_keys') continue
      values[input.id] = input.default ?? ''
    }
    templateInputValues.value = values
  }

  const templateInputs = computed(() =>
    visibleTemplateInputs(selectedTemplate.value?.inputs),
  )

  function setTemplateInput(id: string, value: string) {
    templateInputValues.value = { ...templateInputValues.value, [id]: value }
  }

  function selectGalleryTemplate(template: HomeTemplate) {
    galleryKind.value = 'template'
    selectedTemplateSlug.value = template.slug
    osType.value = 'linux'
    workloadClass.value = 'house'
    name.value = defaultVMNameFromLabel(template.name)
    const medium = sizePresets.value.find((p) => p.id === 'medium') || sizePresets.value[0]
    if (medium) applyPreset(medium)
    diskSizeGB.value = template.diskSizeGB
    uefi.value = true
    tpmOverride.value = null
    seedTemplateInputs(template)
    step.value = 2
    void enterConfigure()
  }

  function selectGalleryWindows() {
    galleryKind.value = 'windows'
    osType.value = 'windows'
    workloadClass.value = 'house'
    name.value = 'Windows 11'
    selectedImageId.value = ''
    mode.value = 'iso'
    applyPreset(sizePresets.value.find((p) => p.id === 'medium') || sizePresets.value[0])
    uefi.value = true
    tpmOverride.value = true
    step.value = 2
    void enterConfigure().then(() => {
      void virtio.startVirtioWinDownload()
    })
  }

  function selectGalleryCustom() {
    galleryKind.value = 'custom'
    osType.value = 'linux'
    workloadClass.value = 'house'
    name.value = defaultVMNameFromLabel('Custom VM')
    selectedImageId.value = ''
    mode.value = 'iso'
    applyPreset(sizePresets.value.find((p) => p.id === 'medium') || sizePresets.value[0])
    uefi.value = true
    tpmOverride.value = null
    step.value = 2
    void enterConfigure()
  }

  function selectGalleryCodingAgent() {
    const img = homeLibrary.images.find((row) => row.status === 'ready' && isCodingAgentImage(row))
    if (!img) return
    galleryKind.value = 'coding-agent'
    osType.value = 'linux'
    workloadClass.value = 'agent'
    name.value = defaultVMNameFromLabel(img.name)
    selectedImageId.value = img.libraryKey || homeImageKey(img)
    mode.value = 'cloud'
    openaiPreset.value = 'home-ollama'
    applyPreset(sizePresets.value.find((p) => p.id === 'medium') || sizePresets.value[0])
    if (memoryMB.value < 2048) memoryMB.value = 2048
    if (diskSizeGB.value < 20) diskSizeGB.value = 20
    uefi.value = true
    tpmOverride.value = null
    step.value = 2
    void enterConfigure()
  }

  watch(vmCpuCapValue, (cap) => {
    if (cpuCount.value > cap) cpuCount.value = cap
  })

  watch(vmMemCapMB, (cap) => {
    if (cap != null && memoryMB.value > cap) memoryMB.value = cap
  })

  const mode = ref<'iso' | 'cloud'>('iso')
  const selectedSSHKeyId = ref('')
  const cloudUserData = ref('')
  const openaiPreset = ref<OpenAIPreset>('home-ollama')
  const byoOpenAIURL = ref(HOME_OLLAMA_GRANT_URL)
  const byoOpenAIAPIKey = ref('')

  function stepContent(s: number): string {
    return stepLabels.value[s - 1] || ''
  }

  async function enterConfigure() {
    await loadPickedDevice()
    await loadBlockDevices()
  }

  async function enterDisk() {
    await loadPickedDevice()
    await loadBlockDevices()
  }

  const diskSource = ref<'new' | 'existing' | 'raw'>('new')
  const diskSizeGB = ref(64)
  const existingDiskId = ref('')
  const sharedPaths = ref<string[]>([])

  const selectedNetworkId = ref('')
  const networkBridged = ref(false)
  const portForwards = ref<PortForwardRule[]>([])

  const isNAT = computed(() => !networkBridged.value)

  const rawDiskAvailable = computed(() => isLinuxDeviceOs(selectedDevice.value?.platform?.os))

  const rawDiskWhy = computed(() =>
    rawDiskAvailable.value
      ? 'Pass a whole host disk through to the VM.'
      : 'Host disks only on Linux Devices.',
  )

  const atResourceCap = computed(() =>
    cpuCount.value >= vmCpuCapValue.value
    || (vmMemCapMB.value != null && memoryMB.value >= vmMemCapMB.value),
  )

  const deviceLabel = computed(() =>
    selectedDevice.value?.displayName || selectedDevice.value?.hostId || 'Device',
  )

  const capHintText = computed(() =>
    `${deviceLabel.value} keeps 2 cores and 4 GB for itself.`,
  )

  const leftoverCores = computed(() => Math.max(0, hostCpuCount.value - cpuCount.value))
  const leftoverMemGB = computed(() => Math.max(0, Math.round((hostMemoryMB.value ?? memoryMB.value) / 1024) - Math.round(memoryMB.value / 1024)))

  const leftoverText = computed(() =>
    `${deviceLabel.value} keeps <b>${leftoverCores.value} cores</b> and <b>${leftoverMemGB.value} GB</b>.`,
  )

  const sharedLeftoverText = computed(() =>
    'Shared with the Device. Other apps may still use these cores.',
  )

  const headTitle = computed(() => {
    if (step.value === 1) return 'What do you want to run?'
    if (step.value === 3) return 'Disk'
    if (galleryKind.value === 'windows') return 'Set up Windows'
    return 'Name it and pick a size'
  })

  const tpmWhyText = computed(() =>
    osType.value === 'windows'
      ? 'Windows expects TPM 2.0. On by default for Windows guests.'
      : 'Linux guests do not need TPM 2.0. Off by default.',
  )

  const showSshKeyRow = computed(() => {
    if (!isCloudInitGuest.value) return false
    if (galleryKind.value === 'template' && selectedTemplate.value) {
      return templateDeclaresSshKeys(selectedTemplate.value.inputs)
    }
    return galleryKind.value === 'custom' && mode.value === 'cloud'
      || galleryKind.value === 'coding-agent'
  })

  const sshKeyRequired = computed(() => showSshKeyRow.value)

  async function loadBlockDevices() {
    blockDevices.value = []
    blockDevicePath.value = ''
    const device = selectedDevice.value
    if (!device || !rawDiskAvailable.value || !canCallDeviceAPI(device)) return
    try {
      const { data } = await api.get<HostBlockDevice[]>(deviceBlockDevicesPath(device))
      blockDevices.value = Array.isArray(data) ? data : []
    } catch {
      blockDevices.value = []
    }
  }

  watch(selectedHostId, () => {
    if (diskSource.value === 'raw' && !rawDiskAvailable.value) diskSource.value = 'new'
    void loadBlockDevices()
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

  let sshRefreshSeq = 0

  async function refreshSSHKeys() {
    const seq = ++sshRefreshSeq
    await sshKeyStore.fetchAll().catch(() => {})
    if (seq !== sshRefreshSeq) return
    applyHomeSSHKeySelection()
  }

  function onWindowFocus() {
    void refreshSSHKeys()
  }

  function onVisibilityChange() {
    if (document.visibilityState === 'visible') void refreshSSHKeys()
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
    await Promise.all([
      homeLibrary.fetchImages(devicesStore.devices).catch(() => {}),
      homeLibrary.fetchAll(devicesStore.devices).catch(() => {}),
    ])
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
        error.value = ''
        await applyLoadedResources(false, seq)
      } catch (e: unknown) {
        if (!isCurrentPickedDeviceLoad(seq)) return
        clearPickedInventory()
        error.value = apiErrorMessage(e, 'Could not load inventory from the picked Device.')
      }
    } finally {
      if (isCurrentPickedDeviceLoad(seq)) pickedDeviceLoading.value = false
    }
  }

  onMounted(() => {
    window.addEventListener('focus', onWindowFocus)
    document.addEventListener('visibilitychange', onVisibilityChange)
    void refreshHomeLibrary()
    void refreshSSHKeys()
    const repos = useRepositoryStore()
    void nudgeBuiltInCatalogSync({
      list: async () => {
        await repos.fetchAll()
        return repos.repositories
      },
      sync: (id) => api.post(`/repositories/${encodeURIComponent(id)}/sync`),
    })
  })

  onUnmounted(() => {
    placement.cancelPlacementScore()
    imagePin.abort()
    window.removeEventListener('focus', onWindowFocus)
    document.removeEventListener('visibilitychange', onVisibilityChange)
  })

  watch(currentStepLabel, (label) => {
    if (label === 'Configure') {
      void refreshHomeLibrary()
      void refreshSSHKeys()
    }
  })

  watch(selectedHostId, async (next, prev) => {
    const programmatic = consumeProgrammaticHostAssign()
    if (!next || next === prev) return
    if (!programmatic) userOverrodeHost.value = true
    existingDiskId.value = ''
    if (programmatic) return
    await loadPickedDevice()
  })

  const pinnedImageLabel = computed(() => selectedImage.value?.name ?? '')

  function applyPinnedImage(img: Image) {
    mode.value = img.imageType === 'cloud-image' ? 'cloud' : 'iso'
    const fromLibrary = homeLibrary.images.find((row) => row.id === img.id)
    selectedImageId.value = fromLibrary?.libraryKey || homeImageKey(img)
    if (!deviceImages.value.some((row) => row.id === img.id)) {
      deviceImages.value = [...deviceImages.value, img]
    }
  }

  async function pinLocalFile(file: File) {
    selectedImageId.value = ''
    const type = galleryKind.value === 'windows' ? 'iso' : undefined
    const img = await imagePin.pinFile(file, type).catch(() => null)
    if (img) applyPinnedImage(img)
  }

  async function pinRemoteUrl(url: string) {
    selectedImageId.value = ''
    const img = await imagePin.pinUrl(url).catch(() => null)
    if (img) applyPinnedImage(img)
  }

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
      return option.reasons[0] || `${option.label} is not recommended for this VM.`
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

  const placementStepReached = computed(() => step.value >= 2)

  function canProceed(): boolean {
    const content = stepContent(step.value)
    if (placementStepReached.value && (
      pickedDeviceLoading.value
      || placementRefreshing.value
      || homeLibrary.imagesLoading
      || homeLibrary.loading
    )) {
      return false
    }
    switch (content) {
      case 'Gallery':
        return galleryKind.value != null
      case 'Configure':
        if (imagePin.busy.value) return false
        if (!name.value.trim() || !selectedDevicePlaceable()) return false
        if (galleryKind.value === 'custom' || galleryKind.value === 'windows') {
          if (!selectedImageId.value) return false
        }
        if (sshKeyRequired.value && !selectedSSHKeyId.value) return false
        if (
          galleryKind.value === 'template'
          && !templateInputsComplete(selectedTemplate.value?.inputs, templateInputValues.value)
        ) {
          return false
        }
        return cpuCount.value >= 1
          && memoryMB.value >= 128
          && cpuCount.value <= vmCpuCapValue.value
          && (vmMemCapMB.value == null || memoryMB.value <= vmMemCapMB.value)
      case 'Disk':
        if (diskSource.value === 'existing') return !!existingDiskId.value
        if (diskSource.value === 'raw') {
          const dev = blockDevices.value.find((row) => row.path === blockDevicePath.value)
          return !!blockDevicePath.value && !!dev?.attachable
        }
        return diskSizeGB.value >= 1
      default:
        return false
    }
  }

  function next() {
    if (step.value === 1 && galleryKind.value) {
      return
    }
    if (!canProceed() || step.value >= totalSteps.value) return
    step.value++
    if (stepContent(step.value) === 'Configure') void enterConfigure()
    if (stepContent(step.value) === 'Disk') void enterDisk()
  }

  function goToDisk() {
    if (!canProceed()) return
    step.value = 3
    void enterDisk()
  }

  function prev() {
    if (step.value > 1) step.value--
  }

  watch(networkBridged, (bridgedMode) => {
    const net = bridgedMode
      ? allNetworks.value.find((n) => n.mode === 'bridged')
      : allNetworks.value.find((n) => n.mode === 'nat' && n.isDefault)
        ?? allNetworks.value.find((n) => n.mode === 'nat')
    selectedNetworkId.value = net?.id ?? ''
  })

  function buildTemplateDeployRequest(): DeployTemplateRequest {
    const gallery = selectedTemplate.value
    if (!gallery) throw new Error("Not in this Device's Library")
    const resolved = resolvedTemplate.value ?? gallery
    const selectedKey = sshKeyStore.keys.find((k) => k.id === selectedSSHKeyId.value)
    const inputs = collectTemplateDeployInputs(gallery.inputs, {
      values: templateInputValues.value,
      sshAuthorizedKey: selectedKey ? authorizedKeyForCloudInit(selectedKey) : undefined,
    })
    return {
      templateId: resolved.id,
      vmName: name.value.trim(),
      inputs,
      cpuCount: cpuCount.value,
      memoryMB: memoryMB.value,
      diskSizeGB: diskSizeGB.value,
      networkId: selectedNetworkId.value || undefined,
      recipe: buildDeployRecipe(gallery, hostImageArch.value),
    }
  }

  async function createRawDisk(device: DeviceApiTarget): Promise<string> {
    const diskName = `${name.value.trim()}-disk`
    const { data } = await api.post(deviceDisksPath(device), {
      name: diskName,
      blockDevice: blockDevicePath.value,
    })
    return (data as Disk).id
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
    if (networkBridged.value && !bridged.value.available) {
      error.value = bridged.value.explanation || 'Bridged networking is not available on this device.'
      return
    }
    if (!pickedDeviceStillLive()) {
      error.value = 'The selected Device is no longer available. Pick a Device again.'
      return
    }
    const target = selectedDevice.value
    loading.value = true
    try {
      if (galleryKind.value === 'template') {
        const gallery = selectedTemplate.value
        if (!gallery) {
          error.value = "Not in this Device's Library"
          return
        }
        if (!resolvedTemplate.value && !buildDeployRecipe(gallery, hostImageArch.value)) {
          error.value = "Not in this Device's Library"
          return
        }
        const request = buildTemplateDeployRequest()
        const result = await templateStore.deploy(request, target ?? undefined)
        void createProgress.followTemplate({
          name: name.value.trim(),
          request,
          device: target ?? undefined,
          result,
        })
        notifyTemplateWebUI(gallery)
        emit('created')
        return
      }

      let existingDisk = existingDiskId.value
      if (diskSource.value === 'raw') {
        if (!target) {
          error.value = 'Pick a Device to place this VM.'
          return
        }
        existingDisk = await createRawDisk(target)
      }

      let createImage = homeLibrary.resolveImageForCreate(
        selectedLibraryKey.value,
        selectedDevice.value,
        selectedImage.value,
      )
      const pickedImage = selectedImage.value
      if ((selectedLibraryKey.value || selectedImageId.value) && !createImage) {
        if (!pickedImage || !(pickedImage.sourceUrl?.trim() || pickedImage.sha256?.trim())) {
          error.value = DEVICE_IMAGE_UNFETCHABLE_REASON
          return
        }
      }
      if (!createImage && pickedImage && selectedDevice.value) {
        toast.info('Copying image to the picked Device...')
        createImage = await acquireImageOnDevice(selectedDevice.value, pickedImage)
      }
      if ((selectedLibraryKey.value || selectedImageId.value) && !createImage) {
        error.value = DEVICE_IMAGE_UNFETCHABLE_REASON
        return
      }
      const selectedKey = sshKeyStore.keys.find((k) => k.id === selectedSSHKeyId.value)
      const req = buildCreateVMPayload({
        name: name.value,
        osFamily: osType.value,
        cpuCount: cpuCount.value,
        memoryMB: memoryMB.value,
        archCustomized: false,
        vmType: vmType.value,
        uefiCustomized: uefiCustomized.value,
        uefi: uefi.value,
        tpmCustomized: tpmCustomized.value,
        tpmEnabled: tpmEnabled.value,
        diskSource: diskSource.value === 'existing' || diskSource.value === 'raw' ? 'existing' : 'new',
        existingDiskId: existingDisk,
        diskSizeGB: diskSizeGB.value,
        mode: mode.value,
        imageId: createImage?.id,
        sshAuthorizedKeys: selectedKey ? [authorizedKeyForCloudInit(selectedKey)] : [],
        userData: mergeCodingAgentUserData(
          cloudUserData.value,
          selectedImage.value,
          openaiPreset.value,
          byoOpenAIURL.value,
          byoOpenAIAPIKey.value,
        ),
        displayResolution: displayResolution.value,
        selectedNetworkId: selectedNetworkId.value,
        portForwards: portForwards.value,
        sharedPaths: sharedPaths.value,
        usbAvailable: false,
        usbDevices: [],
        workloadClass: workloadClass.value,
      })

      const result = await vmStore.create(req, target ?? undefined)
      void createProgress.followVM({
        vm: result.vm,
        taskID: result.taskID,
        device: target ?? undefined,
      })
      emit('created')
    } catch (e: any) {
      error.value = apiErrorMessage(e)
    } finally {
      loading.value = false
    }
  }

  function notifyTemplateWebUI(gallery: HomeTemplate) {
    const device = selectedDevice.value
    const links = natWebUILinks({
      templateName: gallery.name,
      networkMode: gallery.networkMode,
      isSelfDevice: device ? isSelfDevice(device) : true,
      portForwards: gallery.portForwards,
    })
    if (links.length) {
      const first = links[0]
      toast.success(`${gallery.name} is deployed.`, { label: first.label, href: first.href })
      return
    }
    if (gallery.networkMode === 'nat' && device && !isSelfDevice(device)) {
      toast.info(
        'Open the web UI on the Device that hosts this Workload. 127.0.0.1 in this browser is the wrong machine.',
      )
    }
  }

  function formatBytes(b: number) {
    if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB'
    if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB'
    return b + ' B'
  }

  const sshKeyOptions = computed(() =>
    sshKeyStore.keys.map((k) => ({
      value: k.id,
      label: k.isDefault && sshKeyStore.keys.length > 1 ? `${k.name} (default)` : k.name,
    })),
  )

  async function addSSHKey(keyName: string, publicKey: string): Promise<SSHKey> {
    const key = await sshKeyStore.create(keyName.trim(), publicKey.trim())
    selectedSSHKeyId.value = key.id
    return key
  }

  return {
    sshKeys: computed(() => sshKeyStore.keys),
    sshKeyOptions,
    selectedHostId,
    hostCpuCount,
    hostMemoryMB,
    vmCpuCapValue,
    vmMemCapGB,
    placementStepReached,
    placementScore,
    deviceOptions,
    selectedDevice,
    selectedDeviceIncompatibility,
    selectedDeviceBlocksPlacement,
    headTitle,
    galleryKind,
    selectedTemplateSlug,
    galleryTemplates,
    showCodingAgentCard,
    showHostnameHint,
    step,
    totalSteps,
    stepLabels,
    stepContent,
    currentStepLabel,
    canProceed,
    next,
    prev,
    goToDisk,
    name,
    osType,
    workloadClass,
    isAgent,
    supportsWindows,
    selectGalleryTemplate,
    selectGalleryWindows,
    selectGalleryCustom,
    selectGalleryCodingAgent,
    pinLocalFile,
    pinRemoteUrl,
    imagePinBusy: imagePin.busy,
    imagePinProgress: imagePin.progress,
    imagePinError: imagePin.error,
    pinnedImageLabel,
    virtioWinDownloading: virtio.virtioWinDownloading,
    cpuCount,
    memoryMB,
    displayResolution,
    uefi,
    tpmEnabled,
    tpmWhyText,
    setTpmEnabled,
    dedicated,
    sizePresets,
    selectedPresetId,
    selectedPreset,
    applySizeFromPresetId,
    leftoverText,
    sharedLeftoverText,
    atResourceCap,
    capHintText,
    mode,
    selectedImageId,
    selectedSSHKeyId,
    cloudUserData,
    openaiPreset,
    byoOpenAIURL,
    byoOpenAIAPIKey,
    isCodingAgentSelected: computed(() => isCodingAgentImage(selectedImage.value)),
    filteredImages,
    selectedImage,
    formatBytes,
    diskSource,
    diskSizeGB,
    existingDiskId,
    availableDisks,
    blockDevices,
    blockDevicePath,
    rawDiskAvailable,
    rawDiskWhy,
    sharedPaths,
    showSshKeyRow,
    sshKeyRequired,
    templateInputs,
    templateInputValues,
    setTemplateInput,
    refreshSSHKeys,
    addSSHKey,
    networkBridged,
    isNAT,
    error,
    loading,
    pickedDeviceLoading,
    submit,
    loadPickedDevice,
  }
}
