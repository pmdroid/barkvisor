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
  skipBridge,
  startRepoSync,
  getRepoSyncStatus,
  completeSetup,
  type RepoSyncStatus,
  type SetupStatus,
} from '../api/setup'
import { useAuthStore } from '../stores/auth'
import { useCapabilitiesStore } from '../stores/capabilities'
import { clearSetupCache } from '../router'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const router = useRouter()
const authStore = useAuthStore()
const caps = useCapabilitiesStore()
/** Linear UI step index (1-based). Wizard: Welcome → Admin → Catalog → Ready. */
const step = ref(1)

const panel = computed(() => {
  if (step.value === 1) return 'welcome'
  if (step.value === 2) return 'admin'
  if (step.value === 3) return 'repos'
  return 'ready'
})
const error = ref('')
const loading = ref(false)

// Step 2: Admin
const username = ref('admin')
const password = ref('')
const passwordConfirm = ref('')

const passwordOk = computed(() => password.value.length >= 10)
const confirmOk = computed(() => passwordOk.value && passwordConfirm.value === password.value)
const adminValid = computed(
  () => username.value.trim() !== '' && passwordOk.value && confirmOk.value,
)
const passwordHint = computed(() =>
  password.value && !passwordOk.value ? 'err: too short — min_length: 10' : 'min_length: 10',
)
const confirmHint = computed(() => {
  if (!passwordConfirm.value) return ''
  return confirmOk.value ? 'ok: passwords match' : 'err: passwords do not match'
})

// Repo sync step
const syncStatus = ref<RepoSyncStatus | null>(null)
let syncPollInterval: ReturnType<typeof setInterval> | null = null

const catalogSummary = computed(() =>
  syncStatus.value?.done && !syncStatus.value?.error
    ? `${syncStatus.value.imageCount} images, ${syncStatus.value.templateCount} templates`
    : 'not synced',
)

// Ops-checklist rail
const sessionId = `BV-SETUP-${Math.floor(1000 + Math.random() * 9000)}`

const railSteps = [
  { num: '01', t: 'Welcome', key: 'welcome' },
  { num: '02', t: 'Admin account', key: 'admin' },
  { num: '03', t: 'Image catalog', key: 'repos' },
  { num: '04', t: 'Ready', key: 'ready' },
]
const currentRailIndex = computed(() => {
  const idx = railSteps.findIndex((s) => s.key === panel.value)
  return idx === -1 ? 0 : idx
})
function railItemState(i: number) {
  if (i < currentRailIndex.value) return 'done'
  if (i === currentRailIndex.value) return 'current'
  return 'pending'
}
const railState = computed(() => {
  if (panel.value === 'ready') return 'complete'
  if (panel.value === 'repos' && syncStatus.value?.syncing) return 'syncing catalog'
  return 'awaiting input'
})

onMounted(async () => {
  await caps.fetchCapabilities()
  let status: SetupStatus = { complete: false }
  try {
    status = await getSetupStatus()
  } catch {
    // Server may not be ready yet
  }
  if (status.complete) {
    router.replace('/login')
  }
})

async function nextStep() {
  error.value = ''
  // Leaving admin: record NAT-only skip for setup progress.
  // Bridge setup lives on the Networks page, not in first-run.
  if (step.value === 2) {
    try {
      await skipBridge()
    } catch {
      // Already skipped or endpoint unavailable — continue wizard.
    }
  }
  step.value++
}

function startCreate() {
  nextStep()
}

