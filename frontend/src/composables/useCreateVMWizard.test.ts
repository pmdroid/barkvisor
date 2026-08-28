import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import api from '../api/client'
import type { Image, SSHKey } from '../api/types'
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
import { useDevicesStore } from '../stores/devices'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useToastStore } from '../stores/toast'
import { useCreateProgressStore } from '../stores/createProgress'
import { cancelLivePlacementScores, useCreateVMWizard, WIZARD_STEP_LABELS } from './useCreateVMWizard'
import { vmCpuCap, vmMemoryCapMB } from '../utils/hostBuffer'
import type { HomeTemplate } from '../stores/homeLibrary'

const originalGet = api.get
const originalPost = api.post
const originalFetch = globalThis.fetch

function mockCapabilitiesFetch() {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input)
    if (url.includes('/system/capabilities')) {
      return new Response(JSON.stringify({
        hostArch: 'arm64',
        hostCpuCount: 10,
        maxMemoryMB: 32768,
        guestTypes: [],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    }
    if (typeof originalFetch === 'function') return originalFetch(input)
    return new Response('[]', { status: 200 })
  }) as typeof fetch
}

async function waitReady(wizard: ReturnType<typeof useCreateVMWizard>) {
  const library = useHomeLibraryStore()
  for (let i = 0; i < 40; i++) {
    await nextTick()
    if (
      !wizard.pickedDeviceLoading.value
      && !library.loading
      && !library.imagesLoading
    ) {
      return
    }
    await new Promise((resolve) => setTimeout(resolve, 15))
  }
}

function readyImage(partial: Partial<Image> & Pick<Image, 'id' | 'name' | 'arch'>): Image {
  return {
    imageType: 'cloud-image',
    status: 'ready',
    sizeBytes: 1,
    sourceUrl: null,
    error: null,
    sha256: null,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

describe('useCreateVMWizard (magazine)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockCapabilitiesFetch()
    api.get = mock((url: string) => {
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({
          data: { hostArch: 'arm64', hostCpuCount: 10, maxMemoryMB: 32768 },
        })
      }
      if (url === '/templates' || url.endsWith('/templates')) {
        return Promise.resolve({ data: [] })
      }
      if (
        url === '/images' || url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/images') || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      return Promise.resolve({ data: [] })
    }) as typeof api.get
    api.post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
  })

  afterEach(() => {
    cancelLivePlacementScores()
    useCreateProgressStore().cancelAll()
    api.get = originalGet
    api.post = originalPost
    globalThis.fetch = originalFetch
  })

  test('wizard order is Gallery → Configure → Disk', () => {
    const wizard = useCreateVMWizard(() => {})
    expect(wizard.stepLabels.value).toEqual([...WIZARD_STEP_LABELS])
    expect(wizard.totalSteps.value).toBe(3)
    expect(wizard.currentStepLabel.value).toBe('Gallery')
  })

  test('template selection prefills name and shows hostname hint on configure', async () => {
    const library = useHomeLibraryStore()
    library.templates = [{
      id: 'tpl-1',
      slug: 'ubuntu-cloud',
      name: 'Ubuntu Server',
      description: 'General purpose Linux server',
      category: 'general',
      icon: 'terminal',
      imageSlug: 'ubuntu-24.04-arm64',
      cpuCount: 2,
      memoryMB: 2048,
      diskSizeGB: 16,
      portForwards: null,
      networkMode: 'nat',
      inputs: [{ id: 'ssh_keys', label: 'SSH', type: 'textarea', required: false }],
      userDataTemplate: '',
      isBuiltIn: true,
      repositoryId: null,
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', templateId: 'tpl-1', repositoryId: null }],
    }]

    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await nextTick()

    expect(wizard.step.value).toBe(2)
    expect(wizard.name.value).toBe('ubuntu-server-1')
    expect(wizard.showHostnameHint.value).toBe(true)
    expect(wizard.galleryKind.value).toBe('template')
  })

  test('Windows selection hides hostname hint', async () => {
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryWindows()
    await nextTick()
    expect(wizard.showHostnameHint.value).toBe(false)
    expect(wizard.galleryKind.value).toBe('windows')
  })

  test('host buffer reserves two cores and four GB', () => {
    expect(vmCpuCap(10)).toBe(8)
    expect(vmCpuCap(3)).toBe(2)
    expect(vmMemoryCapMB(32768)).toBe(28672)
  })

  test('raw disk is unavailable on macOS devices', async () => {
    const devices = useDevicesStore()
    devices.$patch({
      selfDevice: {
        hostId: 'desk',
        role: 'self',
        agentPort: 7778,
        reachability: 'ok',
        platform: { os: 'macOS', arch: 'arm64' },
      },
    })
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'desk' })
    await wizard.loadPickedDevice()
    expect(wizard.rawDiskAvailable.value).toBe(false)
  })

  test('coding agent card uses cloud-init hostname hint', async () => {
    const library = useHomeLibraryStore()
    const coding = readyImage({
      id: 'ca',
      name: 'Coding Agent',
      imageType: 'cloud-image',
      arch: 'arm64',
    })
    library.images = [{
      ...coding,
      libraryKey: homeImageKey(coding),
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', imageId: coding.id, status: 'ready' }],
    }]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryCodingAgent()
    await nextTick()
    expect(wizard.showHostnameHint.value).toBe(true)
    expect(wizard.workloadClass.value).toBe('agent')
  })
})

