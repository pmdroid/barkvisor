<script setup lang="ts">
defineProps<{
  virtioWinAvailable: boolean
  virtioWinDownloading: boolean
  virtioWinProgress: number
  virtioWinStatus: string
  virtioWinError: string
}>()

const emit = defineEmits<{
  download: []
}>()
</script>

<template>
  <div>
    <h3 class="step-title">Windows Drivers</h3>
    <p style="font-size:13px;color:var(--text-secondary);margin-bottom:16px">
      Windows VMs require the VirtIO driver ISO for network, storage, and display drivers.
      This is a one-time download (~550 MB) from the Fedora project.
    </p>

    <div v-if="virtioWinAvailable" class="driver-status driver-ready">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--green)" stroke-width="2.5" stroke-linecap="round"><polyline points="20 6 9 17 4 12"/></svg>
      <span>VirtIO drivers are ready</span>
    </div>

    <div v-else-if="virtioWinDownloading" class="driver-status">
      <div style="width:100%">
        <div style="display:flex;justify-content:space-between;margin-bottom:6px;font-size:12px">
          <span>{{ virtioWinStatus === 'decompressing' ? 'Decompressing...' : 'Downloading VirtIO drivers...' }}</span>
          <span>{{ Math.round(virtioWinProgress) }}%</span>
        </div>
        <div class="progress-bar">
          <div class="progress-fill" :style="{ width: virtioWinProgress + '%' }"></div>
        </div>
      </div>
    </div>

    <div v-else>
      <button class="btn-primary" style="width:100%" @click="emit('download')">
        Download VirtIO Drivers
      </button>
      <p v-if="virtioWinError" style="color:var(--red);font-size:12px;margin-top:8px">
        {{ virtioWinError }}
      </p>
    </div>

    <p style="font-size:11px;color:var(--text-dim);margin-top:12px">
      Source: fedorapeople.org/groups/virt/virtio-win
    </p>
  </div>
</template>

<style scoped>
.step-title {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 16px;
  color: var(--text);
}
.driver-status {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 16px;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  font-size: 13px;
}
.driver-ready {
  border-color: var(--green);
  background: rgba(34, 197, 94, 0.06);
  color: var(--green);
  font-weight: 500;
}
.progress-bar {
  width: 100%;
  height: 6px;
  background: var(--border);
  border-radius: 3px;
  overflow: hidden;
}
.progress-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 3px;
  transition: width 0.3s ease;
}
</style>
