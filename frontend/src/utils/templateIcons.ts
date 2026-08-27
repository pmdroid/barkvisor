export const templateIconPaths: Record<string, string> = {
  terminal: 'M4 17l6-6-6-6M12 19h8',
  code: 'M16 18l6-6-6-6M8 6l-6 6 6 6',
  container: 'M21 16V8a2 2 0 00-1-1.73l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.73l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z',
  home: 'M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z M9 22V12h6v10',
  shield: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z',
  cloud: 'M18 10h-1.26A8 8 0 109 20h9a5 5 0 000-10z',
}

export const templateIconColors: Record<string, { bg: string; fg: string }> = {
  terminal: { bg: 'rgba(233,84,32,.16)', fg: '#e95420' },
  code: { bg: 'rgba(52,211,153,.14)', fg: '#34d399' },
  container: { bg: 'rgba(65,189,245,.14)', fg: '#41bdf5' },
  home: { bg: 'rgba(65,189,245,.14)', fg: '#41bdf5' },
  shield: { bg: 'rgba(248,113,113,.14)', fg: '#f87171' },
  cloud: { bg: 'rgba(0,144,248,.14)', fg: '#0090f8' },
}

export function templateIconPath(icon: string): string {
  return templateIconPaths[icon] || templateIconPaths.terminal
}

export function templateIconStyle(icon: string): { background: string; color: string } {
  const colors = templateIconColors[icon] || templateIconColors.terminal
  return { background: colors.bg, color: colors.fg }
}
