import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { HostGPUDevice, SystemStatsSample } from '../api/types'
import { mapStatsHistorySamples } from './deviceStatsHistory'
import {
  defaultOllamaStatsHostId,
  OLLAMA_GPU_EMPTY_COPY,
  ollamaGpuEmptyCopy,
  ollamaGpuOccupancyLines,
  ollamaStatsApiTarget,
  ollamaStatsUnreachableCopy,
  shouldFetchOllamaDeviceStats,
} from './ollamaDeviceStats'

const desk = { hostId: 'desk', reachable: true }
const lab = { hostId: 'lab', reachable: true }
const down = { hostId: 'down', reachable: false }

function gpu(over: Partial<HostGPUDevice> = {}): HostGPUDevice {
  return {
    id: '0000:01:00.0',
    pciAddress: '0000:01:00.0',
    iommuGroup: '14',
    vendorId: '10de',
    deviceId: '2684',
    name: 'NVIDIA',
    ...over,
  }
}

describe('ollama live Device stats', () => {
  test('defaults to the Device with a running model', () => {
    expect(
      defaultOllamaStatsHostId(
        [
          {
            locations: [
              { hostId: 'lab', running: false, reachable: true },
              { hostId: 'desk', running: true, reachable: true },
            ],
          },
        ],
        [lab, desk],
      ),
    ).toBe('desk')
    expect(defaultOllamaStatsHostId([], [down, lab])).toBe('lab')
    expect(defaultOllamaStatsHostId([], [])).toBe('')
  })

  test('unreachable catalog Device skips fetch and shows unknown copy', () => {
    expect(shouldFetchOllamaDeviceStats(down, { hostId: 'down', role: 'member', reachability: 'ok' })).toBe(false)
    expect(shouldFetchOllamaDeviceStats(desk, { hostId: 'desk', role: 'member', reachability: 'unreachable' })).toBe(
      false,
    )
    expect(shouldFetchOllamaDeviceStats(desk, { hostId: 'desk', role: 'self', reachability: 'ok' })).toBe(true)
    expect(shouldFetchOllamaDeviceStats(desk, null)).toBe(true)
    expect(shouldFetchOllamaDeviceStats(null, { hostId: 'desk', role: 'self', reachability: 'ok' })).toBe(false)
    expect(ollamaStatsUnreachableCopy()).toContain('unknown')
    expect(ollamaStatsUnreachableCopy()).toContain('This machine')
    expect(ollamaStatsUnreachableCopy().toLowerCase()).not.toContain('node')
  })

  test('maps CPU percent and memory GiB the same as Device detail', () => {
    const samples: SystemStatsSample[] = [
      {
        timestamp: '2026-08-23T12:00:00Z',
        hostCpuPercent: 12.4,
        hostMemoryUsedMB: 8_192,
        hostMemoryTotalMB: 32_768,
      },
      {
        timestamp: '2026-08-23T12:00:05Z',
        hostCpuPercent: 40,
        hostMemoryUsedMB: 16_384,
        hostMemoryTotalMB: 32_768,
      },
    ]
    const series = mapStatsHistorySamples(samples, { formatTime: (ts) => ts })
    expect(series.labels).toEqual(['2026-08-23T12:00:00Z', '2026-08-23T12:00:05Z'])
    expect(series.cpu).toEqual([12.4, 40])
    expect(series.memoryGB).toEqual([8, 16])
    expect(series.memoryTotalGB).toBe(32)
  })

  test('GPU occupancy is gpu-devices, never sizeVRAM util%', () => {
    expect(ollamaGpuEmptyCopy([])).toBe(OLLAMA_GPU_EMPTY_COPY)
    expect(ollamaGpuEmptyCopy(null)).toBeNull()
    expect(ollamaGpuEmptyCopy([gpu()])).toBeNull()
    const lines = ollamaGpuOccupancyLines(
      gpu({
        driver: 'nvidia',
        vfioBound: false,
        inUseByHost: true,
        groupAddresses: ['0000:01:00.0', '0000:01:00.1'],
      }),
    )
    expect(lines).toContain('NVIDIA')
    expect(lines).toContain('nvidia')
    expect(lines).toContain('In use by host')
    expect(lines).toContain('Group mates: 0000:01:00.1')
    expect(lines.join(' ')).not.toMatch(/%/)
    expect(JSON.stringify(lines)).not.toContain('sizeVRAM')
  })

  test('ModelsView has no live Device stats; GPU lives on Device detail', () => {
    const src = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), '../views/ModelsView.vue'),
      'utf8',
    )
    expect(src).not.toContain('deviceStatsHistoryPath')
    expect(src).not.toContain('deviceGpuDevicesPath')
    expect(src).not.toContain('ollamaStatsUnreachableCopy')
    expect(src).not.toContain('latestGpuPercent')
    expect(src).not.toContain('dash-stat-label">GPU')
    expect(src).not.toContain('dash-stat-label">CPU')
    expect(src).not.toContain('dash-stat-label">Memory')
    expect(src).not.toContain('ollamaGpuOccupancyLines')
    expect(src).toContain('overflow-menu')
    expect(src).toContain('Export JSON')
    expect(src).toContain('downloadOllamaPsExport(store.models)')
    expect(src).not.toMatch(/<AppButton[\s\S]*?>\s*Export JSON/)
  })

  test('builds a Device API target from catalog when health is missing', () => {
    expect(
      ollamaStatsApiTarget('desk', [desk], () => null, 'desk'),
    ).toEqual({ hostId: 'desk', role: 'self', reachability: 'ok' })
    expect(
      ollamaStatsApiTarget('lab', [lab], (id) =>
        id === 'lab' ? { hostId: 'lab', role: 'member', reachability: 'ok' } : null,
      ),
    ).toEqual({ hostId: 'lab', role: 'member', reachability: 'ok' })
    expect(ollamaStatsApiTarget('', [desk], () => null)).toBeNull()
  })
})
