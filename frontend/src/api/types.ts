export interface Image {
  id: string
  name: string
  imageType: 'iso' | 'cloud-image'
  arch: 'arm64'
  status: 'uploading' | 'downloading' | 'decompressing' | 'ready' | 'error'
  sizeBytes: number | null
  sourceUrl: string | null
  error: string | null
  createdAt: string
  updatedAt: string
}

export interface VM {
  id: string
  name: string
  vmType: 'linux-arm64' | 'windows-arm64'
  state: 'stopped' | 'starting' | 'running' | 'stopping' | 'error' | 'provisioning' | 'deleting'
  cpuCount: number
  memoryMB: number
  bootDiskId: string
  isoId: string | null
  isoIds: string[] | null
  networkId: string | null
  cloudInitPath: string | null
  description: string | null
  bootOrder: string | null
  displayResolution: string | null
  additionalDiskIds: string[] | null
  uefi: boolean
  tpmEnabled: boolean
  macAddress: string | null
  sharedPaths: string[] | null
  portForwards: PortForwardRule[] | null
  usbDevices: USBPassthroughDevice[] | null
  pendingChanges: boolean
  createdAt: string
  updatedAt: string
}

export interface Disk {
  id: string
  name: string
  path: string
  sizeBytes: number
  format: string
  vmId: string | null
  status: 'ready' | 'creating' | 'error'
  createdAt: string
}

export interface DiskUsage {
  virtualSizeBytes: number
  actualSizeBytes: number
}

export interface StorageSummary {
  totalVirtualBytes: number
  totalActualBytes: number
  diskCount: number
  volumeTotalBytes: number
  volumeAvailableBytes: number
}

export interface Network {
  id: string
  name: string
  mode: 'nat' | 'bridged'
  bridge?: string
  dnsServer?: string | null
  isDefault: boolean
}

export interface PortForwardRule {
  protocol: 'tcp' | 'udp'
  hostPort: number
  guestPort: number
}

export interface USBPassthroughDevice {
  vendorId: string
  productId: string
  label?: string | null
}

export interface HostUSBDevice {
  vendorId: string
  productId: string
  name: string
  manufacturer: string | null
  serialNumber: string | null
  claimedByVMId: string | null
  claimedByVMName: string | null
}

export interface CreateVMRequest {
  name: string
  vmType: 'linux-arm64' | 'windows-arm64'
  cpuCount: number
  memoryMB: number
  diskSizeGB?: number
  isoId?: string
  cloudImageId?: string
  networkId?: string
  cloudInit?: {
    sshAuthorizedKeys?: string[]
    userData?: string
  }
  usbDevices?: USBPassthroughDevice[]
  description?: string
  bootOrder?: string
  displayResolution?: string
  uefi?: boolean
  tpmEnabled?: boolean
}

export interface DownloadImageRequest {
  name: string
  url: string
  imageType: 'iso' | 'cloud-image'
  arch: 'arm64'
}

export interface ImageRepository {
  id: string
  name: string
  url: string
  isBuiltIn: boolean
  repoType: 'images' | 'templates'
  lastSyncedAt: string | null
  lastError: string | null
  syncStatus: 'idle' | 'syncing' | 'error'
  createdAt: string
  updatedAt: string
}

export type TaskKind = 'vmProvision' | 'vmDelete' | 'diagnosticBundle' | 'repoSync' | 'systemUpdate'

export interface TaskEvent {
  taskID: string
  kind: TaskKind
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled'
  progress: number | null
  error: string | null
  resultPayload: string | null
}

export type UpdateVMRequest = Partial<Pick<VM,
  'name' | 'cpuCount' | 'memoryMB' | 'networkId' | 'description' |
  'bootOrder' | 'displayResolution' | 'uefi' | 'tpmEnabled' |
  'sharedPaths' | 'additionalDiskIds' | 'portForwards' | 'usbDevices'
>>

export interface TaskAcceptedResponse {
  taskID: string
}

export interface VMTaskAcceptedResponse {
  taskID: string
  vm: VM
}

