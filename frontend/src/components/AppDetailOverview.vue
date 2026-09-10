<script setup lang="ts">
import { computed } from 'vue'
import type { VM } from '../api/types'
import { firstOpenUrl } from '../utils/workloadKind'
import { shortDigest } from '../utils/composeLogs'
import { parseComposeMounts } from '../utils/composeMounts'
import { appCatalogSource, appEnvSummary, appIngressMode } from '../utils/appDetail'

const props = defineProps<{ vm: VM }>()

const openUi = computed(() => firstOpenUrl(props.vm))
const catalog = computed(() => appCatalogSource(props.vm))
const mounts = computed(() => parseComposeMounts(props.vm.spec?.spec?.compose ?? ''))
const env = computed(() => appEnvSummary(props.vm))
const ingress = computed(() => appIngressMode(props.vm))
const ports = computed(() => props.vm.publishedPorts ?? [])
const roots = computed(() => (props.vm.volumeRoots ?? []).filter(Boolean))
</script>

<template>
  <div class="app-detail-cards">
    <section class="sheet">
      <div class="sheet-head">
        <h3>Status</h3>
        <span v-if="vm.updateAvailable" class="status-pill degraded">Update available</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">State</span>
        <span class="mono">{{ vm.state }}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Image</span>
        <span class="mono">{{ vm.image || '—' }}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Digest</span>
        <span class="mono">{{ shortDigest(vm.digest) || '—' }}</span>
      </div>
      <div v-if="catalog" class="detail-row">
        <span class="detail-label">Catalog</span>
        <span class="badge badge-gray">{{ catalog }}</span>
      </div>
    </section>

    <section class="sheet">
      <div class="sheet-head"><h3>Access</h3></div>
      <div v-if="openUi" class="detail-row">
        <span class="detail-label">Open UI</span>
        <a :href="openUi" target="_blank" rel="noopener" class="mono">{{ openUi }}</a>
      </div>
      <div v-else class="detail-row">
        <span class="detail-label">Open UI</span>
        <span class="dim-text">Start the app to open the UI</span>
      </div>
      <table v-if="ports.length" class="app-ports">
        <thead>
          <tr>
            <th>Bind</th>
            <th>Host</th>
            <th></th>
            <th>Container</th>
            <th>Proto</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="p in ports" :key="`${p.hostPort}-${p.proto}`">
            <td class="mono">0.0.0.0</td>
            <td class="mono">{{ p.hostPort }}</td>
            <td class="dim-text">→</td>
            <td class="mono">{{ p.containerPort }}</td>
            <td class="mono">{{ p.proto }}</td>
          </tr>
        </tbody>
      </table>
      <p class="dim-text app-ports-note">Port bindings are informational — reach the app via the LAN address above.</p>
      <div class="detail-row">
        <span class="detail-label">Ingress</span>
        <span class="badge" :class="ingress.direct ? 'badge-green' : 'badge-blue'">{{ ingress.label }}</span>
      </div>
      <p class="dim-text">{{ ingress.reason }}</p>
    </section>

    <section class="sheet">
      <div class="sheet-head"><h3>Storage</h3></div>
      <div v-if="mounts.length === 0 && roots.length === 0" class="dim-text">No mounts recorded.</div>
      <div v-for="(m, i) in mounts" :key="i" class="detail-row">
        <span class="badge" :class="m.kind === 'bind' ? 'badge-blue' : 'badge-green'">{{ m.kind }}</span>
        <span class="mono">{{ m.source }} → {{ m.target }}</span>
      </div>
      <div v-if="roots.length" class="detail-row">
        <span class="detail-label">Volume roots</span>
        <span class="mono">{{ roots[0] }}</span>
      </div>
    </section>

    <section class="sheet">
      <div class="sheet-head"><h3>Environment</h3></div>
      <div class="detail-row">
        <span class="detail-label">Variables</span>
        <span>{{ env.count }} configured</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Secrets</span>
        <span class="dim-text">{{ env.secrets }} hidden — values never displayed</span>
      </div>
      <p v-if="catalog" class="dim-text">Variables are managed by the {{ catalog }} template. Edit in the Environment tab.</p>
    </section>
  </div>
</template>

<style scoped>
.app-detail-cards {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.app-ports {
  width: 100%;
  border-collapse: collapse;
  font-size: 12.5px;
  margin: 8px 0;
}
.app-ports th {
  text-align: left;
  font-size: 10.5px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-dim);
  padding: 5px 8px;
  border-bottom: 1px solid var(--line, var(--border));
}
.app-ports td {
  padding: 6px 8px;
  border-bottom: 1px solid var(--line, var(--border));
  color: var(--text-secondary);
}
.app-ports-note {
  margin: 0 0 8px;
  padding: 0 8px;
}
.sheet { padding-bottom: 8px; }
.sheet .detail-row { padding: 10px 14px; }
@media (max-width: 900px) {
  .app-detail-cards { grid-template-columns: 1fr; }
}
</style>
