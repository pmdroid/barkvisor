import { describe, expect, test } from 'bun:test'
import type { HomePlacementScoreResponse } from '../api/types'
import {
  applyRecommendedHostId,
  isPlacementScoreAborted,
  isRecommendedHost,
  placementReasonsForHost,
} from './placement'

const score: HomePlacementScoreResponse = {
  recommendedHostId: 'studio',
  candidates: [
    {
      hostId: 'studio',
      role: 'member',
      eligible: true,
      recommended: true,
      rank: 1,
      score: 80,
      reasons: [{ code: 'headroom', kind: 'soft', message: '6144 MB free memory, 8% CPU load.' }],
    },
    {
      hostId: 'desk',
      role: 'self',
      eligible: true,
      recommended: false,
      rank: 2,
      score: 40,
      reasons: [{ code: 'headroom', kind: 'soft', message: '1024 MB free memory, 40% CPU load.' }],
    },
  ],
}

describe('placement (PAS-44)', () => {
  test('pre-selects the recommended Device unless the operator already picked', () => {
    expect(applyRecommendedHostId({
      recommendedHostId: 'studio',
      selfHostId: 'desk',
    })).toBe('studio')
    expect(applyRecommendedHostId({
      recommendedHostId: 'studio',
      initialHostId: 'desk',
      selfHostId: 'desk',
    })).toBe('desk')
    expect(applyRecommendedHostId({
      recommendedHostId: 'studio',
      userOverrode: true,
      currentHostId: 'desk',
      selfHostId: 'desk',
    })).toBe('desk')
    expect(applyRecommendedHostId({
      recommendedHostId: null,
      selfHostId: 'desk',
    })).toBe('desk')
    expect(applyRecommendedHostId({})).toBe('')
  })

  test('never falls back to an arbitrary peer when no recommendation exists', () => {
    expect(applyRecommendedHostId({
      recommendedHostId: null,
      selfHostId: 'desk',
      currentHostId: '',
    })).toBe('desk')
    expect(isRecommendedHost(score, 'studio')).toBe(true)
    expect(isRecommendedHost(score, 'desk')).toBe(false)
    expect(placementReasonsForHost(score, 'studio')[0]).toContain('6144 MB free')
  })

  test('ignores a server recommendation the local picker cannot use', () => {
    const hostAllowed = (hostId: string) => hostId !== 'studio'
    expect(applyRecommendedHostId({
      recommendedHostId: 'studio',
      selfHostId: 'desk',
      hostAllowed,
    })).toBe('desk')
    expect(isRecommendedHost(score, 'studio', hostAllowed)).toBe(false)
    expect(isRecommendedHost(score, 'studio', (hostId) => hostId === 'studio')).toBe(true)
  })

  test('treats axios cancel and ERR_CANCELED as an aborted score', () => {
    expect(isPlacementScoreAborted({ code: 'ERR_CANCELED' })).toBe(true)
    expect(isPlacementScoreAborted(new Error('network'))).toBe(false)
    expect(isPlacementScoreAborted(undefined)).toBe(false)
  })
})
