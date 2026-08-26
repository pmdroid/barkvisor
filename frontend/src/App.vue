<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useAuthStore } from './stores/auth'
import { useDevicesStore } from './stores/devices'
import { useDeviceScopeStore } from './stores/deviceScope'
import { useOllamaStore } from './stores/ollama'
import { useThemeStore } from './stores/theme'
import { chatIsVisible } from './utils/chatCompletions'
import { DEVICE_SCOPE_ALL } from './utils/deviceScope'
import { isReachabilityOk } from './utils/homeDeviceHealth'
import { DEVICE_LABEL, HOME_LABEL } from './utils/terminology'
import ToastContainer from './components/ToastContainer.vue'

const route = useRoute()
const auth = useAuthStore()
const themeStore = useThemeStore()
const ollama = useOllamaStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const mobileMenuOpen = ref(false)

const tickerDevice = computed(() =>
  deviceScope.isAll ? null : devices.deviceByHostId(deviceScope.selectedHostId),
)
const tickerLabel = computed(() =>
  tickerDevice.value ? devices.deviceLabel(tickerDevice.value) : HOME_LABEL,
)
const tickerCounts = computed(() => {
  const row = tickerDevice.value
  if (row) {
    return {
      running: row.healthCounts?.running ?? 0,
      failed: row.healthCounts?.failed ?? 0,
      stopped: row.healthCounts?.stopped ?? 0,
      unreachable: isReachabilityOk(row.reachability) ? 0 : 1,
    }
  }
  const counts = devices.totals?.healthCounts
  return {
    running: counts?.running ?? 0,
    failed: counts?.failed ?? 0,
    stopped: counts?.stopped ?? 0,
    unreachable: devices.totals?.unreachable ?? 0,
  }
})

onMounted(() => {
  if (auth.isAuthenticated) {
    void auth.fetchMe()
    void ollama.fetchCatalog()
    void devices.fetchHealth()
  }
})
watch(
  () => auth.isAuthenticated,
  (ok) => {
    if (ok) {
      void ollama.fetchCatalog()
      void devices.fetchHealth()
    }
  },
)
watch(
  () => devices.devices.map((row) => row.hostId),
  (hostIds) => {
    deviceScope.forgetUnknownHost(hostIds)
  },
)

// Close mobile menu on navigation
watch(() => route.path, () => { mobileMenuOpen.value = false })

function isActive(path: string) {
  if (path === '/vms') return route.path === '/vms' || /\/vms(\/|$)/.test(route.path)
  if (path === '/devices') {
    if (/\/vms(\/|$)/.test(route.path)) return false
    return route.path.startsWith('/devices')
  }
  return route.path.startsWith(path)
}
</script>

