declare module '@novnc/novnc/lib/rfb.js' {
  export default class RFB {
    constructor(target: HTMLElement, url: string, options?: Record<string, any>)
    scaleViewport: boolean
    resizeSession: boolean
    clipViewport: boolean
    focusOnClick: boolean
    showDotCursor: boolean
    qualityLevel: number
    compressionLevel: number
    disconnect(): void
    focus(): void
    sendCtrlAltDel(): void
    clipboardPasteFrom(text: string): void
    addEventListener(event: string, handler: (...args: any[]) => void): void
    removeEventListener(event: string, handler: (...args: any[]) => void): void
  }
}
