import { describe, expect, test } from 'bun:test'
import { appOpenUrl, firstOpenUrl, isApplicationWorkload, workloadKindLabel } from './workloadKind'

describe('workloadKind', () => {
  test('Application kind is App', () => {
    const vm = { kind: 'Application', spec: { apiVersion: 'barkvisor.dev/v1', kind: 'Application', metadata: { name: 'x' }, spec: {} } }
    expect(isApplicationWorkload(vm)).toBe(true)
    expect(workloadKindLabel(vm)).toBe('App')
  })

  test('VirtualMachine kind is VM', () => {
    const vm = { kind: 'VirtualMachine', spec: { apiVersion: 'barkvisor.dev/v1', kind: 'VirtualMachine', metadata: { name: 'x' }, spec: { resources: { cpu: 1, memoryMb: 512 } } } }
    expect(isApplicationWorkload(vm)).toBe(false)
    expect(workloadKindLabel(vm)).toBe('VM')
  })

  test('open URL prefers openUrl then publishedPorts', () => {
    expect(firstOpenUrl({ openUrl: 'http://127.0.0.1:8080', publishedPorts: [] })).toBe('http://127.0.0.1:8080')
    expect(firstOpenUrl({
      openUrl: null,
      publishedPorts: [{ hostPort: 80, containerPort: 80, proto: 'tcp', url: 'http://127.0.0.1:80' }],
    })).toBe('http://127.0.0.1:80')
  })

  test('prefix Open UI is Device go path and Home hop for members', () => {
    const vm = {
      id: 'app-1',
      openUrl: 'http://192.168.1.20:7777/go/app-1/',
      publishedPorts: [{ hostPort: 80, containerPort: 80, proto: 'tcp', url: 'http://192.168.1.20:80' }],
      ingress: { enabled: true, mode: 'prefix' },
    }
    expect(appOpenUrl(vm, { hostId: 'self', role: 'self' })).toBe('/go/app-1/')
    expect(appOpenUrl(vm, { hostId: 'member-1', role: 'member' })).toBe('/home/devices/member-1/go/app-1/')
    expect(appOpenUrl({ ...vm, ingress: { enabled: false, mode: 'prefix' } }, { hostId: 'self', role: 'self' }))
      .toBe('http://192.168.1.20:7777/go/app-1/')
  })
})
