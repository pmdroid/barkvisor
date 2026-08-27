import { describe, expect, test } from 'bun:test'
import {
  collectTemplateDeployInputs,
  natWebUILinks,
  templateDeclaresSshKeys,
  templateRequiresSshKeys,
} from './templateDeploy'

describe('templateDeploy', () => {
  test('SSH picker follows a declared ssh_keys input', () => {
    expect(templateDeclaresSshKeys([{ id: 'username' }, { id: 'ssh_keys' }])).toBe(true)
    expect(templateDeclaresSshKeys([{ id: 'ollama_url' }])).toBe(false)
    expect(templateDeclaresSshKeys([])).toBe(false)
  })

  test('SSH is required only when the recipe says so', () => {
    expect(templateRequiresSshKeys([{ id: 'ssh_keys', required: true }])).toBe(true)
    expect(templateRequiresSshKeys([{ id: 'ssh_keys', required: false }])).toBe(false)
    expect(templateRequiresSshKeys([{ id: 'password', required: true }])).toBe(false)
  })

  test('deploy inputs skip empty password and attach SSH', () => {
    expect(
      collectTemplateDeployInputs(
        [
          { id: 'username', default: 'debian', required: true },
          { id: 'password', required: true },
          { id: 'ssh_keys', required: true },
        ],
        { sshAuthorizedKey: 'ssh-ed25519 AAAA' },
      ),
    ).toEqual({ username: 'debian', ssh_keys: 'ssh-ed25519 AAAA' })
    expect(
      collectTemplateDeployInputs(
        [
          { id: 'username', default: 'pihole' },
          { id: 'password', required: true },
        ],
        { values: { username: 'pihole', password: 'secret' } },
      ),
    ).toEqual({ username: 'pihole', password: 'secret' })
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
