<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import AppButton from '../components/ui/AppButton.vue'
import FormError from '../components/ui/FormError.vue'

const auth = useAuthStore()
const router = useRouter()
const username = ref('')
const password = ref('')
const totpCode = ref('')
const challengeToken = ref('')
const error = ref('')
const loading = ref(false)

async function submitPassword() {
  error.value = ''
  loading.value = true
  try {
    const outcome = await auth.login(username.value, password.value)
    password.value = ''
    if (outcome.totpRequired) {
      challengeToken.value = outcome.challengeToken
      totpCode.value = ''
      return
    }
    await router.push('/vms')
  } catch (e: unknown) {
    error.value = apiErrorMessage(e, 'Login failed')
  } finally {
    loading.value = false
  }
}

async function submitChallenge() {
  error.value = ''
  loading.value = true
  try {
    await auth.completeLoginChallenge(challengeToken.value, totpCode.value.trim())
    totpCode.value = ''
    challengeToken.value = ''
    await router.push('/vms')
  } catch (e: unknown) {
    error.value = apiErrorMessage(e, 'Invalid authenticator code')
  } finally {
    loading.value = false
  }
}

function backToPassword() {
  challengeToken.value = ''
  totpCode.value = ''
  error.value = ''
}
</script>

<template>
  <div class="login-page">
    <form v-if="!challengeToken" class="login-card" @submit.prevent="submitPassword">
      <img src="/app-icon.png" class="login-logo" alt="BarkVisor" />
      <h1>BarkVisor</h1>
      <p class="login-subtitle">Sign in to manage your virtual machines</p>
      <div class="form-group">
        <label>Username</label>
        <input v-model="username" type="text" autofocus placeholder="admin" />
      </div>
      <div class="form-group">
        <label>Password</label>
        <input v-model="password" type="password" placeholder="password" />
      </div>
      <FormError v-if="error" class="login-error" :message="error" />
      <AppButton variant="primary" class="login-btn" :loading="loading" loading-text="Signing in...">Sign In</AppButton>
    </form>

    <form v-else class="login-card" @submit.prevent="submitChallenge">
      <img src="/app-icon.png" class="login-logo" alt="BarkVisor" />
      <h1>BarkVisor</h1>
      <p class="login-subtitle">Enter the authenticator code for this Device, or a recovery code.</p>
      <div class="form-group">
        <label>Authenticator code</label>
        <input
          v-model="totpCode"
          type="text"
          inputmode="numeric"
          autocomplete="one-time-code"
          autofocus
          placeholder="123456"
        />
      </div>
      <FormError v-if="error" class="login-error" :message="error" />
      <AppButton variant="primary" class="login-btn" :loading="loading" loading-text="Verifying...">Verify</AppButton>
      <button type="button" class="login-back" :disabled="loading" @click="backToPassword">Back</button>
    </form>
  </div>
</template>

<style scoped>
.login-page {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  background: var(--bg);
}
.login-card {
  width: 400px;
  text-align: center;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur-lg);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 40px 36px;
}
.login-logo {
  width: 64px;
  height: 64px;
  border-radius: 2px;
  object-fit: cover;
  margin: 0 auto 20px;
}
.login-card h1 {
  font-size: 24px;
  font-weight: 700;
  margin-bottom: 6px;
  letter-spacing: -0.02em;
}
.login-subtitle {
  color: var(--text-dim);
  font-size: 13px;
  margin-bottom: 28px;
}
.login-btn {
  width: 100%;
  padding: 11px;
  font-size: 14px;
  margin-top: 4px;
}
.login-back {
  margin-top: 12px;
  background: none;
  border: none;
  color: var(--text-dim);
  cursor: pointer;
  font-size: 13px;
}
.login-card .form-group { text-align: left; }
</style>
