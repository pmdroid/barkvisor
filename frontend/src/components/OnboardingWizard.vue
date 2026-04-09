<script setup lang="ts">
import { ref } from 'vue'
import api from '../api/client'

const emit = defineEmits(['complete'])
const step = ref(1)
const totalSteps = 3
const syncing = ref(false)
const syncDone = ref(false)
const syncError = ref('')

async function syncRepos() {
  syncing.value = true
  syncError.value = ''
  try {
    const { data: repos } = await api.get('/repositories')
    for (const repo of repos) {
      try {
        await api.post(`/repositories/${repo.id}/sync`)
      } catch {}
    }
    syncDone.value = true
  } catch (e: any) {
    syncError.value = e.message || 'Sync failed'
  } finally {
    syncing.value = false
  }
}

async function finish() {
  try {
    await api.post('/system/onboarding/complete')
  } catch {}
  emit('complete')
}
</script>

<template>
  <div class="onboarding-overlay">
    <div class="onboarding-card">

      <!-- Step 1: Welcome -->
      <div v-if="step === 1" class="onboarding-step">
        <img src="/onboarding-hero.png" alt="BarkVisor" style="width:160px;height:160px;object-fit:contain" />
        <h1>Welcome to BarkVisor</h1>
        <p>
          Create and manage virtual machines on your Mac with a simple web interface.
          Run Linux, Windows, and more — powered by QEMU with hardware acceleration.
        </p>
        <div class="onboarding-features">
          <div class="feature">
            <span class="feature-icon">🐧</span>
            <span>Linux VMs with HVF acceleration</span>
          </div>
          <div class="feature">
            <span class="feature-icon">🪟</span>
            <span>Windows 11 with TPM 2.0</span>
          </div>
          <div class="feature">
            <span class="feature-icon">🖥</span>
            <span>VNC display & serial console</span>
          </div>
          <div class="feature">
            <span class="feature-icon">📦</span>
            <span>Cloud images & ISO installers</span>
          </div>
        </div>
      </div>

      <!-- Step 2: Image Repository Sync -->
      <div v-if="step === 2" class="onboarding-step">
        <div class="onboarding-icon">
          <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.5" stroke-linecap="round">
            <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
            <polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>
          </svg>
        </div>
        <h1>Image Catalog</h1>
        <p>
          Sync the image catalog to browse available operating system images —
          including Alpine, Ubuntu, Debian, Fedora, and more.
        </p>
        <div style="margin-top:20px;text-align:center">
          <button v-if="!syncDone" class="btn-primary" :disabled="syncing" @click="syncRepos">
            {{ syncing ? 'Syncing...' : 'Sync Image Catalog' }}
          </button>
          <div v-else style="color:var(--green);font-size:14px;font-weight:500">
            Image catalog synced successfully!
          </div>
          <p v-if="syncError" style="color:var(--red);font-size:12px;margin-top:8px">{{ syncError }}</p>
          <p style="font-size:12px;color:var(--text-dim);margin-top:12px">
            You can also add custom repositories later in Settings.
          </p>
        </div>
      </div>

      <!-- Step 3: Ready -->
      <div v-if="step === 3" class="onboarding-step">
        <div class="onboarding-icon">
          <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="var(--green)" stroke-width="1.5" stroke-linecap="round">
            <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>
          </svg>
        </div>
        <h1>You're All Set!</h1>
        <p>
          BarkVisor is ready. Create your first virtual machine or browse available images
          from the repository.
        </p>
        <div class="onboarding-tips">
          <div class="tip">
            <strong>NAT Networking</strong> works out of the box — VMs can access the internet through your Mac.
          </div>
          <div class="tip">
            <strong>Bridged Networking</strong> gives VMs their own IP on your local network.
            You can set this up later in the Networks section (requires admin password).
          </div>
          <div class="tip">
            <strong>Guest Agent</strong> — install <code>qemu-guest-agent</code> inside Linux VMs
            to see IP addresses, OS info, and filesystem details.
          </div>
        </div>
      </div>

      <!-- Navigation -->
      <div class="onboarding-nav">
        <div class="onboarding-dots">
          <span v-for="s in totalSteps" :key="s" class="dot" :class="{ active: s === step, done: s < step }"></span>
        </div>
        <div style="display:flex;gap:8px">
          <button v-if="step > 1" class="btn-ghost" @click="step--">Back</button>
          <button v-if="step < totalSteps" class="btn-primary" @click="step++">
            {{ step === 2 && !syncDone ? 'Skip' : 'Next' }}
          </button>
          <button v-if="step === totalSteps" class="btn-primary" @click="finish">Get Started</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.onboarding-overlay {
  position: fixed;
  inset: 0;
  background: var(--bg);
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.onboarding-card {
  max-width: 520px;
  width: 100%;
  padding: 40px;
}
.onboarding-step {
  text-align: center;
}
.onboarding-icon {
  margin-bottom: 20px;
}
.onboarding-step h1 {
  font-size: 24px;
  font-weight: 700;
  margin-bottom: 12px;
}
.onboarding-step p {
  color: var(--text-secondary);
  font-size: 14px;
  line-height: 1.6;
}
.onboarding-features {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  margin-top: 24px;
  text-align: left;
}
.feature {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 12px;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius-sm);
  font-size: 13px;
}
.feature-icon { font-size: 18px; }
.onboarding-tips {
  text-align: left;
  margin-top: 20px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.tip {
  padding: 10px 14px;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius-sm);
  font-size: 13px;
  color: var(--text-secondary);
}
.tip strong {
  color: var(--text);
}
.tip code {
  background: var(--bg);
  padding: 1px 5px;
  border-radius: 1px;
  font-size: 12px;
}
.onboarding-nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 32px;
  padding-top: 20px;
  border-top: 1px solid var(--border-subtle);
}
.onboarding-dots {
  display: flex;
  gap: 6px;
}
.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%; /* keep dot circular */
  background: var(--border);
  transition: background 0.2s;
}
.dot.active { background: var(--accent); }
.dot.done { background: var(--green); }
</style>
