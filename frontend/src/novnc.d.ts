declare module '@novnc/novnc/lib/rfb.js' {
  export default class RFB {
    constructor(target: HTMLElement, url: string, options?: Record<string, any>)
    scaleViewport: boolean
    resizeSession: boolean
    disconnect(): void
    addEventListener(event: string, handler: (...args: any[]) => void): void
  }
}
