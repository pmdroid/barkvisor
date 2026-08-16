<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import DeviceCard from '../components/DeviceCard.vue'
import AppButton from '../components/ui/AppButton.vue'
import { useDevicesStore } from '../stores/devices'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const router = useRouter()
const devices = useDevicesStore()

let pollTimer: number
onMounted(() => {
  devices.fetchHealth()
  pollTimer = window.setInterval(() => { devices.fetchHealth() }, 5000)
})
onUnmounted(() => clearInterval(pollTimer))
</script>

<template>
  <div class="devices-page">
    <div class="welcome">
      <div>
        <h1>{{ DEVICE_LABEL }}s</h1>
        <p class="welcome-sub">
          <template v-if="devices.totals">
            {{ devices.totals.reachable }} of {{ devices.totals.devices }} reachable
            <span v-if="devices.totals.unreachable > 0">
              · {{ devices.totals.unreachable }} unreachable
            </span>
            <template v-if="devices.totals.workloadCount != null">
              · {{ devices.totals.workloadCount }} workloads across this {{ HOME_LABEL }}
            </template>
          </template>
          <template v-else>
            Every {{ DEVICE_LABEL.toLowerCase() }} in this {{ HOME_LABEL }}
          </template>
        </p>
      </div>
      <AppButton variant="primary" icon="plus" @click="router.push('/settings?tab=home')">
        Add a {{ DEVICE_LABEL }}
      </AppButton>
    </div>

    <p v-if="devices.error && !devices.report" class="devices-error">
      Could not load {{ DEVICE_LABEL.toLowerCase() }} health. This {{ DEVICE_LABEL.toLowerCase() }} is still running.
    </p>

    <div v-if="devices.devices.length" class="device-grid">
      <DeviceCard v-for="row in devices.devices" :key="row.hostId" :device="row" />
    </div>
  </div>
</template>

<style scoped>
.welcome {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 32px;
}
.welcome h1 {
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.03em;
}
.welcome-sub {
  color: var(--text-dim);
  font-size: 13px;
  margin-top: 4px;
}
.devices-error {
  color: var(--text-secondary);
  font-size: 13px;
  margin: -12px 0 20px;
}
.device-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 16px;
}

@media (max-width: 768px) {
  .welcome { flex-direction: column; align-items: flex-start; gap: 12px; margin-bottom: 24px; }
  .welcome h1 { font-size: 22px; }
}
</style>
