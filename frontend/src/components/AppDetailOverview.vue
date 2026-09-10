<script setup lang="ts">
import { computed } from 'vue'
import type { VM } from '../api/types'
import { firstOpenUrl } from '../utils/workloadKind'
import { shortDigest } from '../utils/composeLogs'
import { parseComposeMounts, mountsFromSharedPaths } from '../utils/composeMounts'
import AppMountList from './AppMountList.vue'
import { appCatalogSource, appEnvSummary, appIngressMode } from '../utils/appDetail'

const props = defineProps<{ vm: VM }>()

const openUi = computed(() => firstOpenUrl(props.vm))
const catalog = computed(() => appCatalogSource(props.vm))
const mounts = computed(() => {
  const fromShared = mountsFromSharedPaths(props.vm.sharedPaths)
  if (fromShared.length) return fromShared
  return parseComposeMounts(props.vm.spec?.spec?.compose ?? '')
})
const env = computed(() => appEnvSummary(props.vm))
const ingress = computed(() => appIngressMode(props.vm))
const ports = computed(() => props.vm.publishedPorts ?? [])
const roots = computed(() => (props.vm.volumeRoots ?? []).filter(Boolean))
const image = computed(() => {
  if (props.vm.image) return props.vm.image
  const m = (props.vm.spec?.spec?.compose ?? '').match(/image:\s*(\S+)/)
  return m?.[1] ?? '—'
})
</script>

