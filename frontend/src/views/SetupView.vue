<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import AppButton from '../components/ui/AppButton.vue'
import FormError from '../components/ui/FormError.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import {
  getSetupStatus,
  createAdmin,
  listInterfaces,
  installBridge,
  skipBridge,
  startRepoSync,
  getRepoSyncStatus,
  completeSetup,
  type InterfaceInfo,
  type RepoSyncStatus,
  type SetupStatus,
} from '../api/setup'
import { joinHome, isPairingPayload, type PairingJoin } from '../api/pairing'
import {
  clearSetupJoinProgress,
  loadSetupJoinProgress,
  saveSetupJoinProgress,
  shouldResumeJoinReady,
} from '../api/setupJoinProgress'
import { useAuthStore } from '../stores/auth'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useFeature } from '../composables/useFeature'
import { clearSetupCache } from '../router'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const router = useRouter()
const authStore = useAuthStore()
const caps = useCapabilitiesStore()
const managedBridge = useFeature('managedBridgeDaemon')
/** Linear UI step index (1-based). Bridge step is omitted on unsupported platforms. */
const step = ref(1)
/** Setup installs the managed bridge helper (socket_vmnet) — macOS only. */
const showBridgeStep = computed(() => managedBridge.available)

/** Create-Home wizard vs join-existing-Home branch (same SetupView). */
const path = ref<'create' | 'join'>('create')
const qrPayload = ref('')
const joinResult = ref<PairingJoin | null>(null)
/** Server-side join (identity complete) so refresh works when sessionStorage is blocked. */
const resumeJoinReady = ref(false)

const totalSteps = computed(() => {
  if (path.value === 'join') return 2
  return showBridgeStep.value ? 5 : 4
})
/** Which content panel to show for the current linear index. */
const panel = computed(() => {
  if (step.value === 1) return 'welcome'
  if (path.value === 'join') {
    return joinResult.value || resumeJoinReady.value ? 'join-ready' : 'join'
  }
  if (step.value === 2) return 'admin'
  if (showBridgeStep.value) {
    if (step.value === 3) return 'bridge'
    if (step.value === 4) return 'repos'
    return 'ready'
  }
  if (step.value === 3) return 'repos'
  return 'ready'
})
const error = ref('')
const loading = ref(false)

// Step 2: Admin
const username = ref('admin')
const password = ref('')
const passwordConfirm = ref('')

// Bridge step
const interfaces = ref<InterfaceInfo[]>([])
const selectedInterface = ref('')
const bridgeResult = ref('')

// Repo sync step
const syncStatus = ref<RepoSyncStatus | null>(null)
let syncPollInterval: ReturnType<typeof setInterval> | null = null

onMounted(async () => {
  await caps.fetchCapabilities()
  let status: SetupStatus = { complete: false }
  try {
    status = await getSetupStatus()
  } catch {
    // Server may not be ready yet
  }
  if (status.complete) {
    clearSetupJoinProgress()
    router.replace('/login')
    return
  }
  const saved = loadSetupJoinProgress()
  if (shouldResumeJoinReady(status, saved)) {
    path.value = 'join'
    joinResult.value = saved
    resumeJoinReady.value = status.joined === true
    step.value = 2
  }
})

async function nextStep() {
  error.value = ''
  // Leaving admin without a bridge step: record NAT-only skip for setup progress.
  if (path.value === 'create' && step.value === 2 && !showBridgeStep.value) {
    try {
      await skipBridge()
    } catch {
      // Already skipped or endpoint unavailable — continue wizard.
    }
  }
  step.value++
}

function startCreate() {
  path.value = 'create'
  joinResult.value = null
  resumeJoinReady.value = false
  clearSetupJoinProgress()
  nextStep()
}

function startJoin() {
  path.value = 'join'
  error.value = ''
  nextStep()
}

function backToWelcome() {
  path.value = 'create'
  joinResult.value = null
  resumeJoinReady.value = false
  qrPayload.value = ''
  error.value = ''
  step.value = 1
  clearSetupJoinProgress()
}

