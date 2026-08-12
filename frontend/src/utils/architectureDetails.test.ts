import { describe, expect, test } from 'bun:test'
import {
  architectureIsProblem,
  architectureLabel,
  defaultMachineType,
  shouldRevealArchitectureDetails,
} from './architectureDetails'

describe('shouldRevealArchitectureDetails', () => {
  test('hidden for the default same-arch path', () => {
    expect(
      shouldRevealArchitectureDetails({ alwaysShow: false, customized: false, problem: false }),
    ).toBe(false)
  })

  test('shown when the user asked to always show, customized, or hit a problem', () => {
    expect(
      shouldRevealArchitectureDetails({ alwaysShow: true, customized: false, problem: false }),
    ).toBe(true)
    expect(
      shouldRevealArchitectureDetails({ alwaysShow: false, customized: true, problem: false }),
    ).toBe(true)
    expect(
      shouldRevealArchitectureDetails({ alwaysShow: false, customized: false, problem: true }),
    ).toBe(true)
  })
})

describe('architectureIsProblem', () => {
  test('empty guest is not a problem', () => {
    expect(architectureIsProblem(null, false)).toBe(false)
    expect(architectureIsProblem('', false)).toBe(false)
  })

  test('follows host-runnable signal', () => {
    expect(architectureIsProblem('arm64', true)).toBe(false)
    expect(architectureIsProblem('x86_64', false)).toBe(true)
  })
})

describe('architectureLabel / defaultMachineType', () => {
  test('labels common arches', () => {
    expect(architectureLabel('arm64')).toBe('ARM64')
    expect(architectureLabel('aarch64')).toBe('ARM64')
    expect(architectureLabel('x86_64')).toBe('x86_64')
    expect(architectureLabel('amd64')).toBe('x86_64')
  })

  test('machine type follows guest arch', () => {
    expect(defaultMachineType('linux-arm64')).toBe('virt')
    expect(defaultMachineType('windows-arm64')).toBe('virt')
    expect(defaultMachineType('linux-amd64')).toBe('q35')
    expect(defaultMachineType('linux-x86_64')).toBe('q35')
    expect(defaultMachineType('x86_64')).toBe('q35')
  })
})
