<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import AppButton from '../components/ui/AppButton.vue'
import FormError from '../components/ui/FormError.vue'

const auth = useAuthStore()
const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref('')
const loading = ref(false)

async function submit() {
  error.value = ''
  loading.value = true
  try {
    await auth.login(username.value, password.value)
    router.push('/vms')
  } catch (e: any) {
    error.value = e.response?.data?.reason || 'Login failed'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-page">
    <form class="login-card" @submit.prevent="submit">
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
      <FormError v-if="error" :message="error" />
      <AppButton variant="primary" class="login-btn" :loading="loading" loading-text="Signing in...">Sign In</AppButton>
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
.login-card .form-group { text-align: left; }
</style>
