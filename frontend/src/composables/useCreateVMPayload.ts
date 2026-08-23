import type { CreateVMRequest, PortForwardRule, USBPassthroughDevice } from '../api/types'

export interface CreateVMPayloadInput {
  name: string
  osFamily: 'linux' | 'windows'
  cpuCount: number
  memoryMB: number
  archCustomized: boolean
  vmType: string
  uefiCustomized: boolean
  uefi: boolean
  tpmCustomized: boolean
  tpmEnabled: boolean
  diskSource: 'new' | 'existing'
  existingDiskId: string
  diskSizeGB: number
  mode: 'iso' | 'cloud'
  imageId?: string | null
  sshAuthorizedKeys: string[]
  userData: string
  displayResolution: string
  selectedNetworkId: string
  portForwards: PortForwardRule[]
  sharedPaths: string[]
  usbAvailable: boolean
  usbDevices: USBPassthroughDevice[]
  workloadClass?: 'house' | 'agent'
}

/** Assemble CreateVMRequest. Guest-type (`vmType`) is a call-site value, not resolved here (PAS-241). */
export function buildCreateVMPayload(input: CreateVMPayloadInput): CreateVMRequest {
  const req: CreateVMRequest = {
    name: input.name.trim(),
    osFamily: input.osFamily,
    cpuCount: input.cpuCount,
    memoryMB: input.memoryMB,
  }
  if (input.archCustomized) req.vmType = input.vmType
  if (input.uefiCustomized) req.uefi = input.uefi
  if (input.tpmCustomized) req.tpmEnabled = input.tpmEnabled
  if (input.diskSource === 'existing') {
    req.existingDiskId = input.existingDiskId
  } else {
    req.diskSizeGB = input.diskSizeGB
  }
  const imageId = input.imageId
  if (input.mode === 'iso') {
    if (imageId) req.isoId = imageId
  } else {
    if (imageId) req.cloudImageId = imageId
    const keys = input.sshAuthorizedKeys
    const userData = input.userData.trim()
    if (keys.length || userData) {
      req.cloudInit = {
        sshAuthorizedKeys: keys.length ? keys : undefined,
        userData: userData || undefined,
      }
    }
  }
  if (input.displayResolution !== '1280x800') req.displayResolution = input.displayResolution
  if (input.selectedNetworkId) req.networkId = input.selectedNetworkId
  if (input.portForwards.length > 0) req.portForwards = input.portForwards
  if (input.sharedPaths.length > 0) req.sharedPaths = input.sharedPaths
  if (input.usbAvailable && input.usbDevices.length > 0 && input.workloadClass !== 'agent') {
    req.usbDevices = input.usbDevices
  }
  if (input.workloadClass === 'agent') {
    req.workloadClass = 'agent'
    delete req.usbDevices
    delete req.portForwards
    delete req.sharedPaths
    if (input.selectedNetworkId) {
      // Bridged is rejected server-side; still send a chosen NAT/isolated id.
      req.networkId = input.selectedNetworkId
    }
  }
  return req
}

export function useCreateVMPayload() {
  return { buildCreateVMPayload }
}
