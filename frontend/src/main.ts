import { createApp } from 'vue'
import { createPinia } from 'pinia'
import router from './router'
import App from './App.vue'
import './style.css'
import { useToastStore } from './stores/toast'
import { setUnauthorizedHandler, setSetupRequiredHandler } from './api/client'

const app = createApp(App)
const pinia = createPinia()
app.use(pinia)
app.use(router)

// Initialize theme from localStorage (applies data-theme attribute before first paint)
import { useThemeStore } from './stores/theme'
useThemeStore()

// Soft redirect on 401 (preserves SPA state instead of full page reload)
setUnauthorizedHandler(() => {
  if (router.currentRoute.value.name !== 'login') {
    router.push({ name: 'login' })
  }
})

// Redirect to setup wizard when server is in setup mode
setSetupRequiredHandler(() => {
  if (router.currentRoute.value.name !== 'setup') {
    router.push({ name: 'setup' })
  }
})

// Report errors to server for persistent logging
function reportError(payload: Record<string, string>) {
  const token = localStorage.getItem('token')
  if (!token) return
  fetch('/api/logs/client-error', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(payload),
  }).catch(() => {}) // Don't recurse on failure
}

// Global error handler — catches unhandled errors in components
app.config.errorHandler = (err: unknown, _instance, info) => {
  console.error('[BarkVisor] Unhandled error:', err)
  const toast = useToastStore()
  const message = err instanceof Error ? err.message : 'An unexpected error occurred'
  toast.error(message)
  reportError({
    error: String(err),
    component: info || '',
    stack: err instanceof Error ? (err.stack || '') : '',
    type: 'vue-error',
  })
}

// Catch unhandled promise rejections
window.addEventListener('unhandledrejection', (event) => {
  console.error('[BarkVisor] Unhandled rejection:', event.reason)
  reportError({
    error: String(event.reason),
    type: 'unhandledrejection',
  })
})

app.mount('#app')
