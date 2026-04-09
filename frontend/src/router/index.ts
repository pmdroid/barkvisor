import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/setup', name: 'setup', component: () => import('../views/SetupView.vue') },
    { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
    { path: '/', redirect: '/dashboard' },
    { path: '/dashboard', name: 'dashboard', component: () => import('../views/DashboardView.vue') },
    { path: '/vms', name: 'vms', component: () => import('../views/VMListView.vue') },
    { path: '/vms/:id', name: 'vm-detail', component: () => import('../views/VMDetailView.vue') },
    { path: '/images', name: 'images', component: () => import('../views/ImageLibraryView.vue') },
    { path: '/disks', name: 'disks', component: () => import('../views/DiskView.vue') },
    { path: '/networks', name: 'networks', component: () => import('../views/NetworkView.vue') },
    { path: '/registry', name: 'registry', component: () => import('../views/RegistryView.vue') },
    { path: '/logs', name: 'logs', component: () => import('../views/LogView.vue') },
    { path: '/settings', name: 'settings', component: () => import('../views/SettingsView.vue') },
    { path: '/:pathMatch(.*)*', name: 'not-found', redirect: '/dashboard' },
  ],
})

function isTokenExpired(token: string): boolean {
  try {
    const payload = JSON.parse(atob(token.split('.')[1]))
    return payload.exp * 1000 < Date.now()
  } catch {
    return true
  }
}

// Track setup state (checked once, then cached for the session)
let setupChecked = false
let setupRequired = false

export async function checkSetupRequired(): Promise<boolean> {
  if (setupChecked) return setupRequired
  try {
    const res = await fetch('/api/setup/status')
    if (res.ok) {
      const data = await res.json()
      setupRequired = !data.complete
    }
  } catch {
    // Server may not be ready
  }
  setupChecked = true
  return setupRequired
}

/** Call after setup completes to clear the cached state */
export function clearSetupCache() {
  setupChecked = false
  setupRequired = false
}

router.beforeEach(async (to) => {
  // Check if setup is required (first navigation only, then cached)
  const needsSetup = await checkSetupRequired()

  if (needsSetup) {
    // Only allow the setup page
    if (to.name !== 'setup') return { name: 'setup' }
    return
  }

  // Setup done — don't allow navigating to setup page
  if (to.name === 'setup') return { name: 'login' }

  // Normal auth guard
  if (to.name === 'login') return
  const token = localStorage.getItem('token')
  if (!token || isTokenExpired(token)) {
    localStorage.removeItem('token')
    return { name: 'login' }
  }
})

export default router
