<script setup lang="ts">
import { ref, onMounted } from 'vue'
import api from '../api/client'

interface License {
  name: string
  license: string
  url: string
  description: string
}

const version = ref('')
const licenses = ref<License[]>([])
const expanded = ref<string | null>(null)

onMounted(async () => {
  const { data } = await api.get('/system/about')
  version.value = data.version
  licenses.value = data.licenses
})

function toggle(name: string) {
  expanded.value = expanded.value === name ? null : name
}
</script>

<template>
  <div class="page-header">
    <h1>About BarkVisor</h1>
  </div>

  <div class="card" style="margin-bottom:20px">
    <div class="detail-grid">
      <div class="detail-row">
        <span class="detail-label">Version</span>
        <span class="badge badge-accent">{{ version || '...' }}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Platform</span>
        <span>macOS (Apple Silicon)</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Backend</span>
        <span>Swift / Vapor</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Virtualizer</span>
        <span>QEMU with HVF acceleration</span>
      </div>
    </div>
  </div>

  <div style="margin-bottom:12px">
    <h2 style="font-size:16px;font-weight:700">Open Source Licenses</h2>
    <p style="font-size:12px;color:var(--text-dim);margin-top:4px">
      BarkVisor is built with the following open source components.
    </p>
  </div>

  <div class="gpl-notice">
    BarkVisor includes QEMU, which is free software licensed under the
    <strong>GNU General Public License version 2</strong>.
    Source code is available at <a href="https://www.qemu.org/" target="_blank" style="color:var(--accent)">qemu.org</a>.
  </div>

  <div style="background:var(--bg-card);backdrop-filter:var(--glass-blur);border:1px solid var(--border-glass);border-radius:var(--radius);overflow:hidden">
    <div v-for="lib in licenses" :key="lib.name" class="license-item" @click="toggle(lib.name)">
      <div class="license-header">
        <div>
          <strong>{{ lib.name }}</strong>
          <span class="badge badge-gray" style="margin-left:8px">{{ lib.license }}</span>
        </div>
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
          :style="{ transform: expanded === lib.name ? 'rotate(180deg)' : 'rotate(0)', transition: 'transform 0.2s' }">
          <polyline points="6 9 12 15 18 9"/>
        </svg>
      </div>
      <div v-if="expanded === lib.name" class="license-detail">
        <p>{{ lib.description }}</p>
        <a :href="lib.url" target="_blank" style="color:var(--accent);font-size:12px">{{ lib.url }}</a>
      </div>
    </div>
  </div>
</template>

<style scoped>
.detail-grid { display: flex; flex-direction: column; }
.detail-row {
  display: flex; align-items: center; padding: 12px 0;
  border-bottom: 1px solid var(--border-subtle);
}
.detail-row:last-child { border-bottom: none; }
.detail-label {
  width: 140px; flex-shrink: 0; font-size: 12px; font-weight: 600;
  color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.04em;
}
.gpl-notice {
  background: rgba(99, 102, 241, 0.08);
  border: 1px solid rgba(99, 102, 241, 0.2);
  border-radius: var(--radius);
  padding: 12px 16px;
  font-size: 13px;
  color: var(--text-secondary);
  margin-bottom: 16px;
}
.license-item {
  padding: 12px 16px;
  border-bottom: 1px solid var(--border-subtle);
  cursor: pointer;
}
.license-item:last-child { border-bottom: none; }
.license-item:hover { background: var(--bg-hover); }
.license-header {
  display: flex; justify-content: space-between; align-items: center;
}
.license-detail {
  margin-top: 8px; padding-top: 8px;
  border-top: 1px solid var(--border-subtle);
  font-size: 13px; color: var(--text-secondary);
}
.license-detail p { margin-bottom: 4px; }
</style>
