<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import AppButton from '../components/ui/AppButton.vue'
import FormError from '../components/ui/FormError.vue'
import { isPasskeyAvailable } from '../utils/webauthn'

const auth = useAuthStore()
const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref('')
const loading = ref(false)
const passkeyLoading = ref(false)
const showPasskey = isPasskeyAvailable()

async function submit() {
  error.value = ''
  loading.value = true
  try {
    await auth.login(username.value, password.value)
    router.push('/vms')
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Login failed')
  } finally {
    loading.value = false
  }
}

async function signInWithPasskey() {
  error.value = ''
  passkeyLoading.value = true
  try {
    await auth.loginWithPasskey()
    router.push('/vms')
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Passkey sign-in failed')
  } finally {
    passkeyLoading.value = false
  }
}
</script>

<template>
  <div class="login-page">
    <div class="login-shell">
      <div class="login-topbar">
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
        <span class="login-tag">Web console</span>
      </div>
      <form class="login-card" @submit.prevent="submit">
        <div class="login-eyebrow">Operator sign-in</div>
        <h1>BarkVisor</h1>
        <p class="login-subtitle">
          Virtual machines, devices, and local models — one console for your Home.
        </p>
        <div class="form-group">
          <label for="login-username">Username</label>
          <input
            id="login-username"
            v-model="username"
            type="text"
            autofocus
            placeholder="admin"
            autocomplete="username"
            required
          />
        </div>
        <div class="form-group">
          <label for="login-password">Password</label>
          <input
            id="login-password"
            v-model="password"
            type="password"
            placeholder="password"
            autocomplete="current-password"
            required
          />
        </div>
        <FormError v-if="error" class="login-error" :message="error" />
        <AppButton
          variant="primary"
          class="login-btn"
          :loading="loading"
          loading-text="Signing in..."
        >Sign In</AppButton>
        <template v-if="showPasskey">
          <p class="login-or">or</p>
          <AppButton
            type="button"
            icon="key"
            class="login-btn"
            :loading="passkeyLoading"
            loading-text="Waiting for passkey..."
            @click="signInWithPasskey"
          >Sign in with passkey</AppButton>
        </template>
      </form>
      <div class="login-foot">Made with ❤️ in SF</div>
    </div>
  </div>
</template>

<style scoped>
.login-page {
  --l-mono: ui-monospace, 'SF Mono', Menlo, monospace;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  padding: 32px 20px;
  background:
    radial-gradient(1000px 480px at 78% -12%, var(--main-gradient-1), transparent 65%),
    radial-gradient(820px 420px at 6% 108%, var(--main-gradient-2), transparent 60%),
    var(--bg);
}
.login-shell {
  width: min(400px, 100%);
}
.login-topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 14px;
  padding: 0 2px;
}
.login-topbar svg {
  display: block;
}
.login-tag {
  font-family: var(--l-mono);
  font-size: 10.5px;
  color: var(--text-dim);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 2px 7px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
.login-card {
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur-lg);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  box-shadow: var(--shadow-lg);
  padding: 30px 32px 28px;
}
.login-eyebrow {
  font-family: var(--l-mono);
  font-size: 10.5px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--accent);
  margin-bottom: 8px;
}
.login-card h1 {
  font-size: 26px;
  font-weight: 700;
  letter-spacing: -0.02em;
  margin-bottom: 6px;
}
.login-subtitle {
  color: var(--text-dim);
  font-size: 13px;
  margin-bottom: 24px;
}
.login-card input:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 3px var(--accent-glow);
}
.login-btn {
  width: 100%;
  height: 40px;
  font-size: 13.5px;
  margin-top: 4px;
}
.login-or {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 16px 0 12px;
  color: var(--text-dim);
  font-family: var(--l-mono);
  font-size: 10.5px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}
.login-or::before,
.login-or::after {
  content: '';
  flex: 1;
  height: 1px;
  background: var(--line);
}
.login-foot {
  margin-top: 14px;
  text-align: center;
  font-family: var(--l-mono);
  font-size: 10.5px;
  letter-spacing: 0.05em;
  color: var(--text-dim);
}
@media (max-width: 480px) {
  .login-page {
    padding: 24px 16px;
  }
  .login-card {
    padding: 24px 20px;
  }
}
</style>