async function submitJoin() {
  error.value = ''
  const payload = qrPayload.value.trim()
  if (!isPairingPayload(payload)) {
    error.value = 'Paste the full pairing code (starts with barkvisor://), not only the short code.'
    return
  }
  loading.value = true
  try {
    joinResult.value = await joinHome(payload)
    saveSetupJoinProgress(joinResult.value)
  } catch (e: unknown) {
    error.value = apiErrorMessage(e, 'Failed to join Home')
  } finally {
    loading.value = false
  }
}

// Step 2: Create admin
async function submitAdmin() {
  error.value = ''
  if (password.value.length < 10) {
    error.value = 'Password must be at least 10 characters'
    return
  }
  if (password.value !== passwordConfirm.value) {
    error.value = 'Passwords do not match'
    return
  }
  loading.value = true
  try {
    await createAdmin(username.value, password.value)
    await nextStep()
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Failed to create admin user')
  } finally {
    loading.value = false
  }
}

// Step 3: Load interfaces
async function loadInterfaces() {
  try {
    interfaces.value = await listInterfaces()
    // Pre-select first en* interface
    const en = interfaces.value.find((i) => i.name.startsWith('en'))
    if (en) selectedInterface.value = en.name
  } catch {
    // Interfaces may not be available (no helper)
  }
}

async function submitBridge() {
  error.value = ''
  loading.value = true
  try {
    const result = await installBridge(selectedInterface.value)
    if (result.success) {
      bridgeResult.value = `Bridge configured on ${selectedInterface.value}`
      nextStep()
    } else {
      error.value = result.message || 'Failed to install bridge'
    }
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Failed to install bridge')
  } finally {
    loading.value = false
  }
}

async function doSkipBridge() {
  await skipBridge()
  nextStep()
}

// Step 4: Repo sync
async function startSync() {
  error.value = ''
  loading.value = true
  try {
    syncStatus.value = await startRepoSync()
    // Poll for progress
    syncPollInterval = setInterval(async () => {
      try {
        syncStatus.value = await getRepoSyncStatus()
        if (syncStatus.value.done) {
          clearInterval(syncPollInterval!)
          syncPollInterval = null
          loading.value = false
        }
      } catch {
        // Keep polling
      }
    }, 1000)
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Failed to start sync')
    loading.value = false
  }
}

