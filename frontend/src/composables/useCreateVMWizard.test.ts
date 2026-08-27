import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import api from '../api/client'
import type { Image } from '../api/types'
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
import { useDevicesStore } from '../stores/devices'
import { cancelLivePlacementScores, useCreateVMWizard, WIZARD_STEP_LABELS } from './useCreateVMWizard'
import { vmCpuCap, vmMemoryCapMB } from '../utils/hostBuffer'

const originalGet = api.get
const originalPost = api.post

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
    api.get = originalGet
    api.post = originalPost
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