function backToWelcome() {
  error.value = ''
  step.value = 1
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

// Step 3: Repo sync
async function startSync() {
  error.value = ''
  loading.value = true
  try {
    syncStatus.value = await startRepoSync()
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

// Step 4: Complete — auto-login and redirect to dashboard
async function finishSetup() {
  error.value = ''
  loading.value = true
  try {
    const { token } = await completeSetup()
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
    <div class="shell">
      <!-- Top bar -->
      <div class="topbar">
        <svg width="22" height="22" viewBox="0 0 22 22" aria-hidden="true">
          <rect width="22" height="22" rx="4" fill="#0090f8" />
          <path
            d="M6.5 9v4M10 6.5v9M13.5 9.5v3M17 7.5v7"
            stroke="#fff"
            stroke-width="1.7"
            stroke-linecap="round"
            fill="none"
          />
        </svg>
        <span class="name">BarkVisor</span>
        <span class="tag">First-run setup</span>
        <div class="spacer"></div>
        <span class="session"
          >session <b>{{ sessionId }}</b></span
        >
      </div>

      <div class="card">
        <!-- Commissioning checklist rail -->
        <div class="rail">
          <div class="rail-head">Commissioning checklist</div>
          <div
            v-for="(s, i) in railSteps"
            :key="s.num"
            class="item"
            :class="railItemState(i)"
          >
            <div class="box">
              <svg viewBox="0 0 12 12"><path d="M2 6.5l2.6 2.6L10 3.5" /></svg>
            </div>
            <div>
              <div class="num">{{ s.num }}</div>
              <div class="t">{{ s.t }}</div>
              <div class="st"><span class="dot"></span>{{ railItemState(i) }}</div>
            </div>
          </div>
          <div class="rail-foot">
            <div>
              <span class="k">device&nbsp;&nbsp;</span><span class="v">unassigned</span>
            </div>
            <div>
              <span class="k">state&nbsp;&nbsp;&nbsp;&nbsp;</span
              ><span class="v">{{ railState }}</span>
            </div>
          </div>
        </div>

        <!-- Detail pane -->
        <div class="content">
          <!-- Welcome -->
          <div v-if="panel === 'welcome'" class="pane">
            <div class="eyebrow">Step 01 — Welcome</div>
            <h1>Commission this {{ DEVICE_LABEL }}</h1>
            <p class="sub">
              BarkVisor manages headless QEMU virtual machines. Set up this
              {{ DEVICE_LABEL }} as a new {{ HOME_LABEL }}. To join an existing
              {{ HOME_LABEL }}, run <code>barkvisor join --code</code> on the CLI.
            </p>
            <button class="choice" @click="startCreate">
              <span class="cid">→</span>
              <span>
                <div class="t">Set up this {{ DEVICE_LABEL }}</div>
                <div class="d">
                  Create a new {{ HOME_LABEL }} with this machine as its first
                  {{ DEVICE_LABEL }}.
                </div>
              </span>
            </button>
          </div>

          <!-- Admin account -->
          <div v-if="panel === 'admin'" class="pane">
            <div class="eyebrow">Step 02 — Admin account</div>
            <h1>Create Admin Account</h1>
            <p class="sub">This account administers every {{ DEVICE_LABEL }} in your {{ HOME_LABEL }}.</p>
            <form @submit.prevent="submitAdmin">
              <div class="field">
                <label for="setup-username">Username</label>
                <input
                  id="setup-username"
                  v-model="username"
                  type="text"
                  placeholder="admin"
                  autocomplete="off"
                />
              </div>
              <div class="field">
                <label for="setup-password">Password</label>
                <input
                  id="setup-password"
                  v-model="password"
                  type="password"
                  placeholder="Minimum 10 characters"
                />
                <div class="hint" :class="{ err: password && !passwordOk }">
                  {{ passwordHint }}
                </div>
              </div>
              <div class="field">
                <label for="setup-confirm">Confirm password</label>
                <input
                  id="setup-confirm"
                  v-model="passwordConfirm"
                  type="password"
                  placeholder="Repeat password"
                />
                <div class="hint" :class="{ ok: confirmHint.startsWith('ok'), err: confirmHint.startsWith('err') }">
                  {{ confirmHint }}
                </div>
              </div>
              <FormError v-if="error" :message="error" />
              <div class="actions">
                <AppButton variant="ghost" type="button" @click="backToWelcome">Back</AppButton>
                <div class="spacer"></div>
                <AppButton
                  variant="primary"
                  :disabled="!adminValid"
                  :loading="loading"
                  loading-text="Creating..."
                >
                  Continue
                </AppButton>
              </div>
            </form>
          </div>

          <!-- Image catalog -->
          <div v-if="panel === 'repos'" class="pane">
            <div class="eyebrow">Step 03 — Image catalog</div>
            <h1>Image Catalog</h1>
            <p class="sub">
              Sync the OS image and template catalog so you can create virtual machines right
              away.
            </p>
            <div class="console">
              <span class="ln">$ barkvisorctl catalog sync</span>
              <span v-if="!syncStatus" class="ln am">// idle — press Sync to fetch the catalog</span>
              <span v-else-if="syncStatus.syncing" class="ln ac">→ {{ syncStatus.message }}</span>
              <span v-else-if="syncStatus.done && !syncStatus.error" class="ln ok">
                ✓ {{ syncStatus.imageCount }} images and {{ syncStatus.templateCount }} templates
                synced
              </span>
              <span v-else-if="syncStatus.error" class="ln err">✗ {{ syncStatus.error }}</span>
            </div>
            <ProgressBar v-if="syncStatus?.syncing" :indeterminate="true" class="sync-progress" />
            <div class="sync-status" :class="{ ok: syncStatus?.done && !syncStatus?.error }">
              <template v-if="syncStatus?.syncing">syncing…</template>
              <template v-else-if="syncStatus?.done && !syncStatus?.error">
                ok: {{ syncStatus.imageCount }} images and
                {{ syncStatus.templateCount }} templates synced
              </template>
            </div>
            <FormError v-if="syncStatus?.error" :message="syncStatus.error" />
            <FormError v-if="error" :message="error" />
            <div class="actions">
              <div class="spacer"></div>
              <AppButton
                v-if="!syncStatus || syncStatus.error"
                variant="primary"
                :loading="loading"
                loading-text="Syncing..."
                @click="startSync"
              >
                Sync catalog
              </AppButton>
              <AppButton v-if="!syncStatus" variant="ghost" @click="nextStep">Skip</AppButton>
              <AppButton
                v-if="syncStatus?.done && !syncStatus?.error"
                variant="primary"
                @click="nextStep"
              >
                Continue
              </AppButton>
            </div>
          </div>

          <!-- Ready (create path) -->
          <div v-if="panel === 'ready'" class="pane">
            <div class="eyebrow">Step 04 — Ready</div>
            <h1>All Set!</h1>
            <p class="sub">Commissioning complete. This {{ DEVICE_LABEL }} is operational.</p>
            <div class="result">
              <div class="badge">&#10003;</div>
              <div>
                <div class="t">{{ DEVICE_LABEL }} commissioned</div>
                <div class="d">Admin account active · catalog state recorded below</div>
              </div>
            </div>
            <div class="kv">
              <div>
                home&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span class="v">created</span>
              </div>
              <div>
                device&nbsp;&nbsp;&nbsp;<span class="v">this machine (primary)</span>
              </div>
              <div>
                catalog&nbsp;&nbsp;<span class="v">{{ catalogSummary }}</span>
              </div>
            </div>
            <FormError v-if="error" :message="error" />
            <div class="actions">
              <div class="spacer"></div>
              <AppButton
                variant="primary"
                :loading="loading"
                loading-text="Finishing..."
                @click="finishSetup"
              >
                Launch Dashboard
              </AppButton>
            </div>
          </div>

        </div>
      </div>

      <!-- Ops ticker -->
      <div class="ticker">
        <span class="cell live">DAEMON UP</span>
        <span class="cell">HOME <span class="v">—</span></span>
        <span class="cell">DEVICE <span class="v">unassigned</span></span>
        <span class="cell grow"></span>
        <span class="cell">QEMU <span class="v">10.0.2</span></span>
        <span class="cell">BARKVISOR <span class="v">v0.4.1</span></span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.setup-page {
  --s-bg: var(--bg);
  --s-panel: var(--panel, rgba(255, 255, 255, 0.03));
  --s-line: var(--line, rgba(255, 255, 255, 0.07));
  --s-text: var(--text);
  --s-dim: var(--text-dim);
  --s-accent: var(--accent);
  --s-green: var(--green);
  --s-red: var(--red);
  --s-amber: var(--amber);
  --s-radius: var(--radius, 2px);
  --s-mono: ui-monospace, 'SF Mono', Menlo, monospace;
  --s-input-bg: var(--bg-input);
  --s-console-bg: rgba(0, 0, 0, 0.3);
  --s-choice-hover: rgba(0, 144, 248, 0.04);
  --s-current-bg: rgba(0, 144, 248, 0.06);

  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--s-bg);
  color: var(--s-text);
  font-size: 14px;
  line-height: 1.5;
  padding: 24px 0;
}

:root[data-theme='light'] .setup-page {
  --s-panel: rgba(255, 255, 255, 0.85);
  --s-line: rgba(0, 0, 0, 0.1);
  --s-input-bg: rgba(255, 255, 255, 0.95);
  --s-console-bg: rgba(0, 0, 0, 0.04);
  --s-choice-hover: rgba(0, 120, 212, 0.06);
  --s-current-bg: rgba(0, 120, 212, 0.08);
}

.shell {
  width: min(880px, 94vw);
}

/* Header */
.topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 14px;
}
.topbar svg {
  display: block;
}
.topbar .name {
  font-weight: 700;
  font-size: 15px;
  letter-spacing: 0.01em;
}
.topbar .tag {
  font-family: var(--s-mono);
  font-size: 10.5px;
  color: var(--s-dim);
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  padding: 2px 7px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
.topbar .spacer {
  flex: 1;
}
.topbar .session {
  font-family: var(--s-mono);
  font-size: 11px;
  color: var(--s-dim);
}
.topbar .session b {
  color: var(--s-amber);
  font-weight: 500;
}

/* Card: rail + content */
.card {
  display: flex;
  background: var(--s-panel);
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  min-height: 520px;
}

/* Checklist rail */
.rail {
  width: 264px;
  flex: 0 0 auto;
  border-right: 1px solid var(--s-line);
  padding: 22px 0;
  display: flex;
  flex-direction: column;
}
.rail-head {
  font-family: var(--s-mono);
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--s-dim);
  padding: 0 22px 14px;
  border-bottom: 1px solid var(--s-line);
  margin-bottom: 8px;
}
.item {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 13px 22px;
  border-left: 2px solid transparent;
  transition:
    background 0.15s,
    border-color 0.15s;
}
.item.current {
  background: var(--s-current-bg);
  border-left-color: var(--s-accent);
}
.item .box {
  width: 17px;
  height: 17px;
  flex: 0 0 auto;
  margin-top: 2px;
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  display: flex;
  align-items: center;
  justify-content: center;
  transition:
    border-color 0.2s,
    background 0.2s;
}
.item .box svg {
  width: 10px;
  height: 10px;
  stroke: var(--s-green);
  stroke-width: 2.4;
  fill: none;
  stroke-linecap: round;
  stroke-linejoin: round;
  stroke-dasharray: 16;
  stroke-dashoffset: 16;
}
.item.done .box {
  border-color: rgba(52, 211, 153, 0.5);
  background: rgba(52, 211, 153, 0.1);
}
.item.done .box svg {
  animation: draw 0.35s ease-out forwards;
}
@keyframes draw {
  to {
    stroke-dashoffset: 0;
  }
}
.item .num {
  font-family: var(--s-mono);
  font-size: 10.5px;
  color: var(--s-dim);
  letter-spacing: 0.08em;
  margin-bottom: 2px;
}
.item .t {
  font-size: 13px;
  font-weight: 600;
  color: var(--s-dim);
  transition: color 0.15s;
}
.item.current .t,
.item.done .t {
  color: var(--s-text);
}
.item .st {
  display: flex;
  align-items: center;
  gap: 6px;
  font-family: var(--s-mono);
  font-size: 10px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--s-dim);
  margin-top: 3px;
}
.dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--s-dim);
  opacity: 0.5;
}
.item.current .dot {
  background: var(--s-accent);
  opacity: 1;
  animation: pulse 1.6s infinite;
}
.item.current .st {
  color: var(--s-accent);
}
.item.done .dot {
  background: var(--s-green);
  opacity: 1;
}
.item.done .st {
  color: var(--s-green);
}
@keyframes pulse {
  0%,
  100% {
    box-shadow: 0 0 0 0 rgba(0, 144, 248, 0.4);
  }
  50% {
    box-shadow: 0 0 0 4px rgba(0, 144, 248, 0);
  }
}
.rail-foot {
  margin-top: auto;
  padding: 14px 22px 0;
  border-top: 1px solid var(--s-line);
  font-family: var(--s-mono);
  font-size: 10.5px;
  color: var(--s-dim);
  line-height: 1.8;
}
.rail-foot .v {
  color: var(--s-text);
}