// Step 5: Complete — auto-login and redirect to dashboard
async function finishSetup() {
  error.value = ''
  loading.value = true
  try {
    const { token } = await completeSetup()
    clearSetupJoinProgress()
    clearSetupCache()
    authStore.token = token
    localStorage.setItem('token', token)
    router.replace('/dashboard')
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Failed to complete setup')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="setup-page">
    <div class="setup-card">
      <img src="/app-icon.png" class="setup-logo" alt="BarkVisor" />

      <!-- Step indicator -->
      <div class="step-indicator">
        <div
          v-for="s in totalSteps"
          :key="s"
          class="step-dot"
          :class="{ active: s === step, done: s < step }"
        />
      </div>

      <!-- Welcome -->
      <div v-if="panel === 'welcome'" class="step-content">
        <h1>Welcome to BarkVisor</h1>
        <p class="step-desc">
          Set up this {{ DEVICE_LABEL }} as a new {{ HOME_LABEL }}, or join an existing
          {{ HOME_LABEL }}.
        </p>
        <div class="step-actions">
          <AppButton variant="primary" class="step-btn" @click="startCreate">
            Set up this {{ DEVICE_LABEL }}
          </AppButton>
          <AppButton variant="ghost" class="step-btn" @click="startJoin">
            Join an existing {{ HOME_LABEL }}
          </AppButton>
        </div>
      </div>

      <!-- Join existing Home (PAS-51) — same SetupView, existing /api/pairing/join -->
      <div v-if="panel === 'join'" class="step-content">
        <h2>Join an existing {{ HOME_LABEL }}</h2>
        <ol class="pairing-steps">
          <li>
            On the other {{ DEVICE_LABEL }}, open Settings → Pairing → Add a {{ DEVICE_LABEL }},
            pick the address this {{ DEVICE_LABEL }} can reach, and copy the full
            <code>barkvisor://</code> offer.
          </li>
          <li>Paste that offer here. The short printed code is not enough.</li>
          <li>
            Join. On an API-only {{ DEVICE_LABEL }}, run
            <code>barkvisor join --code 'barkvisor://pair/v1?…'</code>
            on this machine instead.
          </li>
        </ol>
        <p class="step-desc">
          This {{ DEVICE_LABEL }} still runs if that {{ DEVICE_LABEL }} is later unreachable.
        </p>
        <form @submit.prevent="submitJoin">
          <div class="form-group">
            <label>Pairing code</label>
            <textarea
              v-model="qrPayload"
              class="pairing-input"
              rows="4"
              placeholder="barkvisor://pair/v1?…"
              autocomplete="off"
              spellcheck="false"
            />
          </div>
          <FormError v-if="error" :message="error" />
          <div class="step-actions">
            <AppButton
              variant="primary"
              class="step-btn"
              :loading="loading"
              loading-text="Joining..."
            >
              Join {{ HOME_LABEL }}
            </AppButton>
            <AppButton variant="ghost" type="button" @click="backToWelcome">Back</AppButton>
          </div>
        </form>
      </div>

      <div v-if="panel === 'join-ready'" class="step-content">
        <h2>Joined your {{ HOME_LABEL }}</h2>
        <p class="step-desc">
          This {{ DEVICE_LABEL }} is part of your {{ HOME_LABEL }}. You'll be signed in with the
          same admin account. Local workloads keep running on this {{ DEVICE_LABEL }} if peers are
          unreachable.
        </p>
        <FormError v-if="error" :message="error" />
        <AppButton
          variant="primary"
          class="step-btn"
          :loading="loading"
          loading-text="Finishing..."
          @click="finishSetup"
        >
          Launch Dashboard
        </AppButton>
      </div>

      <!-- Admin credentials -->
      <div v-if="panel === 'admin'" class="step-content">
        <h2>Create Admin Account</h2>
        <p class="step-desc">Set up the administrator account for the web dashboard.</p>
        <form @submit.prevent="submitAdmin">
          <div class="form-group">
            <label>Username</label>
            <input v-model="username" type="text" placeholder="admin" />
          </div>
          <div class="form-group">
            <label>Password</label>
            <input v-model="password" type="password" placeholder="Minimum 10 characters" />
          </div>
          <div class="form-group">
            <label>Confirm Password</label>
            <input v-model="passwordConfirm" type="password" placeholder="Confirm password" />
          </div>
          <FormError v-if="error" :message="error" />
          <AppButton variant="primary" class="step-btn" :loading="loading" loading-text="Creating...">
            Continue
          </AppButton>
        </form>
      </div>

      <!-- Bridge setup (macOS / platforms with bridged networking) -->
      <div v-if="panel === 'bridge'" class="step-content" @vue:mounted="loadInterfaces">
        <h2>Network Bridge</h2>
        <p class="step-desc">
          Configure bridged networking to give VMs direct network access. You can skip this and use
          NAT instead.
        </p>
        <div v-if="interfaces.length" class="form-group">
          <label>Network Interface</label>
          <select v-model="selectedInterface" class="select-input">
            <option v-for="iface in interfaces" :key="iface.name" :value="iface.name">
              {{ iface.displayName }} — {{ iface.ipAddress || 'no IP' }}
            </option>
          </select>
        </div>
        <div v-else class="step-desc dimmed">No network interfaces detected.</div>
        <FormError v-if="error" :message="error" />
        <div class="step-actions">
          <AppButton
            v-if="interfaces.length"
            variant="primary"
            :loading="loading"
            loading-text="Configuring..."
            @click="submitBridge"
          >
            Configure Bridge
          </AppButton>
          <AppButton variant="ghost" @click="doSkipBridge">Skip (use NAT)</AppButton>
        </div>
      </div>

      <!-- Repository sync -->
      <div v-if="panel === 'repos'" class="step-content">
        <h2>Image Catalog</h2>
        <p class="step-desc">Sync the OS image and template catalog so you can create VMs.</p>
        <div v-if="syncStatus">
          <p class="sync-message">{{ syncStatus.message }}</p>
          <ProgressBar v-if="syncStatus.syncing" :indeterminate="true" />
          <div v-if="syncStatus.done && !syncStatus.error" class="sync-done">
            {{ syncStatus.imageCount }} images and {{ syncStatus.templateCount }} templates synced.
          </div>
          <FormError v-if="syncStatus.error" :message="syncStatus.error" />
        </div>
        <FormError v-if="error" :message="error" />
        <div class="step-actions">
          <AppButton
            v-if="!syncStatus || syncStatus.error"
            variant="primary"
            :loading="loading"
            loading-text="Syncing..."
            @click="startSync"
          >
            Sync Catalog
          </AppButton>
          <AppButton
            v-if="syncStatus?.done && !syncStatus?.error"
            variant="primary"
            @click="nextStep"
          >
            Continue
          </AppButton>
          <AppButton v-if="!syncStatus" variant="ghost" @click="nextStep">Skip</AppButton>
        </div>
      </div>

      <!-- Ready -->
      <div v-if="panel === 'ready'" class="step-content">
        <h2>All Set!</h2>
        <p class="step-desc">
          This {{ DEVICE_LABEL.toLowerCase() }} is your {{ HOME_LABEL }}. You'll be signed in
          automatically and taken to the dashboard.
        </p>
        <FormError v-if="error" :message="error" />
        <AppButton
          variant="primary"
          class="step-btn"
          :loading="loading"
          loading-text="Finishing..."
          @click="finishSetup"
        >
          Launch Dashboard
        </AppButton>
      </div>
    </div>
  </div>
</template>

<style scoped>
.setup-page {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  background: var(--bg);
}
.setup-card {
  width: 480px;
  text-align: center;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur-lg);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 40px 36px;
}
.setup-logo {
  width: 64px;
  height: 64px;
  border-radius: 2px;
  object-fit: cover;
  margin: 0 auto 20px;
}
.step-indicator {
  display: flex;
  gap: 8px;
  justify-content: center;
  margin-bottom: 28px;
}
.step-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--border);
  transition: background 0.2s;
}
.step-dot.active {
  background: var(--accent);
}
.step-dot.done {
  background: var(--success, #22c55e);
}
.step-content h1,
.step-content h2 {
  font-size: 22px;
  font-weight: 700;
  margin-bottom: 8px;
  letter-spacing: -0.02em;
}
.step-desc {
  color: var(--text-dim);
  font-size: 13px;
  margin-bottom: 24px;
  line-height: 1.5;
}
.step-desc.dimmed {
  opacity: 0.6;
}
.step-btn {
  width: 100%;
  padding: 11px;
  font-size: 14px;
  margin-top: 4px;
}
.step-actions {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 4px;
}
.step-content .form-group {
  text-align: left;
}
.pairing-steps {
  margin: 0 0 14px;
  padding-left: 22px;
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
  text-align: left;
}
.pairing-steps li + li {
  margin-top: 6px;
}
.select-input,
.pairing-input {
  width: 100%;
  padding: 8px 10px;
  background: var(--bg-input, var(--bg));
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm, 6px);
  font-size: 13px;
}
.pairing-input {
  font-family: var(--font-mono, ui-monospace, monospace);
  resize: vertical;
  line-height: 1.4;
}
.sync-message {
  color: var(--text-dim);
  font-size: 13px;
  margin-bottom: 12px;
}
.sync-done {
  color: var(--success, #22c55e);
  font-size: 13px;
  font-weight: 500;
  margin: 12px 0;
}
</style>
