/** PAS-44 recommender: pre-select only. Never place a workload. */

import api from '../api/client'
import type { HomePlacementScoreRequest, HomePlacementScoreResponse } from '../api/types'

export const PLACEMENT_SCORE_PATH = '/home/placement/score'

export async function scorePlacement(
  request: HomePlacementScoreRequest,
): Promise<HomePlacementScoreResponse> {
  const { data } = await api.post<HomePlacementScoreResponse>(PLACEMENT_SCORE_PATH, request)
  return data
}

/** Explicit initial pick wins; else the recommended Device; else this Device. */
export function applyRecommendedHostId(opts: {
  recommendedHostId?: string | null
  initialHostId?: string | null
  selfHostId?: string | null
  userOverrode?: boolean
  currentHostId?: string | null
}): string {
  if (opts.userOverrode && opts.currentHostId) return opts.currentHostId
  if (opts.initialHostId) return opts.initialHostId
  if (opts.recommendedHostId) return opts.recommendedHostId
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
): boolean {
  return !!score?.recommendedHostId && score.recommendedHostId === hostId
}
