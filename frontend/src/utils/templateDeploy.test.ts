import { describe, expect, test } from 'bun:test'
import {
  collectTemplateDeployInputs,
  natWebUILinks,
  templateDeclaresSshKeys,
  templateInputsComplete,
  templateRequiresSshKeys,
  buildDeployRecipe,
  visibleTemplateInputs,
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

  test('visible inputs hide ssh_keys', () => {
    expect(visibleTemplateInputs([
      { id: 'password' },
      { id: 'ssh_keys' },
    ]).map((input) => input.id)).toEqual(['password'])
  })

  test('required template input blocks until filled', () => {
    const defs = [
      { id: 'username', default: 'ubuntu', required: true },
      { id: 'password', required: true, minLength: 8 },
      { id: 'ssh_keys', required: true },
    ]
    expect(templateInputsComplete(defs, { username: 'ubuntu', password: '' })).toBe(false)
    expect(templateInputsComplete(defs, { username: 'ubuntu', password: 'short' })).toBe(false)
    expect(templateInputsComplete(defs, { username: 'ubuntu', password: 'secret12' })).toBe(true)
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

  test('recipe uses catalog image for the target arch', () => {
    const template = {
      name: 'Fedora Cloud',
      slug: 'fedora-cloud',
      inputs: [{ id: 'ssh_keys', label: 'SSH', type: 'textarea' as const, required: true }],
      userDataTemplate: 'lock_passwd: true',
      cpuCount: 2,
      memoryMB: 2048,
      diskSizeGB: 16,
      networkMode: 'nat' as const,
      portForwards: null,
      architectures: ['arm64', 'x86_64'],
      catalogImages: [
        {
          slug: 'fedora-arm64',
          name: 'Fedora',
          imageType: 'cloud-image',
          arch: 'arm64',
          downloadUrl: 'https://example.test/fedora-arm64.qcow2',
          sha256: 'aaa',
        },
        {
          slug: 'fedora-x86_64',
          name: 'Fedora',
          imageType: 'cloud-image',
          arch: 'x86_64',
          downloadUrl: 'https://example.test/fedora-x86_64.qcow2',
          sha256: 'bbb',
        },
      ],
    }
    const recipe = buildDeployRecipe(template, 'aarch64')
    expect(recipe?.image.downloadUrl).toBe('https://example.test/fedora-arm64.qcow2')
    expect(recipe?.image.sha256).toBe('aaa')
    expect(recipe?.image.arch).toBe('arm64')
    expect(recipe?.inputs[0].id).toBe('ssh_keys')
    expect(buildDeployRecipe(template, 'riscv64')).toBeUndefined()
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
