import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  API_VERSION,
  API_VERSION_HEADER,
  ERROR_ENVELOPE_KEYS,
  isAPIErrorEnvelope,
} from './contract'
import type { Disk, Image, Network, VM, WorkloadSpec } from './types'

const specPath = join(dirname(fileURLToPath(import.meta.url)), '../../../docs/api/openapi.yaml')

function specText(): string {
  return readFileSync(specPath, 'utf8')
}

describe('API contract (PAS-78)', () => {
  test('version constants match the published spec', () => {
    expect(API_VERSION).toBe(1)
    expect(API_VERSION_HEADER).toBe('X-BarkVisor-API-Version')
    const yaml = specText()
    expect(yaml).toContain('x-barkvisor-api-version: 1')
    expect(yaml).toContain(`x-barkvisor-version-header: ${API_VERSION_HEADER}`)
    expect(yaml).toContain('openapi: "3.1.0"')
  })

  test('error envelope is the existing middleware shape', () => {
    expect([...ERROR_ENVELOPE_KEYS]).toEqual(['error', 'code', 'reason', 'status'])
    const body = { error: true as const, code: 'bad_request', reason: 'Name is required', status: 400 }
    expect(isAPIErrorEnvelope(body)).toBe(true)
    expect(isAPIErrorEnvelope({ error: 'yes' })).toBe(false)
    const yaml = specText()
    for (const key of ERROR_ENVELOPE_KEYS) {
      expect(yaml).toContain(`${key}:`)
    }
  })

  test('stable paths are documented', () => {
    const yaml = specText()
    for (const path of [
      '/api/auth/login',
      '/api/auth/refresh',
      '/api/auth/logout',
      '/api/auth/me',
      '/api/auth/login-offers',
      '/api/auth/login-offers/redeem',
      '/api/vms',
      '/api/disks',
      '/api/networks',
      '/api/images',
      '/api/health',
      '/api/openapi.yaml',
      '/api/contract',
      '/api/workloads/apply',
      '/api/workloadspec.schema.json',
      '/api/system/usb-devices',
      '/api/system/gpu-devices',
      '/api/system/pci-devices',
      '/api/system/library/settings',
      '/api/system/remote-access',
      '/api/home/settings/remote-access',
      '/api/vms/{id}/usb',
      '/api/vms/{id}/gpu',
      '/api/vms/{id}/health',
      '/api/vms/{id}/session/resume',
      '/api/vms/{id}/session/reset',
      '/api/vms/{id}/session/burn',
      '/api/workloads/health-summary',
      '/api/agent/whoami',
      '/api/agent/library/images',
      '/api/agent/library/images/{id}/content',
      '/api/pairing/codes',
      '/api/pairing/redeem',
      '/api/pairing/join',
      '/api/home/devices',
      '/api/home/devices/health',
      '/api/home/placement/score',
    ]) {
      expect(yaml).toContain(`  ${path}:`)
    }
    expect(yaml).toContain('x-barkvisor-transport: sse')
    expect(yaml).toContain('x-barkvisor-transport: websocket')
  })

  test('frontend types cover the frozen resource shapes', () => {
    const spec: WorkloadSpec = {
      apiVersion: 'barkvisor.dev/v1',
      kind: 'VirtualMachine',
      metadata: { name: 'fixture' },
      spec: { resources: { cpu: 2, memoryMb: 1024 } },
    }
    const vm: VM = {
      spec,
      status: {
        state: 'stopped',
        pendingChanges: false,
        generation: 1,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        health: 'stopped',
        backend: {
          accelerator: 'tcg',
          guestArch: 'arm64',
          qemuBinary: 'qemu-system-aarch64',
          emulated: true,
        },
      },
      id: 'vm-1',
      name: 'fixture',
      vmType: 'linux-arm64',
      state: 'stopped',
      health: 'stopped',
      cpuCount: 2,
      memoryMB: 1024,
      bootDiskId: 'disk-1',
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
    }
    const disk: Disk = {
      id: 'disk-1',
      name: 'boot',
      path: '/data/disks/disk-1.qcow2',
      sizeBytes: 1024,
      format: 'qcow2',
      vmId: null,
      status: 'ready',
      createdAt: '2026-01-01T00:00:00Z',
    }
    const network: Network = { id: 'net-1', name: 'default', mode: 'nat', isDefault: true }
    const image: Image = {
      id: 'img-1',
      name: 'Ubuntu',
      imageType: 'cloud-image',
      arch: 'arm64',
      status: 'ready',
      sizeBytes: 1024,
      sourceUrl: null,
      error: null,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    }
    expect(vm.spec?.apiVersion).toBe('barkvisor.dev/v1')
    expect(disk.format).toBe('qcow2')
    expect(network.mode).toBe('nat')
    expect(image.arch).toBe('arm64')
  })
})
