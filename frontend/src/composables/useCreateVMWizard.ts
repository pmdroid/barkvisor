import { ref, computed, watch, onMounted } from 'vue'
import { storeToRefs } from 'pinia'
import { useVMStore } from '../stores/vms'
import { useImageStore } from '../stores/images'
import { useToastStore } from '../stores/toast'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useCapabilitiesStore } from '../stores/capabilities'
import api from '../api/client'
import type { PortForwardRule, HostUSBDevice, USBPassthroughDevice } from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { useImageProgress } from './useTicketedEventSource'
import { useNetworkStore } from '../stores/networks'
import { useDiskStore } from '../stores/disks'
import { hostArchToImageArch, normalizeImageArch } from '../utils/imageArch'

export function useCreateVMWizard(emit: (e: 'created') => void) {
  const vmStore = useVMStore()
  const imageStore = useImageStore()
  const toast = useToastStore()
  const sshKeyStore = useSSHKeyStore()
  const caps = useCapabilitiesStore()
  const networkStore = useNetworkStore()
  const diskStore = useDiskStore()
  const { supportsUSBPassthrough, hostArch, guestTypes } = storeToRefs(caps)
  const { networks } = storeToRefs(networkStore)
  const { unattached: availableDisks } = storeToRefs(diskStore)

  // Wizard step
  const step = ref(1)

  // Step 1: OS & Name
  const name = ref('')
  const osType = ref<'linux' | 'windows'>('linux')
  /**
   * Windows guest profile exists only for arm64 today (`windows-arm64`).
   * Until capabilities load, do not offer Windows — store defaults are arm64 and
   * would otherwise allow a stale selection on x86_64 hosts (PAS-48).
   */
  const supportsWindows = computed(() => {
    if (!caps.loaded) return false
    const host = hostArchToImageArch(hostArch.value)
    if (host !== 'arm64') return false
    const types = guestTypes.value ?? []
    if (types.length === 0) return true
    return types.some(
      (g) => g.id === 'windows-arm64' || (g.osFamily === 'windows' && g.arch === 'arm64'),
    )
  })
  const vmType = computed(() => {
    const arch = hostArchToImageArch(hostArch.value)
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
  const tpmEnabled = computed(() => osType.value === 'windows')

  function selectOS(os: 'linux' | 'windows') {
    if (os === 'windows' && !supportsWindows.value) return
    osType.value = os
    selectedImageId.value = ''
    const maxCpu = caps.hostCpuCount
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
      const { data } = await api.get('/system/virtio-win/status')
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
      const { data } = await api.post('/system/virtio-win/download')
      virtioWinImageId.value = data.imageId

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
      const { data } = await api.get('/system/usb-devices')
      hostUSBDevices.value = data
    } catch {
      hostUSBDevices.value = []
    }
  }

  function toggleUSBDevice(dev: HostUSBDevice) {
    const idx = selectedUSBDevices.value.findIndex(
      (d) => d.vendorId === dev.vendorId && d.productId === dev.productId,
    )
    if (idx >= 0) {
      selectedUSBDevices.value.splice(idx, 1)
    } else {
      selectedUSBDevices.value.push({
        vendorId: dev.vendorId,
        productId: dev.productId,
        label: dev.name,
      })
    }
  }

  function isUSBSelected(dev: HostUSBDevice): boolean {
    return selectedUSBDevices.value.some(
      (d) => d.vendorId === dev.vendorId && d.productId === dev.productId,
    )
  }

  function removeUSBDevice(dev: USBPassthroughDevice) {
    selectedUSBDevices.value = selectedUSBDevices.value.filter(
      (d) => !(d.vendorId === dev.vendorId && d.productId === dev.productId),
    )
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
    if (!selectedNetworkId.value) return false
    const net = networks.value.find((n) => n.id === selectedNetworkId.value)
    return net?.mode === 'nat'
  })

  // State
  const error = ref('')
  const loading = ref(false)

  onMounted(async () => {
    // Resolve host arch before OS selection can enable Windows (PAS-48).
    await caps.fetchCapabilities().catch(() => {})
    imageStore.fetchAll()
    sshKeyStore.fetchAll().then(() => {
      if (sshKeyStore.defaultKey) selectedSSHKeyId.value = sshKeyStore.defaultKey.id
    })
    await Promise.all([networkStore.fetchAll(), diskStore.fetchAll()])
    const defaultNet =
      networkStore.defaultNAT
      ?? networks.value.find(n => n.isDefault)
      ?? null
    if (defaultNet) selectedNetworkId.value = defaultNet.id
  })

  const hostImageArch = computed(() => hostArchToImageArch(hostArch.value))

  /** Local ready images of the current mode, unfiltered by arch. */
  function readyImagesForMode(imageType: 'iso' | 'cloud-image') {
    return imageStore.images.filter((i) => i.imageType === imageType && i.status === 'ready')
  }

  /** Match host arch once known; empty arch allowed (e.g. virtio drivers). */
  function localImageMatchesHost(arch: string | null | undefined): boolean {
    if (!caps.hostArchKnown) return true
    if (!arch) return true
    const img = normalizeImageArch(arch)
    if (!img) return false
    return img === hostImageArch.value
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
    if (!caps.hostArchKnown) return 0
    const type = mode.value === 'iso' ? 'iso' : 'cloud-image'
    return readyImagesForMode(type).filter((i) => i.arch && !localImageMatchesHost(i.arch)).length
  })

  const selectedImage = computed(() => {
    if (!selectedImageId.value) return null
    return imageStore.images.find((i) => i.id === selectedImageId.value) || null
  })

  const selectedNetwork = computed(() => {
    if (!selectedNetworkId.value) return null
    return networks.value.find((n) => n.id === selectedNetworkId.value) || null
  })

  function canProceed(): boolean {
    if (osType.value === 'windows' && !supportsWindows.value) return false
    const content = stepContent(step.value)
    switch (content) {
      case 'OS':
        return !!name.value.trim()
      case 'Hardware':
        return cpuCount.value >= 1 && memoryMB.value >= 128
      case 'Image':
        return !!selectedImageId.value
      case 'Drivers':
        return virtioWinAvailable.value
      case 'Storage':
        return diskSource.value === 'existing' ? !!existingDiskId.value : diskSizeGB.value >= 1
      case 'Network':
        return true
      case 'Summary':
        return true
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
    if (osType.value === 'windows' && !supportsWindows.value) {
      error.value = 'Windows VMs are not available on this host architecture.'
      return
    }
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
        const selectedKey = sshKeyStore.keys.find((k) => k.id === selectedSSHKeyId.value)
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
      if (supportsUSBPassthrough.value && selectedUSBDevices.value.length > 0) {
        req.usbDevices = selectedUSBDevices.value
      }

      const result = await vmStore.create(req)
      if (result.taskID) {
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

  const archLabel = computed(() => (hostArch.value === 'x86_64' ? 'x86_64' : 'ARM64'))

  return {
    // stores exposed for steps that need lists
    sshKeyStore,
    supportsUSBPassthrough,
    hostArch,
    archLabel,

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
