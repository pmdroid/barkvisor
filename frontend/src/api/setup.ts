import axios from 'axios'
import type { LibrarySettings } from './types'

const setupApi = axios.create({ baseURL: '/api/setup' })

export { setupApi }

export interface SetupStatus {
  complete: boolean
  /** Shared identity landed after a pairing join (admin exists). Not receipt-only. */
  joined?: boolean
  admin?: boolean
}

export interface InterfaceInfo {
  name: string
  displayName: string
  ipAddress: string
  bridgeStatus: string | null
}

export interface RepoSyncStatus {
  syncing: boolean
  message: string
  done: boolean
  error: string | null
  imageCount: number
  templateCount: number
}

export async function getSetupStatus(): Promise<SetupStatus> {
  const { data } = await setupApi.get('/status')
  return data
}

export async function createAdmin(username: string, password: string): Promise<void> {
  await setupApi.post('/admin', { username, password })
}

export async function listInterfaces(): Promise<InterfaceInfo[]> {
  const { data } = await setupApi.get('/interfaces')
  return data
}

export async function installBridge(iface: string): Promise<{ success: boolean; message?: string }> {
  const { data } = await setupApi.post('/bridge', { interface: iface })
  return data
}

export async function skipBridge(): Promise<void> {
  await setupApi.post('/bridge/skip')
}

export async function startRepoSync(): Promise<RepoSyncStatus> {
  const { data } = await setupApi.post('/repositories/sync')
  return data
}

export async function getRepoSyncStatus(): Promise<RepoSyncStatus> {
  const { data } = await setupApi.get('/repositories/status')
  return data
}

export async function completeSetup(): Promise<{ token: string }> {
  const { data } = await setupApi.post('/complete')
  return data
}

export async function getSetupLibrary(): Promise<LibrarySettings> {
  const { data } = await setupApi.get<LibrarySettings>('/library')
  return data
}

export async function saveSetupLibrary(imageDirectory: string): Promise<LibrarySettings> {
  const { data } = await setupApi.put<LibrarySettings>('/library', { imageDirectory })
  return data
}
