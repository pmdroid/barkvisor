<script setup lang="ts">
import { computed } from 'vue'
import type { MetricSample, VM } from '../api/types'
import { firstOpenUrl } from '../utils/workloadKind'
import { shortDigest } from '../utils/composeLogs'
import { visibleAppMounts, type ComposeMount } from '../utils/composeMounts'
import type { ComposeMountDraft } from '../utils/composeEdit'
import AppMountList from './AppMountList.vue'
import {
  appCatalogSource,
  appClassLabel,
  appEnvSummary,
  appIngressState,
  composeProjectName,
  formatUptime,
  parseRestartPolicy,
} from '../utils/appDetail'
import { isAppRunning, summarizeAppUsage } from '../utils/appUsage'
import { DEVICE_LABEL } from '../utils/terminology'

const props = defineProps<{
  vm: VM
  deviceLabel?: string
  openUrl?: string | null
  savingIngress?: boolean
  metrics?: MetricSample[]
  editable?: boolean
  savingVolumes?: boolean
  savingPorts?: boolean
  pickedHost?: string
}>()

const emit = defineEmits<{
  'update-ingress': [{ enabled: boolean; mode: 'prefix' | 'direct' }]
  'add-mount': [ComposeMountDraft]
  'remove-mount': [ComposeMount]
  'pick-host': []
  'edit-ports': []
}>()

const published = computed(() => props.openUrl || firstOpenUrl(props.vm))
const catalog = computed(() => appCatalogSource(props.vm))
const mounts = computed(() => visibleAppMounts({
  compose: props.vm.spec?.spec?.compose,
  sharedPaths: props.vm.sharedPaths,
}))
const env = computed(() => appEnvSummary(props.vm))
const ingress = computed(() => appIngressState(props.vm))

function setIngressEnabled(enabled: boolean) {
  emit('update-ingress', { enabled, mode: ingress.value.mode })
}

function setIngressMode(mode: 'prefix' | 'direct') {
  emit('update-ingress', { enabled: ingress.value.enabled, mode })
}
const ports = computed(() => props.vm.publishedPorts ?? [])
const image = computed(() => {
  if (props.vm.image) return props.vm.image
  const m = (props.vm.spec?.spec?.compose ?? '').match(/image:\s*(\S+)/)
  return m?.[1] ?? '—'
})
const klass = computed(() => appClassLabel(props.vm))
const restart = computed(() => parseRestartPolicy(props.vm.spec?.spec?.compose))
const runtimeLabel = computed(() => {
  const r = (props.vm.runtime || props.vm.spec?.spec?.runtime || '').toLowerCase()
  if (r === 'device' || r === 'docker') return `${DEVICE_LABEL} Docker`
  return r ? r : `${DEVICE_LABEL} Docker`
})
const container = computed(() => composeProjectName(props.vm.id))
const uptime = computed(() =>
  props.vm.state === 'running' && props.vm.createdAt ? formatUptime(props.vm.createdAt) : '—',
)
const appRunning = computed(() => isAppRunning(props.vm))
const usage = computed(() =>
  appRunning.value ? summarizeAppUsage(props.metrics) : null,
)
</script>

