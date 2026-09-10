import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`create-app-flow.mjs: missing --${name}`)
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

const browser = await chromium.launch()
const errors = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  page.on('pageerror', (e) => errors.push(String(e)))
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, token)
  await page.goto(`${base}/vms`, { waitUntil: 'networkidle' })
  await page.getByRole('button', { name: 'Create App' }).first().click()
  await page.waitForSelector('.mag-frame, h2:has-text("Create App")', { timeout: 10_000 })
  await page.waitForTimeout(800)
  const gallery = join(dir, 'create-app-gallery.png')
  await page.screenshot({ path: gallery, fullPage: true })
  const cards = page.locator('.mag-card')
  const n = await cards.count()
  let configure = null
  if (n > 0) {
    await cards.first().click()
    await page.waitForTimeout(800)
    configure = join(dir, 'create-app-configure.png')
    await page.screenshot({ path: configure, fullPage: true })
  }
  const before = await fetch(`${base}/api/vms`, { headers: { Authorization: `Bearer ${token}` } })
  const list = before.ok ? await before.json() : []
  const result = {
    ok: errors.length === 0,
    gallery,
    configure,
    catalogCards: n,
    workloads: Array.isArray(list) ? list.length : 0,
    pageErrors: errors,
  }
  writeFileSync(join(dir, 'result.json'), JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result))
  if (!result.ok) process.exit(1)
} finally {
  await browser.close()
}
