export function hostnameFromVMName(name: string): string {
  let slug = name.trim().toLowerCase().replace(/\s+/g, '-')
  slug = slug.replace(/[^a-z0-9-]/g, '')
  slug = slug.replace(/-+/g, '-').replace(/^-+|-+$/g, '')
  if (slug.length > 63) slug = slug.slice(0, 63).replace(/-+$/g, '')
  return slug || 'vm'
}

export function defaultVMNameFromLabel(label: string): string {
  return `${hostnameFromVMName(label)}-1`
}
