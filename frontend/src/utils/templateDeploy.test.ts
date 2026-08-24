import { describe, expect, test } from 'bun:test'
import { natWebUILinks, templateDeclaresSshKeys } from './templateDeploy'

describe('templateDeploy', () => {
  test('SSH picker follows a declared ssh_keys input', () => {
    expect(templateDeclaresSshKeys([{ id: 'username' }, { id: 'ssh_keys' }])).toBe(true)
    expect(templateDeclaresSshKeys([{ id: 'ollama_url' }])).toBe(false)
    expect(templateDeclaresSshKeys([])).toBe(false)
  })

  test('Open links are This Device NAT with httpPath only', () => {
    const onyx = natWebUILinks({
      templateName: 'Onyx',
      networkMode: 'nat',
      isSelfDevice: true,
      portForwards: [{ protocol: 'tcp', hostPort: 80, httpPath: '/' }],
    })
    expect(onyx).toEqual([{ href: 'http://127.0.0.1/', label: 'Open Onyx' }])
    expect(
      natWebUILinks({
        templateName: 'Onyx',
        networkMode: 'nat',
        isSelfDevice: false,
        portForwards: [{ protocol: 'tcp', hostPort: 80, httpPath: '/' }],
      }),
    ).toEqual([])
    expect(
      natWebUILinks({
        templateName: 'Pi-hole',
        networkMode: 'bridged',
        isSelfDevice: true,
        portForwards: [{ protocol: 'tcp', hostPort: 80, httpPath: '/admin/login' }],
      }),
    ).toEqual([])
    expect(
      natWebUILinks({
        templateName: 'Home Assistant OS',
        networkMode: 'nat',
        isSelfDevice: true,
        portForwards: [{ protocol: 'tcp', hostPort: 8123, httpPath: '/' }],
      }),
    ).toEqual([{ href: 'http://127.0.0.1:8123/', label: 'Open Home Assistant OS' }])
  })
})