function ubuntuTemplate(overrides: Partial<HomeTemplate> = {}): HomeTemplate {
  return {
    id: 'tpl-1',
    slug: 'ubuntu-cloud',
    name: 'Ubuntu Server',
    description: 'General purpose Linux server',
    category: 'general',
    icon: 'terminal',
    imageSlug: 'ubuntu-24.04-arm64',
    cpuCount: 2,
    memoryMB: 2048,
    diskSizeGB: 16,
    portForwards: null,
    networkMode: 'nat',
    inputs: [
      { id: 'username', label: 'Username', type: 'text', required: true, default: 'ubuntu' },
      { id: 'ssh_keys', label: 'SSH Public Keys', type: 'textarea', required: true },
    ],
    userDataTemplate: 'lock_passwd: true',
    isBuiltIn: true,
    repositoryId: null,
    catalogImages: [{
      slug: 'ubuntu-24.04-arm64',
      name: 'Ubuntu',
      imageType: 'cloud-image',
      arch: 'arm64',
      downloadUrl: 'https://example.test/ubuntu-arm64.qcow2',
      sha256: 'abc',
    }],
    sourceHostIds: ['desk'],
    copies: [{ hostId: 'desk', templateId: 'tpl-1', repositoryId: null }],
    ...overrides,
  }
}

function demoKey(): SSHKey {
  return {
    id: 'k1',
    name: 'demo-key',
    publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHXv0YbPjW9kOQK8tE1gZqLmNvXyCdRfS2uJhAw4T demo',
    fingerprint: 'SHA256:demo',
    keyType: 'ssh-ed25519',
    isDefault: true,
    createdAt: '2026-01-01T00:00:00Z',
  }
}

const emptyTotals = {
  devices: 1,
  reachable: 1,
  unreachable: 0,
  workloadCount: 0,
  healthCounts: {},
}

function macSelf() {
  return {
    hostId: 'desk',
    role: 'self' as const,
    agentPort: 7778,
    reachability: 'ok' as const,
    platform: { os: 'macOS', arch: 'arm64' },
  }
}

let healthDevices: ReturnType<typeof macSelf>[] = [macSelf()]
let catalogTemplates: HomeTemplate[] = []
let catalogImages: Image[] = []

function patchSelfDevice() {
  healthDevices = [macSelf()]
}

