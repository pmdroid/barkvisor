/** PAS-44 recommender: pre-select only. Never place a workload. */

import axios from 'axios'
import api from '../api/client'
import type { HomePlacementScoreRequest, HomePlacementScoreResponse } from '../api/types'

export const PLACEMENT_SCORE_PATH = '/home/placement/score'
/** Coalesce memory/arch keystrokes before probing every Home member. */
export const PLACEMENT_SCORE_DEBOUNCE_MS = 200

export async function scorePlacement(
  request: HomePlacementScoreRequest,
  opts?: { signal?: AbortSignal },
): Promise<HomePlacementScoreResponse> {
  const { data } = await api.post<HomePlacementScoreResponse>(
    PLACEMENT_SCORE_PATH,
    request,
    { signal: opts?.signal },
  )
  return data
}

export function isPlacementScoreAborted(error: unknown): boolean {
  if (axios.isCancel(error)) return true
  return typeof error === 'object' && error !== null
    && 'code' in error
    && (error as { code?: string }).code === 'ERR_CANCELED'
}

function hostIsAllowed(hostId: string, hostAllowed?: (hostId: string) => boolean): boolean {
  return hostAllowed ? hostAllowed(hostId) : true
}

/** Explicit initial pick wins; else the recommended Device; else this Device. */
export function applyRecommendedHostId(opts: {
  recommendedHostId?: string | null
  initialHostId?: string | null
  selfHostId?: string | null
  userOverrode?: boolean
  currentHostId?: string | null
  /** Reject a server recommendation the local picker cannot deploy (e.g. Library). */
  hostAllowed?: (hostId: string) => boolean
}): string {
  if (opts.userOverrode && opts.currentHostId) return opts.currentHostId
  if (opts.initialHostId) return opts.initialHostId
  if (opts.recommendedHostId && hostIsAllowed(opts.recommendedHostId, opts.hostAllowed)) {
    return opts.recommendedHostId
  }
  return opts.selfHostId || opts.currentHostId || ''
}

export function placementReasonsForHost(
  score: HomePlacementScoreResponse | null | undefined,
  hostId: string,
): string[] {
  const row = score?.candidates.find((candidate) => candidate.hostId === hostId)
  return row?.reasons.map((reason) => reason.message) ?? []
}

export function isRecommendedHost(
  score: HomePlacementScoreResponse | null | undefined,
  hostId: string,
  hostAllowed?: (hostId: string) => boolean,
): boolean {
  if (!score?.recommendedHostId || score.recommendedHostId !== hostId) return false
  return hostIsAllowed(hostId, hostAllowed)
}
