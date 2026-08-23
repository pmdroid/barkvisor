/** Guest / image CPU architecture (API: arm64 | x86_64). */
export type ImageArch = 'arm64' | 'x86_64'

export interface Image {
  id: string
  name: string
  imageType: 'iso' | 'cloud-image'
  arch: ImageArch | string
  status: 'uploading' | 'downloading' | 'decompressing' | 'ready' | 'error'
  sizeBytes: number | null
  sourceUrl: string | null
  error: string | null
  sha256?: string | null
  createdAt: string
  updatedAt: string
}

export type VMState =
  | 'stopped'
  | 'starting'
  | 'running'
  | 'stopping'
  | 'error'
  | 'provisioning'
  | 'deleting'

export type WorkloadHealth =
  | 'unknown'
  | 'stopped'
  | 'starting'
  | 'running'
  | 'guest_ready'
  | 'degraded'
  | 'failed'

export type WorkloadHealthCheckStatus = 'pass' | 'fail' | 'skip'

export interface WorkloadHealthCheck {
  name: string
  status: WorkloadHealthCheckStatus
  message?: string | null
}

export interface WorkloadHealthStatus {
  health: WorkloadHealth
  checks: WorkloadHealthCheck[]
  updatedAt: string
  lastError?: string | null
}

export interface WorkloadHealthSummaryItem {
  id: string
  name: string
  kind: string
  health: WorkloadHealth
  lastError?: string | null
}

export interface WorkloadHealthSummary {
  counts: Record<string, number>
  items: WorkloadHealthSummaryItem[]
  updatedAt: string
}

export interface WorkloadResources {
  cpu: number
  memoryMb: number
}

export interface WorkloadFirmware {
  uefi: boolean
  tpm: boolean
}

export interface WorkloadDisk {
  role: 'boot' | 'data' | 'cdrom' | string
  diskId?: string | null
  imageId?: string | null
  bus?: string | null
}

export interface WorkloadPortForward {
  hostPort: number
  guestPort: number
  proto: string
}

export interface WorkloadNetwork {
  mode?: string | null
  networkId?: string | null
  mac?: string | null
  portForwards?: WorkloadPortForward[]
}

export interface WorkloadCloudInit {
  userDataRef?: string | null
  inline?: string | null
}

export interface WorkloadUSBDevice {
  vendorId: string
  productId: string
  label?: string | null
  serialNumber?: string | null
  deviceId?: string | null
}

export interface WorkloadDisplay {
  resolution?: string | null
}

export interface WorkloadMetadata {
  id?: string | null
  name: string
  description?: string | null
  labels?: Record<string, string> | null
}

export interface WorkloadHealthHTTPCheck {
  path: string
  port: number
  expectedStatus?: number | null
}

export interface WorkloadHealthTCPCheck {
  port: number
}

export interface WorkloadHealthSpec {
  intervalSec?: number | null
  timeoutSec?: number | null
  healthyThreshold?: number | null
  unhealthyThreshold?: number | null
  http?: WorkloadHealthHTTPCheck | null
  tcp?: WorkloadHealthTCPCheck | null
}

export interface WorkloadSpecBody {
  resources: WorkloadResources
  arch?: string | null
  guestType?: string | null
  osFamily?: string | null
  machine?: string | null
  firmware?: WorkloadFirmware | null
  bootOrder?: string | null
  disks?: WorkloadDisk[]
  networks?: WorkloadNetwork[]
  cloudInit?: WorkloadCloudInit | null
  usb?: WorkloadUSBDevice[]
  display?: WorkloadDisplay | null
  sharedPaths?: string[] | null
  health?: WorkloadHealthSpec | null
  /** `house` | `agent`. Omitted = house (PAS-268). */
  workloadClass?: 'house' | 'agent' | string | null
}

export interface WorkloadResourcesOverlay {
  cpu?: number | null
  memoryMb?: number | null
}

export interface WorkloadFirmwareOverlay {
  uefi?: boolean | null
  tpm?: boolean | null
}

/** Platform-specific spec overlay (PAS-41). Deep-merged for the host OS. */
export interface WorkloadSpecOverlay {
  resources?: WorkloadResourcesOverlay | null
  arch?: string | null
  guestType?: string | null
  osFamily?: string | null
  machine?: string | null
  firmware?: WorkloadFirmwareOverlay | null
  bootOrder?: string | null
  display?: WorkloadDisplay | null
  accelerator?: string | null
  hugepages?: boolean | null
}