describe('useCreateVMWizard magazine flows', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockCapabilitiesFetch()
    healthDevices = [macSelf()]
    catalogTemplates = []
    catalogImages = []
    api.get = mock((url: string) => {
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({
          data: { hostArch: 'arm64', hostCpuCount: 10, maxMemoryMB: 32768 },
        })
      }
      if (url.includes('/home/devices/health')) {
        return Promise.resolve({
          data: { devices: healthDevices, totals: { ...emptyTotals, devices: healthDevices.length } },
        })
      }
      if (url === '/templates' || url.endsWith('/templates')) {
        return Promise.resolve({ data: catalogTemplates })
      }
      if (url === '/images' || url.endsWith('/images')) {
        return Promise.resolve({ data: catalogImages })
      }
      if (url.includes('/images/')) {
        return Promise.resolve({
          data: { id: 'img-alma', status: 'downloading', downloadPercent: 10 },
        })
      }
      if (url.includes('/ssh-keys')) {
        return Promise.resolve({ data: [demoKey()] })
      }
      return Promise.resolve({ data: [] })
    }) as typeof api.get
    api.post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      if (url === '/templates/deploy' || url.endsWith('/templates/deploy')) {
        return Promise.resolve({
          data: { status: 'created', imageId: null, vm: { id: 'vm-1', name: 'ubuntu-server-1' } },
        })
      }
      if (String(url).includes('/images/acquire')) {
        return Promise.resolve({
          data: {
            id: 'img-cloud',
            name: 'Debian cloud',
            imageType: 'cloud-image',
            arch: 'arm64',
            status: 'ready',
            sourceUrl: 'https://example.test/debian.qcow2',
          },
        })
      }
      if (url === '/vms' || url.endsWith('/vms')) {
        return Promise.resolve({
          status: 201,
          data: { id: 'vm-2', name: 'custom-vm-1' },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
  })

  afterEach(() => {
    cancelLivePlacementScores()
    useCreateProgressStore().cancelAll()
    api.get = originalGet
    api.post = originalPost
    globalThis.fetch = originalFetch
  })

  test('custom flow blocks Next until an image is picked', async () => {
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryCustom()
    await waitReady(wizard)
    expect(wizard.galleryKind.value).toBe('custom')
    expect(wizard.step.value).toBe(2)
    expect(wizard.canProceed()).toBe(false)
    wizard.selectedImageId.value = 'img-1'
    expect(wizard.canProceed()).toBe(true)
  })

  test('Windows flow stays on ISO and needs a ready ISO', async () => {
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryWindows()
    await waitReady(wizard)
    expect(wizard.galleryKind.value).toBe('windows')
    expect(wizard.osType.value).toBe('windows')
    expect(wizard.mode.value).toBe('iso')
    expect(wizard.canProceed()).toBe(false)
    wizard.selectedImageId.value = 'win-iso'
    expect(wizard.canProceed()).toBe(true)
  })

  test('size presets write cpu memory and disk', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.applySizeFromPresetId('small')
    expect(wizard.selectedPresetId.value).toBe('small')
    expect(wizard.cpuCount.value).toBe(2)
    expect(wizard.memoryMB.value).toBe(4096)
    wizard.applySizeFromPresetId('large')
    expect(wizard.cpuCount.value).toBe(8)
    expect(wizard.memoryMB.value).toBe(16384)
  })

  test('SSH-required template cannot leave configure without a key', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = ''
    expect(wizard.showSshKeyRow.value).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    useSSHKeyStore().keys = [demoKey()]
    wizard.selectedSSHKeyId.value = 'k1'
    expect(wizard.canProceed()).toBe(true)
  })

  test('required template input blocks Create until filled', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate({
      inputs: [
        { id: 'username', label: 'Username', type: 'text', required: true, default: 'ubuntu' },
        { id: 'password', label: 'Password', type: 'password', required: true, minLength: 8 },
        { id: 'ssh_keys', label: 'SSH Public Keys', type: 'textarea', required: true },
      ],
    })]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    expect(wizard.templateInputs.value.some((input) => input.id === 'password')).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    wizard.setTemplateInput('password', 'short')
    expect(wizard.canProceed()).toBe(false)
    wizard.setTemplateInput('password', 'secret12')
    expect(wizard.canProceed()).toBe(true)
  })

  test('template architecture reasons surface on the picked Device', async () => {
    healthDevices = [
      macSelf(),
      {
        hostId: 'pc',
        role: 'member',
        agentPort: 7778,
        reachability: 'ok',
        platform: { os: 'linux', arch: 'x86_64' },
      },
    ]
    const prevGet = api.get
    api.get = mock((url: string) => {
      if (url.includes('/home/devices/pc/') && url.endsWith('/system/capabilities')) {
        return Promise.resolve({
          data: { hostArch: 'x86_64', hostCpuCount: 8, maxMemoryMB: 16384 },
        })
      }
      return prevGet(url)
    }) as typeof api.get
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate({ architectures: ['arm64'] })]
    library.templates = catalogTemplates
    const devices = useDevicesStore()
    devices.$patch({
      devices: healthDevices,
      selfDevice: macSelf(),
    })
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'pc' })
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    const pc = wizard.deviceOptions.value.find((option) => option.hostId === 'pc')
    expect(pc?.reasons.some((reason) => reason.includes('Architecture'))).toBe(true)
    expect(wizard.selectedHostId.value).toBe('pc')
    expect(wizard.selectedDeviceIncompatibility()).toMatch(/Architecture/)
  })

  test('SSH-needed template with no keys cannot proceed', async () => {
    api.get = mock((url: string) => {
      if (url.includes('/ssh-keys')) return Promise.resolve({ data: [] })
      if (url === '/templates' || url.endsWith('/templates')) {
        return Promise.resolve({ data: catalogTemplates })
      }
      if (url.includes('/home/devices/health')) {
        return Promise.resolve({
          data: { devices: healthDevices, totals: { ...emptyTotals, devices: healthDevices.length } },
        })
      }
      return Promise.resolve({ data: [] })
    }) as typeof api.get
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    expect(wizard.showSshKeyRow.value).toBe(true)
    expect(wizard.sshKeyRequired.value).toBe(true)
    expect(wizard.sshKeyOptions.value).toEqual([])
    expect(wizard.selectedSSHKeyId.value).toBe('')
    expect(wizard.canProceed()).toBe(false)
  })

  test('refreshSSHKeys picks a key added after empty', async () => {
    let keys: SSHKey[] = []
    api.get = mock((url: string) => {
      if (url.includes('/ssh-keys')) return Promise.resolve({ data: keys })
      if (url === '/templates' || url.endsWith('/templates')) {
        return Promise.resolve({ data: catalogTemplates })
      }
      if (url.includes('/home/devices/health')) {
        return Promise.resolve({
          data: { devices: healthDevices, totals: { ...emptyTotals, devices: healthDevices.length } },
        })
      }
      return Promise.resolve({ data: [] })
    }) as typeof api.get
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    expect(wizard.selectedSSHKeyId.value).toBe('')
    keys = [demoKey()]
    await wizard.refreshSSHKeys()
    expect(wizard.selectedSSHKeyId.value).toBe('k1')
    expect(wizard.canProceed()).toBe(true)
  })

  test('custom cloud cannot leave configure without an SSH key', async () => {
    patchSelfDevice()
    const image = readyImage({
      id: 'img-cloud',
      name: 'Debian cloud',
      imageType: 'cloud-image',
      arch: 'arm64',
      sourceUrl: 'https://example.test/debian.qcow2',
    })
    const library = useHomeLibraryStore()
    catalogImages = [image]
    library.images = [{
      ...image,
      libraryKey: homeImageKey(image),
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', imageId: image.id, status: 'ready' }],
    }]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryCustom()
    await waitReady(wizard)
    wizard.mode.value = 'cloud'
    wizard.selectedImageId.value = homeImageKey(image)
    wizard.selectedSSHKeyId.value = ''
    expect(wizard.showSshKeyRow.value).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    useSSHKeyStore().keys = [demoKey()]
    wizard.selectedSSHKeyId.value = 'k1'
    expect(wizard.canProceed()).toBe(true)
  })

  test('template deploy omits empty password and sends SSH', async () => {
    patchSelfDevice()
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    let created = false
    const wizard = useCreateVMWizard(() => { created = true })
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    expect(wizard.currentStepLabel.value).toBe('Disk')
    await wizard.submit()
    const deployCall = (api.post as ReturnType<typeof mock>).mock.calls.find((call) =>
      String(call[0]).includes('/templates/deploy'),
    )
    expect(deployCall).toBeTruthy()
    const body = deployCall![1] as {
      inputs: Record<string, string>
      vmName: string
      recipe?: { image?: { downloadUrl?: string; sha256?: string }; inputs?: { id: string }[] }
    }
    expect(body.inputs.password).toBeUndefined()
    expect(body.inputs.username).toBe('ubuntu')
    expect(body.inputs.ssh_keys).toContain('ssh-ed25519')
    expect(body.recipe?.image?.downloadUrl).toBe('https://example.test/ubuntu-arm64.qcow2')
    expect(body.recipe?.image?.sha256).toBe('abc')
    expect(body.recipe?.inputs?.some((i) => i.id === 'ssh_keys')).toBe(true)
    expect(created).toBe(true)
  })

  test('template create toasts NAT web UI links on This Device', async () => {
    patchSelfDevice()
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate({
      name: 'Onyx',
      portForwards: [{ protocol: 'tcp', hostPort: 80, guestPort: 80, httpPath: '/' }],
    })]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    const devices = useDevicesStore()
    devices.$patch({
      devices: [macSelf()],
      selfDevice: macSelf(),
    })
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    await wizard.submit()
    const toast = useToastStore().toasts.find((t) => t.message.includes('Onyx is deployed'))
    expect(toast).toBeTruthy()
    expect(toast?.link).toEqual({ label: 'Open Onyx', href: 'http://127.0.0.1/' })
  })

  test('template deploy to a Device that never synced still sends the Home recipe', async () => {
    healthDevices = [
      macSelf(),
      {
        hostId: 'studio',
        role: 'member',
        agentPort: 7778,
        reachability: 'ok',
        platform: { os: 'macOS', arch: 'arm64' },
      },
    ]
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate({
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', templateId: 'tpl-1', repositoryId: null }],
    })]
    library.templates = catalogTemplates
    const prevGet = api.get
    api.get = mock((url: string) => {
      if (url.includes('/home/devices/studio/') && url.endsWith('/templates')) {
        return Promise.resolve({ data: [] })
      }
      return prevGet(url)
    }) as typeof api.get
    useSSHKeyStore().keys = [demoKey()]
    const devices = useDevicesStore()
    devices.$patch({
      devices: healthDevices,
      selfDevice: macSelf(),
    })
    let created = false
    const wizard = useCreateVMWizard(() => { created = true }, { initialHostId: 'studio' })
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    await wizard.submit()
    expect(wizard.error.value).toBe('')
    const deployCall = (api.post as ReturnType<typeof mock>).mock.calls.find((call) =>
      String(call[0]).includes('/templates/deploy'),
    )
    expect(deployCall).toBeTruthy()
    expect(String(deployCall![0])).toContain('/home/devices/studio/')
    const body = deployCall![1] as { templateId: string; recipe?: { slug?: string } }
    expect(body.recipe?.slug).toBe('ubuntu-cloud')
    expect(created).toBe(true)
  })

  test('template deploy downloading emits created and lists progress', async () => {
    patchSelfDevice()
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    api.post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      if (url === '/templates/deploy' || url.endsWith('/templates/deploy')) {
        return Promise.resolve({
          data: { status: 'downloading', imageId: 'img-alma', vm: {
            id: 'vm-alma',
            name: 'alma',
            state: 'provisioning',
            health: 'starting',
            vmType: 'linux-arm64',
            cpuCount: 2,
            memoryMB: 2048,
            bootDiskId: 'd1',
            isoId: null,
            isoIds: null,
            networkId: null,
            cloudInitPath: null,
            description: null,
            bootOrder: null,
            displayResolution: null,
            additionalDiskIds: null,
            uefi: true,
            tpmEnabled: false,
            macAddress: null,
            sharedPaths: null,
            portForwards: null,
            usbDevices: null,
            pendingChanges: false,
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
          } },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    await wizard.submit()
    expect(useToastStore().toasts.some((t) => t.message.includes('Images'))).toBe(false)
    expect(useCreateProgressStore().jobs.some((job) => job.phase === 'downloading' && job.name)).toBe(true)
  })

  test('new disk is the default Create path', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    expect(wizard.diskSource.value).toBe('new')
    expect(wizard.canProceed()).toBe(true)
  })

  test('existing disk requires a picked unused disk', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    wizard.diskSource.value = 'existing'
    expect(wizard.canProceed()).toBe(false)
    wizard.existingDiskId.value = 'disk-1'
    expect(wizard.canProceed()).toBe(true)
  })

  test('raw disk on Linux needs an attachable block device', async () => {
    healthDevices = [{
      hostId: 'box',
      role: 'self',
      agentPort: 7778,
      reachability: 'ok',
      platform: { os: 'linux', arch: 'x86_64' },
    }]
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'box' })
    await wizard.loadPickedDevice()
    await waitReady(wizard)
    expect(wizard.rawDiskAvailable.value).toBe(true)
    wizard.diskSource.value = 'raw'
    wizard.step.value = 3
    expect(wizard.canProceed()).toBe(false)
    wizard.blockDevices.value = [{
      path: '/dev/sdb',
      name: 'sdb',
      sizeBytes: 1_000_000_000,
      attachable: true,
    }]
    wizard.blockDevicePath.value = '/dev/sdb'
    expect(wizard.canProceed()).toBe(true)
  })

  test('custom cloud submit posts create VM not template deploy', async () => {
    patchSelfDevice()
    const image = readyImage({
      id: 'img-cloud',
      name: 'Debian cloud',
      imageType: 'cloud-image',
      arch: 'arm64',
      sourceUrl: 'https://example.test/debian.qcow2',
    })
    const library = useHomeLibraryStore()
    catalogImages = [image]
    library.images = [{
      ...image,
      libraryKey: homeImageKey(image),
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', imageId: image.id, status: 'ready' }],
    }]
    useSSHKeyStore().keys = [demoKey()]
    let created = false
    const wizard = useCreateVMWizard(() => { created = true })
    wizard.selectGalleryCustom()
    await waitReady(wizard)
    wizard.mode.value = 'cloud'
    wizard.selectedImageId.value = homeImageKey(image)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    await wizard.submit()
    const calls = (api.post as ReturnType<typeof mock>).mock.calls
    expect(wizard.error.value).toBe('')
    expect(calls.some((call) => String(call[0]).includes('/templates/deploy'))).toBe(false)
    expect(calls.some((call) => String(call[0]).endsWith('/vms'))).toBe(true)
    expect(created).toBe(true)
  })

  test('Back from disk returns to configure', async () => {
    const library = useHomeLibraryStore()
    catalogTemplates = [ubuntuTemplate()]
    library.templates = catalogTemplates
    useSSHKeyStore().keys = [demoKey()]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectGalleryTemplate(library.templates[0])
    await waitReady(wizard)
    wizard.selectedSSHKeyId.value = 'k1'
    wizard.goToDisk()
    await waitReady(wizard)
    wizard.prev()
    expect(wizard.currentStepLabel.value).toBe('Configure')
    wizard.prev()
    expect(wizard.currentStepLabel.value).toBe('Gallery')
  })

  test('coding agent card is hidden when no ready agent image exists', () => {
    const library = useHomeLibraryStore()
    library.images = []
    const wizard = useCreateVMWizard(() => {})
    expect(wizard.showCodingAgentCard.value).toBe(false)
    wizard.selectGalleryCodingAgent()
    expect(wizard.galleryKind.value).toBeNull()
  })
})
