/** Guest → this computer: write VNC cut-buffer text to the system clipboard. */
export async function copyGuestText(text: string): Promise<boolean> {
  const value = text ?? ''
  if (!value) return false
  if (!navigator.clipboard?.writeText) return false
  try {
    await navigator.clipboard.writeText(value)
    return true
  } catch {
    return false
  }
}

export type LocalClipboardRead =
  | { status: 'ok'; text: string }
  | { status: 'unsupported' }
  | { status: 'denied' }

/** This computer → guest: read the system clipboard (needs a user gesture). */
export async function readLocalClipboard(): Promise<LocalClipboardRead> {
  if (!navigator.clipboard?.readText) return { status: 'unsupported' }
  try {
    return { status: 'ok', text: await navigator.clipboard.readText() }
  } catch {
    return { status: 'denied' }
  }
}

export function textFromPasteEvent(event: ClipboardEvent): string {
  const plain = event.clipboardData?.getData('text/plain')
  if (plain) return plain
  return event.clipboardData?.getData('text') ?? ''
}
