import { ref, watch } from 'vue'
import { defineStore } from 'pinia'

export type Theme = 'dark' | 'light'

const THEME_KEY = 'theme'

function systemTheme(): Theme {
  if (typeof window === 'undefined' || !window.matchMedia) return 'dark'
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
}

function readSavedTheme(): Theme | null {
  const saved = localStorage.getItem(THEME_KEY)
  return saved === 'light' || saved === 'dark' ? saved : null
}

export const useThemeStore = defineStore('theme', () => {
  const explicit = ref(readSavedTheme() !== null)
  const theme = ref<Theme>(readSavedTheme() ?? systemTheme())

  function apply(t: Theme) {
    document.documentElement.setAttribute('data-theme', t)
  }

  watch(
    theme,
    (t) => {
      apply(t)
      if (explicit.value) localStorage.setItem(THEME_KEY, t)
    },
    { immediate: true },
  )

  if (typeof window !== 'undefined' && window.matchMedia) {
    const mq = window.matchMedia('(prefers-color-scheme: light)')
    const onChange = () => {
      if (!explicit.value) theme.value = systemTheme()
    }
    if (typeof mq.addEventListener === 'function') mq.addEventListener('change', onChange)
    else mq.addListener(onChange)
  }

  function toggle() {
    explicit.value = true
    theme.value = theme.value === 'dark' ? 'light' : 'dark'
  }

  return { theme, toggle }
})