<template>
  <div class="detail-grid">
    <div class="col">
      <section class="panel">
        <h2>
          Application
          <span v-if="vm.updateAvailable" class="update-badge">Update available</span>
        </h2>
        <div class="kv"><span class="k">Image</span><span class="v mono">{{ image }}</span></div>
        <div class="kv"><span class="k">Digest</span><span class="v mono">{{ shortDigest(vm.digest) || '—' }}</span></div>
        <div class="kv">
          <span class="k">Published</span>
          <span class="v">
            <a v-if="published" :href="published" target="_blank" rel="noopener">{{ published }}</a>
            <span v-else class="dim">Start the app to open the UI</span>
          </span>
        </div>
        <div v-if="klass" class="kv">
          <span class="k">Class</span>
          <span class="v"><span class="tag">{{ klass }}</span></span>
        </div>
        <div class="kv"><span class="k">Restart policy</span><span class="v">{{ restart }}</span></div>
      </section>

      <section class="panel">
        <h2>Volumes</h2>
        <AppMountList
          :mounts="mounts"
          :roots="(vm.volumeRoots ?? []).filter(Boolean)"
          :editable="editable === true"
          :busy="savingVolumes === true"
          :pickedHost="pickedHost"
          @add-mount="emit('add-mount', $event)"
          @remove-mount="emit('remove-mount', $event)"
          @pick-host="emit('pick-host')"
        />
      </section>

      <section class="panel">
        <h2>
          Access
          <button
            v-if="editable"
            type="button"
            class="fact-edit"
            :disabled="savingPorts"
            @click="emit('edit-ports')"
          >Edit</button>
        </h2>
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
        <p v-if="ports.length && !editable" class="ports-note">Port bindings are informational — reach the app via the published address above.</p>
        <p v-else-if="editable" class="ports-note">Use Edit to change which host ports the app publishes.</p>
        <div class="kv">
          <span class="k">Ingress</span>
          <span class="v">
            <label class="switch" :class="{ on: ingress.enabled, busy: savingIngress }">
              <input
                type="checkbox"
                role="switch"
                :checked="ingress.enabled"
                :disabled="savingIngress"
                aria-label="Enable ingress"
                @change="setIngressEnabled(($event.target as HTMLInputElement).checked)"
              >
              <span class="track"><span class="knob"></span></span>
              <span class="switch-label">{{ ingress.enabled ? 'On' : 'Off' }}</span>
            </label>
          </span>
        </div>
        <div class="kv">
          <span class="k">Mode</span>
          <span class="v">
            <span class="seg" role="group" aria-label="Ingress mode">
              <button
                type="button"
                class="seg-btn"
                :class="{ on: ingress.mode === 'prefix' }"
                :disabled="savingIngress || !ingress.enabled"
                @click="setIngressMode('prefix')"
              >Prefix</button>
              <button
                type="button"
                class="seg-btn"
                :class="{ on: ingress.mode === 'direct' }"
                :disabled="savingIngress || !ingress.enabled"
                @click="setIngressMode('direct')"
              >Direct</button>
            </span>
          </span>
        </div>
        <div v-if="ingress.enabled && ingress.mode === 'prefix'" class="kv">
          <span class="k">Prefix</span>
          <span class="v mono">{{ ingress.path }}</span>
        </div>
        <p class="ingress-reason">{{ ingress.reason }}</p>
      </section>
    </div>

    <div class="col">
      <section class="panel">
        <h2>Runtime</h2>
        <div class="kv"><span class="k">Device</span><span class="v">{{ deviceLabel || '—' }}</span></div>
        <div class="kv"><span class="k">Runtime</span><span class="v">{{ runtimeLabel }}</span></div>
        <div class="kv"><span class="k">Container</span><span class="v mono">{{ container }}</span></div>
        <div class="kv"><span class="k">Uptime</span><span class="v">{{ uptime }}</span></div>
      </section>

      <section class="panel">
        <h2>Usage</h2>
        <div class="stat">
          <span class="sk">CPU</span>
          <span class="sv">{{ usage?.cpuLabel ?? '—' }}</span>
          <div v-if="usage?.cpuFraction != null" class="bar">
            <i :style="{ width: `${Math.round((usage.cpuFraction ?? 0) * 100)}%` }"></i>
          </div>
        </div>
        <div class="stat">
          <span class="sk">Memory</span>
          <span class="sv">{{ usage?.memLabel ?? '—' }}</span>
          <div v-if="usage?.memFraction != null" class="bar">
            <i :style="{ width: `${Math.round((usage.memFraction ?? 0) * 100)}%` }"></i>
          </div>
        </div>
        <div class="stat">
          <span class="sk">Network I/O</span>
          <span class="sv net">{{ usage?.netLabel ?? '—' }}</span>
        </div>
        <p v-if="!appRunning" class="ports-note">Start the app to see live container stats.</p>
        <p v-else-if="!usage" class="ports-note">Waiting for container stats…</p>
      </section>

      <section class="panel">
        <h2>Environment</h2>
        <div class="env-summary">
          <div class="env-count">
            <span class="num">{{ env.count }}</span>
            <span class="unit">variables configured</span>
          </div>
          <div class="secrets-note">{{ env.secrets }} secrets hidden — values never displayed</div>
          <p v-if="catalog" class="env-hint">
            Catalog app: variables are managed by the {{ catalog }} template. Edit in the Environment tab.
          </p>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.detail-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr);
  gap: 14px;
  width: 100%;
  align-items: start;
}
.col {
  display: flex;
  flex-direction: column;
  gap: 14px;
  min-width: 0;
}
.panel {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 18px;
}
.panel h2 {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--text-dim);
  margin-bottom: 14px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.kv {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 8px 0;
  border-bottom: 1px solid var(--border);
  font-size: 13px;
}
.kv:last-child { border-bottom: none; }
.k { color: var(--text-dim); flex-shrink: 0; }
.v {
  color: var(--text);
  text-align: right;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.v.mono, .mono {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
}
.v a { color: var(--accent); text-decoration: none; }
.v a:hover { text-decoration: underline; }
.dim { color: var(--text-dim); }
.tag {
  display: inline-block;
  font-size: 10.5px;
  font-weight: 600;
  padding: 2px 7px;
  border-radius: var(--radius);
  border: 1px solid rgba(251, 191, 36, 0.4);
  color: var(--amber);
}
.update-badge {
  display: inline-flex;
  align-items: center;
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
.ports-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12.5px;
  margin-bottom: 8px;
}
.ports-table th {
  text-align: left;
  font-size: 10.5px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: var(--text-dim);
  padding: 5px 0;
  border-bottom: 1px solid var(--border);
}
.ports-table td {
  padding: 6px 0;
  border-bottom: 1px solid var(--border);
  color: var(--text-secondary);
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
}
.ports-table tr:last-child td { border-bottom: none; }
.ports-table .arrow { color: var(--text-dim); }
.ports-note, .ingress-reason, .env-hint {
  font-size: 12px;
  color: var(--text-dim);
  margin-top: 8px;
}
.switch {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
}
.switch.busy { opacity: 0.6; cursor: wait; }
.switch input { position: absolute; opacity: 0; pointer-events: none; }
.track {
  position: relative;
  width: 32px;
  height: 18px;
  border-radius: 999px;
  background: rgba(184, 184, 180, 0.18);
  border: 1px solid var(--border);
  flex-shrink: 0;
}
.switch.on .track {
  background: var(--accent);
  border-color: var(--accent);
}
.knob {
  position: absolute;
  top: 2px;
  left: 2px;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--text-dim);
  transition: left 0.15s ease;
}
.switch.on .knob { left: 16px; background: #fff; }
.switch-label { font-size: 12px; font-weight: 600; color: var(--text-secondary); }
.seg {
  display: inline-flex;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
}
.seg-btn {
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  padding: 5px 10px;
  border: none;
  background: transparent;
  color: var(--text-dim);
  cursor: pointer;
}
.seg-btn.on { background: rgba(0, 144, 248, 0.14); color: var(--accent); }
.seg-btn:disabled { opacity: 0.45; cursor: not-allowed; }
.stat {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: 10px 0;
  border-bottom: 1px solid var(--border);
}
.stat:last-of-type { border-bottom: none; }
.sk {
  font-size: 11px;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  font-weight: 600;
}
.sv { font-size: 16px; font-weight: 600; }
.sv.net { font-size: 13.5px; font-weight: 600; }
.bar {
  height: 5px;
  border-radius: 999px;
  background: rgba(184, 184, 180, 0.16);
  overflow: hidden;
  margin-top: 6px;
}
.bar i {
  display: block;
  height: 100%;
  border-radius: 999px;
  background: var(--accent);
}
.env-summary { display: flex; flex-direction: column; gap: 8px; }
.env-count { display: flex; align-items: baseline; gap: 8px; }
.env-count .num { font-size: 26px; font-weight: 700; line-height: 1; }
.env-count .unit { font-size: 12.5px; color: var(--text-dim); }
.secrets-note { font-size: 12.5px; color: var(--text-secondary); }
@media (max-width: 720px) {
  .detail-grid { grid-template-columns: 1fr; }
}
.fact-edit {
  font: inherit;
  font-size: 11px;
  font-weight: 600;
  color: var(--accent);
  background: none;
  border: 0;
  padding: 0;
  cursor: pointer;
  text-transform: none;
  letter-spacing: 0;
}
.fact-edit:disabled { opacity: 0.35; cursor: default; }
</style>