<template>
  <div v-if="route.name === 'login' || route.name === 'setup' || route.name === 'vm-vnc' || route.meta.bare">
    <router-view />
  </div>
  <div v-else class="layout">
    <aside class="sidebar" :class="{ 'mobile-open': mobileMenuOpen }">
      <div class="sidebar-header">
        <svg class="sidebar-logo" width="22" height="22" viewBox="0 0 22 22" aria-hidden="true"><rect width="22" height="22" rx="4" fill="#0090f8"/><path d="M6.5 9v4M10 6.5v9M13.5 9.5v3M17 7.5v7" stroke="#fff" stroke-width="1.7" stroke-linecap="round" fill="none"/></svg>
        <span class="sidebar-title">BarkVisor</span>
        <button class="mobile-menu-toggle" @click="mobileMenuOpen = !mobileMenuOpen" :aria-label="mobileMenuOpen ? 'Close menu' : 'Open menu'">
          <svg v-if="!mobileMenuOpen" class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="20" y2="18"/>
          </svg>
          <svg v-else class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>
      <div class="sidebar-scope">
        <label for="device-scope">{{ DEVICE_LABEL }} scope</label>
        <select
          id="device-scope"
          :value="deviceScope.selectedHostId"
          @change="deviceScope.select(($event.target as HTMLSelectElement).value)"
        >
          <option :value="DEVICE_SCOPE_ALL">All</option>
          <option
            v-for="row in devices.devices"
            :key="row.hostId"
            :value="row.hostId"
          >{{ devices.deviceLabel(row) }}</option>
        </select>
      </div>
      <nav class="sidebar-nav">
        <router-link v-if="auth.isAdmin" to="/dashboard" :class="{ active: route.path === '/dashboard' }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/><rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/>
          </svg>
          <span class="nav-label">Dashboard</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/devices" :class="{ active: isActive('/devices') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="2" y="3" width="9" height="7" rx="1"/><rect x="13" y="3" width="9" height="7" rx="1"/>
            <rect x="2" y="14" width="9" height="7" rx="1"/><rect x="13" y="14" width="9" height="7" rx="1"/>
          </svg>
          <span class="nav-label">Devices</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/vms" :class="{ active: isActive('/vms') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/>
          </svg>
          <span class="nav-label">Virtual Machines</span>
        </router-link>
        <router-link v-if="auth.isAdmin || auth.isInference" to="/models" :class="{ active: isActive('/models') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="4" y="4" width="16" height="16" rx="2"/><path d="M9 9h6"/><path d="M9 13h6"/><path d="M9 17h4"/>
          </svg>
          <span class="nav-label">Ollama</span>
        </router-link>
        <router-link v-if="chatIsVisible(ollama.anyReachable, ollama.models.length)" to="/chat" :class="{ active: isActive('/chat') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z"/>
          </svg>
          <span class="nav-label">Chat</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/images" :class="{ active: isActive('/images') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/><path d="M12 2v3"/><path d="M12 19v3"/>
          </svg>
          <span class="nav-label">Images</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/disks" :class="{ active: isActive('/disks') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4.03 3 9 3s9-1.34 9-3"/>
          </svg>
          <span class="nav-label">Disks</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/networks" :class="{ active: isActive('/networks') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/>
          </svg>
          <span class="nav-label">Networks</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/registry" :class="{ active: isActive('/registry') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/>
            <rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/>
          </svg>
          <span class="nav-label">Repositories</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/logs" :class="{ active: isActive('/logs') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/>
          </svg>
          <span class="nav-label">Logs</span>
        </router-link>
        <router-link v-if="auth.isAdmin" to="/settings" :class="{ active: isActive('/settings') }">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/>
          </svg>
          <span class="nav-label">Settings</span>
        </router-link>
      </nav>
      <div class="sidebar-bottom">
        <button @click="themeStore.toggle()" :title="themeStore.theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'">
          <svg v-if="themeStore.theme === 'dark'" class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>
          </svg>
          <svg v-else class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
          </svg>
          <span class="nav-label">{{ themeStore.theme === 'dark' ? 'Light Mode' : 'Dark Mode' }}</span>
        </button>
        <button @click="auth.logout(); $router.push('/login')" title="Logout">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>
          </svg>
          <span class="nav-label">Logout</span>
        </button>
      </div>
      <div class="sidebar-footer">Made with ❤️ in SF</div>
    </aside>
    <main class="main">
      <div class="ops-ticker">
        <span class="ops-ticker-label">{{ tickerLabel }}</span>
        <span class="ops-tick"><span class="ops-dot ok"></span><b>{{ tickerCounts.running }}</b>&nbsp;running</span>
        <span class="ops-tick" :class="{ alert: tickerCounts.failed > 0 }">
          <span class="ops-dot bad" :class="{ pulse: tickerCounts.failed > 0 }"></span><b>{{ tickerCounts.failed }}</b>&nbsp;failed
        </span>
        <span class="ops-tick"><span class="ops-dot off"></span><b>{{ tickerCounts.stopped }}</b>&nbsp;stopped</span>
        <span class="ops-tick" :class="{ 'warn-t': tickerCounts.unreachable > 0 }">
          <span class="ops-dot warn" :class="{ pulse: tickerCounts.unreachable > 0 }"></span><b>{{ tickerCounts.unreachable }}</b>&nbsp;{{ DEVICE_LABEL }} unreachable
        </span>
        <span class="ops-ticker-right"><span class="ops-dot ok pulse"></span>Live</span>
      </div>
      <div class="main-slot">
        <router-view />
      </div>
    </main>
    <ToastContainer />
  </div>
</template>
