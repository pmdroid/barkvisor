export const UNSLOTH_INSTALL_HINT = 'Install Unsloth with: curl -fsSL https://unsloth.ai/install.sh | sh'
export const UNSLOTH_INSTALL_COMMAND = 'curl -fsSL https://unsloth.ai/install.sh | sh'
export const UNSLOTH_STAGE_DIR = 'unsloth/models'
export const UNSLOTH_STAGE_HINT =
  "Put GGUF weights in this Device's BarkVisor data dir under unsloth/models"

export type UnslothInstallStep = {
  title: string
  command?: string
}

export function unslothInstallSteps(installed: boolean): UnslothInstallStep[] {
  if (!installed) {
    return [
      { title: UNSLOTH_INSTALL_HINT, command: UNSLOTH_INSTALL_COMMAND },
      { title: UNSLOTH_STAGE_HINT },
    ]
  }
  return [{ title: UNSLOTH_STAGE_HINT }]
}