/* Content pane */
.content {
  flex: 1;
  padding: 34px 40px 28px;
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.pane {
  flex: 1;
  display: flex;
  flex-direction: column;
}
.pane form {
  flex: 1;
  display: flex;
  flex-direction: column;
}

.eyebrow {
  font-family: var(--s-mono);
  font-size: 10.5px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--s-accent);
  margin-bottom: 8px;
}
.pane h1 {
  font-size: 19px;
  font-weight: 600;
  letter-spacing: -0.01em;
  margin-bottom: 6px;
}
.sub {
  color: var(--s-dim);
  font-size: 13px;
  margin-bottom: 26px;
}

/* Choice cards */
.choice {
  display: flex;
  align-items: center;
  gap: 14px;
  width: 100%;
  text-align: left;
  background: transparent;
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  padding: 15px 18px;
  margin-bottom: 10px;
  cursor: pointer;
  color: var(--s-text);
  font-family: inherit;
  font-size: inherit;
  transition:
    border-color 0.15s,
    background 0.15s;
}
.choice:hover {
  border-color: var(--s-accent);
  background: var(--s-choice-hover);
}
.choice:focus-visible {
  outline: 2px solid var(--s-accent);
  outline-offset: 2px;
}
.choice .cid {
  font-family: var(--s-mono);
  font-size: 11px;
  color: var(--s-dim);
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  padding: 4px 7px;
  flex: 0 0 auto;
}
.choice:hover .cid {
  color: var(--s-accent);
  border-color: rgba(0, 144, 248, 0.4);
}
.choice .t {
  font-weight: 600;
  font-size: 13.5px;
  margin-bottom: 2px;
}
.choice .d {
  color: var(--s-dim);
  font-size: 12px;
}