export interface RepositoryImage {
  id: string
  repositoryId: string
  slug: string
  name: string
  description: string | null
  imageType: string
  arch: string
  version: string | null
  downloadUrl: string
  sizeBytes: number | null
}

export interface HostInterface {
  name: string
  displayName: string
  ipAddress: string
  bridgeStatus?: 'active' | 'installed' | 'not_configured' | null
}

export interface BridgeInfo {
  interface: string
  socketPath: string | null
  plistExists: boolean
  daemonRunning: boolean
  status: 'active' | 'installed' | 'not_configured'
  updatedAt: string
}

export interface BridgeActionResponse {
  success: boolean
  message: string | null
}

export interface GuestUser {
  name: string
  loginTime: number | null
}

export interface GuestFilesystem {
  mountpoint: string
  type: string
  device: string
  totalBytes: number | null
  usedBytes: number | null
}

export interface GuestInfo {
  available: boolean
  ipAddresses: string[]
  macAddress: string | null
  ipSource: string  // "guest-agent", "nat-default", "waiting"
  hostname: string | null
  osName: string | null
  osVersion: string | null
  osId: string | null
  kernelVersion: string | null
  kernelRelease: string | null
  machine: string | null
  timezone: string | null
  timezoneOffset: number | null
  users: GuestUser[] | null
  filesystems: GuestFilesystem[] | null
}

export interface MetricSample {
  timestamp: string
  cpuPercent: number
  memoryUsedMB: number
  diskReadBytes: number
  diskWriteBytes: number
}

export interface SystemStats {
  hostCpuPercent: number
  hostMemoryTotalMB: number
  hostMemoryUsedMB: number
  runningVMs: number
  totalVMs: number
  vmCpuPercent: number
  vmMemoryMB: number
}

export interface SystemStatsSample {
  timestamp: string
  hostCpuPercent: number
  hostMemoryUsedMB: number
  hostMemoryTotalMB: number
}

export interface TemplateInput {
  id: string
  label: string
  type: 'text' | 'password' | 'textarea'
  default?: string
  required: boolean
  placeholder?: string
  minLength?: number
}

export interface VMTemplate {
  id: string
  slug: string
  name: string
  description: string | null
  category: string
  icon: string
  imageSlug: string
  cpuCount: number
  memoryMB: number
  diskSizeGB: number
  portForwards: PortForwardRule[] | null
  networkMode: 'nat' | 'bridged'
  inputs: TemplateInput[]
  userDataTemplate: string
  isBuiltIn: boolean
  repositoryId: string | null
}

export interface DeployTemplateRequest {
  templateId: string
  vmName: string
  inputs: Record<string, string>
  cpuCount?: number
  memoryMB?: number
  diskSizeGB?: number
  networkId?: string
}

export interface DeployTemplateResponse {
  status: 'downloading' | 'created'
  imageId: string | null
  vm: VM | null
}

export interface APIKeyResponse {
  id: string
  name: string
  keyPrefix: string
  expiresAt: string | null
  lastUsedAt: string | null
  createdAt: string
}

export interface APIKeyCreateResponse {
  id: string
  name: string
  key: string
  keyPrefix: string
  expiresAt: string | null
  createdAt: string
}

export interface SSHKey {
  id: string
  name: string
  publicKey: string
  fingerprint: string
  keyType: string
  isDefault: boolean
  createdAt: string
}

export interface AuditEntry {
  id: number
  timestamp: string
  userId: string | null
  username: string | null
  action: string
  resourceType: string | null
  resourceId: string | null
  resourceName: string | null
  detail: string | null
  authMethod: string | null
  apiKeyId: string | null
}

export interface AuditLogResponse {
  entries: AuditEntry[]
  total: number
}

export interface UpdateInfo {
  version: string
  pkgURL: string
  checksumURL: string | null
  changelog: string
  publishedAt: string
  isPrerelease: boolean
}

export interface UpdateCheckResponse {
  currentVersion: string
  update: UpdateInfo | null
}

export interface UpdateSettings {
  channel: 'stable' | 'beta'
  autoCheck: boolean
  isDevBuild: boolean
  updateURL?: string | null
}
