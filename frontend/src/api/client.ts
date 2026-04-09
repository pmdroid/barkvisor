import axios from 'axios'

const api = axios.create({
  baseURL: '/api',
})

api.interceptors.request.use((config) => {
  const token = localStorage.getItem('token')
  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

let onUnauthorized: (() => void) | null = null

/** Register a callback for 401 responses (called from main.ts with router.push). */
export function setUnauthorizedHandler(handler: () => void) {
  onUnauthorized = handler
}

let onSetupRequired: (() => void) | null = null

/** Register a callback for 503 setup_required responses. */
export function setSetupRequiredHandler(handler: () => void) {
  onSetupRequired = handler
}

api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      localStorage.removeItem('token')
      if (onUnauthorized) {
        onUnauthorized()
      }
    }
    if (error.response?.status === 503 && error.response?.data?.reason === 'setup_required') {
      if (onSetupRequired) {
        onSetupRequired()
      }
    }
    return Promise.reject(error)
  }
)

/**
 * Exchange the current JWT for a short-lived, single-use ticket
 * suitable for use in URL query parameters (WebSocket, SSE, downloads).
 * Tickets expire after 30 seconds and can only be used once.
 */
export async function getWSTicket(vmID?: string): Promise<string> {
  const { data } = await api.post('/auth/ws-ticket', vmID ? { vmID } : {})
  return data.ticket
}

export default api