/* Form */
.field {
  margin-bottom: 16px;
}
.field label {
  display: block;
  font-family: var(--s-mono);
  font-size: 10.5px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--s-dim);
  margin-bottom: 6px;
}
.field input[type='text'],
.field input[type='password'],
.field textarea {
  width: 100%;
  background: var(--s-input-bg);
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  color: var(--s-text);
  font-family: inherit;
  font-size: 13.5px;
  padding: 9px 12px;
  transition:
    border-color 0.15s,
    box-shadow 0.15s;
}
.field input:focus,
.field textarea:focus {
  outline: none;
  border-color: var(--s-accent);
  box-shadow: 0 0 0 3px rgba(0, 144, 248, 0.15);
}
.field input::placeholder,
.field textarea::placeholder {
  color: var(--s-dim);
}
.field textarea {
  resize: vertical;
  min-height: 104px;
  font-family: var(--s-mono);
  font-size: 12px;
  line-height: 1.6;
}
.hint {
  font-size: 11.5px;
  color: var(--s-dim);
  margin-top: 5px;
  font-family: var(--s-mono);
  min-height: 14px;
}
.hint.err {
  color: var(--s-red);
}
.hint.ok {
  color: var(--s-green);
}

/* Sync console */
.console {
  background: var(--s-console-bg);
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  padding: 14px 16px;
  font-family: var(--s-mono);
  font-size: 11.5px;
  line-height: 1.9;
  color: var(--s-dim);
  min-height: 108px;
  margin-bottom: 14px;
}
.console .ln {
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.console .ok {
  color: var(--s-green);
}
.console .ac {
  color: var(--s-accent);
}
.console .am {
  color: var(--s-amber);
}
.console .err {
  color: var(--s-red);
}
.sync-progress {
  margin-bottom: 8px;
}
.sync-status {
  font-family: var(--s-mono);
  font-size: 11.5px;
  color: var(--s-dim);
  min-height: 18px;
  margin-bottom: 8px;
}
.sync-status.ok {
  color: var(--s-green);
}

/* Success block */
.result {
  border: 1px solid rgba(52, 211, 153, 0.3);
  background: rgba(52, 211, 153, 0.05);
  border-radius: var(--s-radius);
  padding: 18px 20px;
  display: flex;
  align-items: center;
  gap: 14px;
  margin-bottom: 8px;
}
.result .badge {
  width: 34px;
  height: 34px;
  flex: 0 0 auto;
  border-radius: 50%;
  border: 1px solid rgba(52, 211, 153, 0.4);
  background: rgba(52, 211, 153, 0.1);
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--s-green);
  font-size: 16px;
}
.result .t {
  font-weight: 600;
  font-size: 14px;
}
.result .d {
  color: var(--s-dim);
  font-size: 12px;
  margin-top: 1px;
}

