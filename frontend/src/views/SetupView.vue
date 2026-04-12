<script setup lang="ts">
import { ref, onMounted } from 'vue'
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
} from '../api/setup'
import { useAuthStore } from '../stores/auth'
import { clearSetupCache } from '../router'

const router = useRouter()
const authStore = useAuthStore()
const step = ref(1)
const totalSteps = 5
const error = ref('')
const loading = ref(false)

// Step 2: Admin
const username = ref('admin')
const password = ref('')
const passwordConfirm = ref('')

// Step 3: Bridge
const interfaces = ref<InterfaceInfo[]>([])
const selectedInterface = ref('')
const bridgeResult = ref('')

// Step 4: Repo sync
const syncStatus = ref<RepoSyncStatus | null>(null)
let syncPollInterval: ReturnType<typeof setInterval> | null = null

onMounted(async () => {
  try {
    const status = await getSetupStatus()
    if (status.complete) {
      router.replace('/login')
    }
  } catch {
    // Server may not be ready yet
  }
})

function nextStep() {
  error.value = ''
  step.value++
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
    nextStep()
  } catch (e: any) {
    error.value = e.response?.data?.reason || 'Failed to create admin user'
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
    error.value = e.response?.data?.reason || 'Failed to install bridge'
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
    error.value = e.response?.data?.reason || 'Failed to start sync'
    loading.value = false
  }
}

// Step 5: Complete — auto-login and redirect to dashboard
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
    error.value = e.response?.data?.reason || 'Failed to complete setup'
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

      <!-- Step 1: Welcome -->
      <div v-if="step === 1" class="step-content">
        <h1>Welcome to BarkVisor</h1>
        <p class="step-desc">
          Let's get your virtual machine server set up. This will only take a minute.
        </p>
        <AppButton variant="primary" class="step-btn" @click="nextStep">Get Started</AppButton>
      </div>

      <!-- Step 2: Admin credentials -->
      <div v-if="step === 2" class="step-content">
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

      <!-- Step 3: Bridge setup -->
      <div v-if="step === 3" class="step-content" @vue:mounted="loadInterfaces">
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

      <!-- Step 4: Repository sync -->
      <div v-if="step === 4" class="step-content">
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

      <!-- Step 5: Ready -->
      <div v-if="step === 5" class="step-content">
        <h2>All Set!</h2>
        <p class="step-desc">
          BarkVisor is ready. You'll be signed in automatically and taken to the dashboard.
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
.select-input {
  width: 100%;
  padding: 8px 10px;
  background: var(--bg-input, var(--bg));
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm, 6px);
  font-size: 13px;
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
