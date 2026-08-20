import { ref, watch, onUnmounted, type ComputedRef, type Ref } from 'vue'
import type { HomePlacementScoreResponse } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useHomeLibraryStore } from '../stores/homeLibrary'
import { createVMIncompatibilityReasons } from '../utils/deviceCompatibility'
import {
  applyRecommendedHostId,
  isPlacementScoreAborted,
  PLACEMENT_SCORE_DEBOUNCE_MS,
  scorePlacement,
} from '../utils/placement'

const livePlacementCancels = new Set<() => void>()

/** Abort in-flight placement scores. Tests call this in afterEach. */
export function cancelLivePlacementScores() {
  for (const cancel of [...livePlacementCancels]) cancel()
  livePlacementCancels.clear()
}

export function usePlacement(opts: {
  selectedHostId: Ref<string>
  userOverrodeHost: Ref<boolean>
  initialHostId?: string
  effectiveGuestArch: ComputedRef<string>
  memoryMB: Ref<number>
  osType: Ref<'linux' | 'windows'>
  selectedLibraryKey: ComputedRef<string>
}) {
  const devicesStore = useDevicesStore()
  const homeLibrary = useHomeLibraryStore()

  const placementScore = ref<HomePlacementScoreResponse | null>(null)
  const placementRefreshing = ref(false)
  let placementScoreSeq = 0
  /** True while refreshPlacement assigns selectedHostId — not a user pick. */
  let applyingRecommendedHost = false
  let placementAbort: AbortController | null = null
  let placementDebounce: ReturnType<typeof setTimeout> | undefined

  function consumeProgrammaticHostAssign() {
    const programmatic = applyingRecommendedHost
    applyingRecommendedHost = false
    return programmatic
  }

  function assignRecommendedHostId(hostId: string) {
    if (hostId === opts.selectedHostId.value) return
    applyingRecommendedHost = true
    opts.selectedHostId.value = hostId
  }

  function hostAllowed(hostId: string): boolean {
    const row = devicesStore.deviceByHostId(hostId)
    if (!row) return false
    return createVMIncompatibilityReasons(row, {
      guestArch: opts.effectiveGuestArch.value,
      osType: opts.osType.value,
      hasImage: opts.selectedLibraryKey.value
        ? homeLibrary.deviceHasLibraryImage(opts.selectedLibraryKey.value, row)
        : undefined,
    }).length === 0
  }

  function cancelPlacementScore() {
    if (placementDebounce !== undefined) {
      clearTimeout(placementDebounce)
      placementDebounce = undefined
    }
    placementAbort?.abort()
    placementAbort = null
    livePlacementCancels.delete(cancelPlacementScore)
  }

  livePlacementCancels.add(cancelPlacementScore)

  function schedulePlacementRefresh(applyRecommendation: boolean) {
    if (placementDebounce !== undefined) clearTimeout(placementDebounce)
    placementDebounce = setTimeout(() => {
      placementDebounce = undefined
      void refreshPlacement(applyRecommendation)
    }, PLACEMENT_SCORE_DEBOUNCE_MS)
  }

  async function refreshPlacement(applyRecommendation = true) {
    placementAbort?.abort()
    const ac = new AbortController()
    placementAbort = ac
    const seq = ++placementScoreSeq
    placementRefreshing.value = true
    try {
      const guest = opts.effectiveGuestArch.value
      const data = await scorePlacement({
        declaredArchitectures: guest ? [guest] : [],
        minMemoryMB: opts.memoryMB.value,
        requestedMemoryMB: opts.memoryMB.value,
      }, { signal: ac.signal })
      if (seq !== placementScoreSeq) return
      placementScore.value = data
    } catch (error) {
      if (seq !== placementScoreSeq || isPlacementScoreAborted(error)) return
      placementScore.value = null
    } finally {
      if (seq === placementScoreSeq) placementRefreshing.value = false
    }
    if (seq !== placementScoreSeq) return
    if (!applyRecommendation || opts.userOverrodeHost.value) return
    assignRecommendedHostId(applyRecommendedHostId({
      recommendedHostId: placementScore.value?.recommendedHostId,
      initialHostId: opts.initialHostId,
      selfHostId: devicesStore.selfDevice?.hostId,
      currentHostId: opts.selectedHostId.value,
      hostAllowed,
    }))
  }

  watch([opts.memoryMB, opts.effectiveGuestArch, opts.osType], () => {
    schedulePlacementRefresh(false)
  })

  watch(() => homeLibrary.imagesLoading, (loading, wasLoading) => {
    if (wasLoading && !loading) void refreshPlacement(true)
  })

  onUnmounted(() => {
    cancelPlacementScore()
  })

  return {
    placementScore,
    placementRefreshing,
    assignRecommendedHostId,
    consumeProgrammaticHostAssign,
    cancelPlacementScore,
    schedulePlacementRefresh,
    refreshPlacement,
    hostAllowed,
  }
}
