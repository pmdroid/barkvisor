import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'
import { redactPage } from './redactPage.mjs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`device-terminal-flow.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass', '')
const dir = arg('dir')
const tokenArg = arg('token', '')

mkdirSync(dir, { recursive: true })

let token = tokenArg
if (!token) {
  const loginRes = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: user, password: pass }),
  })
  if (!loginRes.ok) {
    console.error(`login failed: HTTP ${loginRes.status}`)
    process.exit(1)
  }
  token = (await loginRes.json()).token
}
const authHeader = { Authorization: `Bearer ${token}` }

const health = await (await fetch(`${base}/api/home/devices/health`, { headers: authHeader })).json()
const self = (health.devices || health || []).find?.((row) => row.role === 'self')
  || (Array.isArray(health) ? health.find((row) => row.role === 'self') : null)
const devices = health.devices || health.report?.devices || []
const selfDevice = devices.find((row) => row.role === 'self') || devices[0]
if (!selfDevice?.hostId) {
  writeFileSync(`${dir}/health.json`, JSON.stringify(health, null, 2))
  console.error('no self Device in health')
  process.exit(1)
}

const usersRes = await fetch(`${base}/api/system/users`, { headers: authHeader })
const users = usersRes.ok ? await usersRes.json() : { status: usersRes.status, body: await usersRes.text() }
writeFileSync(`${dir}/users.json`, JSON.stringify(users, null, 2))
const userNames = Array.isArray(users) ? users.map((row) => row.name) : []
const hasRoot = userNames.includes('root')

const browser = await chromium.launch()
let pickerShot = null
let openShot = null
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, token)
  await page.goto(`${base}/devices/${encodeURIComponent(selfDevice.hostId)}`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.ops-toolbar', { timeout: 15000 })
  await page.getByRole('button', { name: 'Terminal' }).click()
  await page.waitForSelector('.terminal-modal', { timeout: 10000 })
  const box = await page.locator('.terminal-modal').boundingBox()
  const vp = page.viewportSize()
  if (!box || !vp || box.width < vp.width - 24 || box.height < vp.height - 24) {
    console.error(`terminal-modal too small: ${box?.width}x${box?.height} viewport ${vp?.width}x${vp?.height}`)
    process.exit(1)
  }
  pickerShot = `${dir}/picker.png`
  await redactPage(page)
  await page.screenshot({ path: pickerShot, fullPage: true })

  if (userNames.length) {
    await page.getByRole('button', { name: 'Open' }).click()
    await page.getByRole('button', { name: 'Open' }).last().click()
    await page.waitForSelector('.terminal-term', { timeout: 15000 })
    await page.waitForTimeout(1500)
    openShot = `${dir}/open.png`
    await redactPage(page)
    await page.screenshot({ path: openShot, fullPage: true })
  }
} finally {
  await browser.close()
}

const auditRes = await fetch(`${base}/api/audit-log`, { headers: authHeader })
const audit = auditRes.ok ? await auditRes.json() : null
writeFileSync(`${dir}/audit.json`, JSON.stringify(audit, null, 2))
const auditRows = Array.isArray(audit) ? audit : audit?.entries || audit?.items || []
const opened = Array.isArray(auditRows)
  ? auditRows.some((row) => row.action === 'device.terminal.open')
  : false

console.log(JSON.stringify({
  ok: usersRes.ok && !hasRoot && Boolean(pickerShot),
  hostId: selfDevice.hostId,
  users: userNames,
  hasRoot,
  usersStatus: usersRes.status,
  pickerShot,
  openShot,
  opened,
}))
