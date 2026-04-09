import { ref, watch } from 'vue'
import { defineStore } from 'pinia'

export type Theme = 'dark' | 'light'

export const useThemeStore = defineStore('theme', () => {
  const saved = localStorage.getItem('theme') as Theme | null
  const theme = ref<Theme>(saved || 'dark')

  function apply(t: Theme) {
    document.documentElement.setAttribute('data-theme', t)
  }

  watch(theme, (t) => {
    localStorage.setItem('theme', t)
    apply(t)
  }, { immediate: true })

  function toggle() {
    theme.value = theme.value === 'dark' ? 'light' : 'dark'
  }

  return { theme, toggle }
})