.kv {
  font-family: var(--s-mono);
  font-size: 11.5px;
  color: var(--s-dim);
  line-height: 2;
  margin-top: 12px;
}
.kv .v {
  color: var(--s-text);
}

/* Actions */
.actions {
  display: flex;
  align-items: center;
  margin-top: auto;
  padding-top: 24px;
  gap: 12px;
}
.actions .spacer {
  flex: 1;
}

/* Ops ticker footer */
.ticker {
  display: flex;
  align-items: center;
  margin-top: 14px;
  border: 1px solid var(--s-line);
  border-radius: var(--s-radius);
  background: var(--s-panel);
  font-family: var(--s-mono);
  font-size: 10.5px;
  letter-spacing: 0.05em;
  color: var(--s-dim);
  overflow: hidden;
}
.ticker .cell {
  padding: 8px 14px;
  border-right: 1px solid var(--s-line);
  white-space: nowrap;
}
.ticker .cell:last-child {
  border-right: none;
}
.ticker .v {
  color: var(--s-text);
}
.ticker .live {
  color: var(--s-green);
  display: flex;
  align-items: center;
  gap: 6px;
}
.ticker .live::before {
  content: '';
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--s-green);
  animation: pulse 1.6s infinite;
}
.ticker .grow {
  flex: 1;
}

@media (max-width: 720px) {
  .card {
    flex-direction: column;
  }
  .rail {
    width: 100%;
    border-right: none;
    border-bottom: 1px solid var(--s-line);
  }
}
</style>
