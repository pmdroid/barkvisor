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

/** This computer → guest: read the system clipboard (needs a user gesture). */
export async function readLocalClipboard(): Promise<string | null> {
  if (!navigator.clipboard?.readText) return null
  try {
    return await navigator.clipboard.readText()
  } catch {
    return null
  }
}

export function textFromPasteEvent(event: ClipboardEvent): string {
  const plain = event.clipboardData?.getData('text/plain')
  if (plain) return plain
  return event.clipboardData?.getData('text') ?? ''
}