export interface WorkloadOverrides {
  linux?: WorkloadSpecOverlay | null
  macos?: WorkloadSpecOverlay | null
}

export interface WorkloadSpec {
  apiVersion: string
  kind: string
  metadata: WorkloadMetadata
  spec: WorkloadSpecBody
  overrides?: WorkloadOverrides | null
}

export interface VMRuntimeBackend {
  accelerator: string
  guestArch: string
  qemuBinary: string
  emulated: boolean
  warning?: string | null
}

export interface VMRuntimeStatus {
  state: VMState
  pendingChanges: boolean
  generation: number
  createdAt: string
  updatedAt: string
  health: WorkloadHealth
  healthError?: string | null
  backend?: VMRuntimeBackend | null
}

export interface VM {
  spec?: WorkloadSpec
  status?: VMRuntimeStatus
  id: string
  name: string
  vmType: 'linux-arm64' | 'windows-arm64' | 'linux-amd64' | 'linux-x86_64' | 'windows-amd64' | string
  state: VMState | string
  health?: WorkloadHealth
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
  workloadClass?: 'house' | 'agent' | string | null
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

export type NetworkModeName = 'nat' | 'bridged' | 'isolated'

export interface Network {
  id: string
  name: string
  mode: NetworkModeName
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
  serialNumber?: string | null
  deviceId?: string | null
}

export interface HostUSBDevice {
  id: string
  vendorId: string
  productId: string
  name: string
  productName?: string
  manufacturer: string | null
  serial?: string | null
  serialNumber: string | null
  bus?: number | null
  address?: number | null
  idUnstable?: boolean
  attachable?: boolean
  excludedReason?: string | null
  busy?: boolean
  attachedToVmId?: string | null
  claimedByVMId: string | null
  claimedByVMName: string | null
}

export interface CreateVMRequest {
  name?: string
  vmType?: 'linux-arm64' | 'windows-arm64' | 'linux-amd64' | 'linux-x86_64' | 'windows-amd64' | string
  /** Used when vmType is omitted so the server can pick a host-native guest (PAS-93). */
  osFamily?: 'linux' | 'windows' | string
  cpuCount?: number
  memoryMB?: number
  diskSizeGB?: number
  existingDiskId?: string
  isoId?: string
  cloudImageId?: string
  networkId?: string
  cloudInit?: {
    sshAuthorizedKeys?: string[]
    userData?: string
  }
  usbDevices?: USBPassthroughDevice[]
  sharedPaths?: string[]
  portForwards?: PortForwardRule[]
  description?: string
  bootOrder?: string
  displayResolution?: string
  uefi?: boolean
  tpmEnabled?: boolean
  spec?: WorkloadSpec
  /** `house` | `agent`. Omitted = house (PAS-268). */
  workloadClass?: 'house' | 'agent' | string
}

export interface DownloadImageRequest {
  name: string
  url: string
  imageType: 'iso' | 'cloud-image'
  arch: ImageArch
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

export type TaskKind = 'vmProvision' | 'vmDelete' | 'diagnosticBundle' | 'repoSync' | 'systemUpdate' | 'ollamaPull'

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
>> & { spec?: WorkloadSpec }

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

export interface GuestListeningPort {
  proto: string
  address: string
  port: number
  scope: 'internal' | 'network' | string
  label: string | null
  scheme?: 'http' | 'https' | string | null
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
  /** null = unavailable, [] = none. */
  listeningPorts?: GuestListeningPort[] | null
  portsCollectedAt?: string | null
}

export interface MetricSample {
  timestamp: string
  cpuPercent: number
  memoryUsedMB: number
  diskReadBytes: number
  diskWriteBytes: number
}

export interface HostStorageMetric {
  path: string
  totalBytes: number | null
  freeBytes: number | null
  kind?: string
}

/** Unified host metrics (PAS-85). temperatureC is null when no sensor is readable. */
export interface HostMetrics {
  hostId: string
  collectedAt: string
  cpuLoadPercent: number
  memoryTotalMB: number
  memoryUsedMB: number
  storage: HostStorageMetric[]
  temperatureC: number | null
  uptimeSeconds: number
  agentHealthy: boolean
}

export interface SystemStats {
  hostCpuPercent: number
  hostMemoryTotalMB: number
  hostMemoryUsedMB: number
  runningVMs: number
  totalVMs: number
  vmCpuPercent: number
  vmMemoryMB: number
  metrics?: HostMetrics
  historyRetentionMinutes?: number
  historySampleIntervalSeconds?: number
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
  networkMode: NetworkModeName
  inputs: TemplateInput[]
  userDataTemplate: string
  isBuiltIn: boolean
  repositoryId: string | null
  architectures?: string[]
  imageByArch?: Record<string, string>
  minMemoryMB?: number | null
  requiredFeatures?: string[]
  resolvedImageSlug?: string | null
  compatible?: boolean
}

export interface TemplateCompatibilityReason {
  code: string
  message: string
}

export interface TemplateCompatibilityReport {
  compatible: boolean
  hostId: string
  hostArch: string
  resolvedImageSlug: string | null
  resolvedArch: string | null
  reasons: TemplateCompatibilityReason[]
  missingFeatures: string[]
  minMemoryMB: number | null
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
  status: 'downloading' | 'provisioning' | 'created'
  imageId: string | null
  /** Present when status is provisioning (HTTP 202) — poll GET /tasks/:taskID */
  taskID?: string | null
  vm: VM | null
}

export interface APIKeyResponse {
  id: string
  name: string
  keyPrefix: string
  expiresAt: string | null
  lastUsedAt: string | null
  createdAt: string
  kind?: 'full' | 'inference' | string
}

export interface APIKeyCreateResponse {
  id: string
  name: string
  key: string
  keyPrefix: string
  expiresAt: string | null
  createdAt: string
  kind?: 'full' | 'inference' | string
}

export interface OllamaModelLocation {
  hostId: string
  displayName?: string | null
  running: boolean
  reachable: boolean
  probedAt: string
  size?: number | null
}

export interface OllamaCatalogModel {
  name: string
  digest?: string | null
  size?: number | null
  running: boolean
  locations: OllamaModelLocation[]
}

export interface OllamaDeviceStatus {
  hostId: string
  displayName?: string | null
  installed: boolean
  reachable: boolean
  stale: boolean
  binaryPath?: string | null
  installHint: string
  probedAt?: string | null
}

export interface OllamaHomeCatalog {
  anyReachable: boolean
  anyInstalled: boolean
  refreshedAt?: string | null
  models: OllamaCatalogModel[]
  devices: OllamaDeviceStatus[]
}

export interface OllamaSettingsSnapshot {
  endpoint: string
  hasApiKey: boolean
}

export interface OllamaTaskAccepted {
  taskID: string
  hostId: string
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

/** GET /api/system/remote-access (PAS-89) */
export interface TailnetInfo {
  available: boolean
  ip?: string | null
  dnsName?: string | null
}

export interface RemoteAccessStatus {
  tailscale: TailnetInfo
  wireguard: { configured: boolean }
  advertiseUrl: string | null
  requireTailnetForRemote: boolean
}

/** GET/PUT /api/system/library/settings */
export interface LibrarySettings {
  imageDirectory: string
  isDefault: boolean
  libraryDepotHostId: string | null
}

/** Supported guest type from GET /api/system/capabilities (stable persisted IDs). */
export interface GuestTypeInfo {
  id: string
  arch: string
  machine: string
  osFamily: string
  qemuBinary: string
}

/** Per-feature support + reason from GET /api/system/capabilities (PAS-37 / PAS-94). */
export interface CapabilityDetail {
  code: string
  supported: boolean
  reasonCode?: string | null
  remediation?: string | null
}

/** Per-mode support from GET /api/system/capabilities and GET /api/networks/modes. */
export interface NetworkModeCapability {
  mode: NetworkModeName | string
  supported: boolean
  reasonCode?: string | null
  remediation?: string | null
  label?: string | null
  description?: string | null
}

/**
 * Feature flags and host facts from GET /api/system/capabilities.
 *
 * Describes the **current host** (the process serving the SPA) — a projection
 * of server-side HostInventory. The SPA calls that machine a Device (PAS-97).
 * Create-VM / Deploy may target a picked Device via /home/devices/:id/v1/*.
 * Home-wide health is GET /api/home/devices/health.
 */
export interface SystemCapabilities {
  platform: 'macOS' | 'Linux' | string
  /** VMs may use bridged networking (Linux host bridge or macOS socket_vmnet). */
  supportsBridgedNetworking: boolean
  /** Install/start/stop privileged bridge daemons (macOS only). */
  supportsManagedBridgeDaemon: boolean
  /** Linux Manage Bridges shows host-bridge setup guidance (no mutation). */
  supportsHostBridgeManagement?: boolean
  supportsUSBPassthrough: boolean
  supportsInAppUpdate: boolean
  accelerator: 'hvf' | 'kvm' | string
  hostArch: 'arm64' | 'x86_64' | string
  /** Online logical CPUs on the host (max vCPUs per VM). */
  hostCpuCount?: number
  /**
   * Guest profiles this host can run natively (PAS-48).
   * Filtered to host arch — not the full static GuestProfiles table.
   */
  guestTypes?: GuestTypeInfo[]
  /** Per-feature reason/remediation catalog (PAS-37 / PAS-94). */
  details?: CapabilityDetail[]
  inventorySchemaVersion?: number
  /**
   * Architectures this host can run natively (PAS-37).
   * Wave 0: host arch only. Do not infer from `guestTypes`.
   */
  runnableArches?: string[]
  /** Per-mode support (PAS-57 / PAS-67): nat, bridged, isolated. */
  networkModes?: NetworkModeCapability[]
}

export type HostBridgeSnapshot = {
  name: string
  enslaved: string[]
}

export type HostBridgeRemediation = {
  id: string
  label: string
  commands: string
}

export type HostBridgeReadiness = {
  helperPath: string | null
  helperSetuid: boolean
  suggestedBridge: string
  aclAllowsSuggested: boolean | null
  bridges: HostBridgeSnapshot[]
  defaultRouteInterface: string | null
  onlyUplink: boolean
  ready: boolean
  remediations?: HostBridgeRemediation[]
}

/** Alias: capabilities for the host running this BarkVisor process. */
export type CurrentHostCapabilities = SystemCapabilities

export type HomeDeviceRole = 'self' | 'member'
export type HomeDeviceReachability = 'ok' | 'unreachable'

export interface HomeDevicePlatformSummary {
  os: string
  arch: string
}

export interface HomeDeviceResourceSummary {
  cpuCount?: number | null
  memoryTotalMB?: number | null
  memoryUsedMB?: number | null
  cpuLoadPercent?: number | null
}

export interface HomeDeviceFeatureSummary {
  kvmDevice: boolean
  bridgedNetworking: boolean
  usbPassthrough: boolean
}

export interface HomeDeviceHealthSnapshot {
  hostId: string
  role: HomeDeviceRole | string
  displayName?: string | null
  fingerprint?: string | null
  agentHost?: string | null
  agentPort: number
  pairedAt?: string | null
  reachability: HomeDeviceReachability | string
  reachabilityError?: string | null
  collectedAt?: string | null
  platform?: HomeDevicePlatformSummary | null
  resources?: HomeDeviceResourceSummary | null
  features?: HomeDeviceFeatureSummary | null
  workloadCount?: number | null
  healthCounts?: Record<string, number> | null
}

export interface HomePlacementScoreRequest {
  declaredArchitectures?: string[]
  requiredFeatures?: string[]
  minMemoryMB?: number | null
  requestedMemoryMB?: number | null
}

export interface HomePlacementReason {
  code: string
  kind: 'hard' | 'soft' | string
  message: string
}

export interface HomePlacementCandidate {
  hostId: string
  displayName?: string | null
  role: string
  eligible: boolean
  recommended: boolean
  rank: number
  score: number
  reasons: HomePlacementReason[]
}

export interface HomePlacementScoreResponse {
  recommendedHostId: string | null
  candidates: HomePlacementCandidate[]
}

export interface HomeDeviceHealthTotals {
  devices: number
  reachable: number
  unreachable: number
  workloadCount: number | null
  healthCounts: Record<string, number>
}

export interface HomeDeviceHealthReport {
  devices: HomeDeviceHealthSnapshot[]
  totals: HomeDeviceHealthTotals
}