<template>
  <div class="app-kimi">
    <div class="cards">
      <section class="card status">
        <div class="card-title">
          Status
          <span v-if="vm.updateAvailable" class="update-badge">Update available</span>
        </div>
        <div class="kv">
          <div class="kv-row">
            <span class="k">State</span>
            <span class="v" :class="{ 'state-running': vm.state === 'running' }">{{ vm.state }}</span>
          </div>
          <div class="kv-row">
            <span class="k">Image</span>
            <span class="v mono">{{ image }}</span>
          </div>
          <div class="kv-row">
            <span class="k">Digest</span>
            <span class="v mono">{{ shortDigest(vm.digest) || '—' }}</span>
          </div>
        </div>
      </section>

      <section class="card access">
        <div class="card-title">Access</div>
        <div v-if="openUi" class="access-url">
          <span class="label">Open UI</span>
          <a :href="openUi" target="_blank" rel="noopener">{{ openUi }}</a>
        </div>
        <div v-else class="access-url">
          <span class="label">Open UI</span>
          <span class="dim">Start the app to open the UI</span>
        </div>
        <table v-if="ports.length" class="ports-table">
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
              <td>0.0.0.0</td>
              <td>{{ p.hostPort }}</td>
              <td class="arrow">→</td>
              <td>{{ p.containerPort }}</td>
              <td>{{ p.proto }}</td>
            </tr>
          </tbody>
        </table>
        <div class="ports-note">Port bindings are informational — reach the app via the LAN address above.</div>
        <div class="ingress-row">
          <span class="label">Ingress</span>
          <span class="chip" :class="ingress.direct ? 'direct' : 'prefix'">{{ ingress.label }}</span>
          <span class="toggle" aria-disabled="true"></span>
          <span class="toggle-state">{{ ingress.direct ? 'Off · inapplicable' : 'On' }}</span>
          <span class="ingress-reason">{{ ingress.reason }}</span>
        </div>
      </section>

      <section class="card storage">
        <div class="card-title">Storage</div>
        <AppMountList :mounts="mounts" :roots="roots" />
      </section>

      <section class="card env">
        <div class="card-title">Environment</div>
        <div class="env-summary">
          <div class="env-count">
            <span class="num">{{ env.count }}</span>
            <span class="unit">variables configured</span>
          </div>
          <div class="secrets-note">
            <span class="lock">🔒</span>
            {{ env.secrets }} secrets hidden — values never displayed
          </div>
          <div v-if="catalog" class="env-hint">
            Catalog app: variables are managed by the {{ catalog }} template. Edit in the Environment tab.
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.app-kimi {
  --k-border: rgba(184, 184, 180, 0.08);
  --k-card: rgba(0, 144, 248, 0.05);
  --k-surface: rgba(0, 144, 248, 0.03);
}
.cards {
  display: grid;
  grid-template-columns: repeat(12, 1fr);
  gap: 14px;
  margin-bottom: 8px;
}
.card {
  background: var(--k-card);
  border: 1px solid var(--k-border);
  border-radius: var(--radius);
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.25);
  padding: 16px 18px;
  min-width: 0;
}
.card.status { grid-column: span 4; }
.card.access { grid-column: span 8; }
.card.storage { grid-column: span 7; }
.card.env { grid-column: span 5; }
.card-title {
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: var(--text-dim);
  margin-bottom: 12px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.kv { display: flex; flex-direction: column; gap: 8px; }
.kv-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  font-size: 13px;
}
.kv-row .k { color: var(--text-dim); flex-shrink: 0; }
.kv-row .v {
  color: var(--text);
  font-weight: 500;
  text-align: right;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.mono, .kv-row .v.mono {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
}
.state-running {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--green);
  font-weight: 600;
}
.state-running::before {
  content: '';
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--green);
}
.update-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 10.5px;
  font-weight: 700;
  background: rgba(251, 191, 36, 0.12);
  color: var(--amber);
  border: 1px solid rgba(251, 191, 36, 0.3);
  text-transform: none;
  letter-spacing: 0.2px;
}
.access-url {
  display: flex;
  align-items: center;
  gap: 10px;
  background: var(--k-surface);
  border: 1px solid var(--k-border);
  border-radius: var(--radius);
  padding: 9px 12px;
  margin-bottom: 12px;
}
.access-url .label,
.ingress-row .label {
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: var(--text-dim);
  flex-shrink: 0;
}
.access-url a {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 13px;
  font-weight: 600;
  color: var(--accent);
}
.access-url .dim { color: var(--text-dim); font-size: 13px; }
.ports-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12.5px;
  margin-bottom: 12px;
}
.ports-table th {
  text-align: left;
  font-size: 10.5px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: var(--text-dim);
  padding: 5px 8px;
  border-bottom: 1px solid var(--k-border);
}
.ports-table td {
  padding: 6px 8px;
  border-bottom: 1px solid var(--k-border);
  color: var(--text-secondary);
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
}
.ports-table tr:last-child td { border-bottom: none; }
.ports-table .arrow { color: var(--text-dim); }
.ports-note {
  font-size: 11px;
  color: var(--text-dim);
  margin-top: -6px;
  margin-bottom: 12px;
}
.ingress-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding-top: 10px;
  border-top: 1px solid var(--k-border);
  flex-wrap: wrap;
}
.chip {
  display: inline-flex;
  align-items: center;
  padding: 3px 9px;
  border-radius: var(--radius);
  font-size: 11.5px;
  font-weight: 600;
  border: 1px solid var(--k-border);
  background: var(--k-card);
  color: var(--text-secondary);
}
.chip.direct {
  color: var(--green);
  border-color: rgba(52, 211, 153, 0.3);
  background: rgba(52, 211, 153, 0.08);
}
.chip.prefix {
  color: var(--accent);
  border-color: rgba(0, 144, 248, 0.3);
  background: rgba(0, 144, 248, 0.08);
}
.toggle {
  position: relative;
  width: 30px;
  height: 17px;
  border-radius: 999px;
  background: rgba(184, 184, 180, 0.15);
  border: 1px solid var(--k-border);
  flex-shrink: 0;
}
.toggle::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 11px;
  height: 11px;
  border-radius: 50%;
  background: var(--text-dim);
}
.toggle-state {
  font-size: 12px;
  color: var(--text-dim);
  font-weight: 500;
}
.ingress-reason {
  font-size: 12px;
  color: var(--text-dim);
  flex-basis: 100%;
}
.mount-list {
  display: flex;
  flex-direction: column;
  gap: 7px;
  margin-bottom: 12px;
}
.mount {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 12.5px;
}
.mount .kind {
  flex-shrink: 0;
  width: 52px;
  text-align: center;
  padding: 2px 0;
  border-radius: var(--radius);
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
.mount .kind.bind { background: rgba(0, 144, 248, 0.12); color: var(--accent); }
.mount .kind.volume { background: rgba(52, 211, 153, 0.12); color: var(--green); }
.mount .paths {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.mount .paths .arrow { color: var(--text-dim); margin: 0 5px; }
.volume-root {
  padding-top: 10px;
  border-top: 1px solid var(--k-border);
  font-size: 12px;
  color: var(--text-dim);
}
.volume-root .mono { color: var(--text-secondary); }
.env-summary { display: flex; flex-direction: column; gap: 8px; }
.env-count { display: flex; align-items: baseline; gap: 8px; }
.env-count .num {
  font-size: 26px;
  font-weight: 700;
  color: var(--text);
  line-height: 1;
}
.env-count .unit { font-size: 12.5px; color: var(--text-dim); }
.secrets-note {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.secrets-note .lock { color: var(--amber); font-size: 12px; }
.env-hint {
  font-size: 11.5px;
  color: var(--text-dim);
  border-top: 1px solid var(--k-border);
  padding-top: 10px;
  margin-top: 2px;
}
.dim { color: var(--text-dim); font-size: 13px; }
@media (max-width: 900px) {
  .card.status, .card.access, .card.storage, .card.env { grid-column: span 12; }
}
</style>
