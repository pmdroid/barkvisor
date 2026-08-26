<script setup lang="ts">
defineProps<{
  columns: Array<{ key: string; label: string; width?: string; align?: 'left' | 'right' }>
}>()
</script>

<template>
  <div class="data-table-wrap">
    <table>
      <thead>
        <tr>
          <th
            v-for="col in columns"
            :key="col.key"
            :style="{ width: col.width, textAlign: col.align }"
          >
            {{ col.label }}
          </th>
        </tr>
      </thead>
      <tbody>
        <slot />
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.data-table-wrap {
  background: var(--panel);
  backdrop-filter: none;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  overflow-x: auto;
  box-shadow: none;
}
</style>
