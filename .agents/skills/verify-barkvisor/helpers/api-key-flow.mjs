import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`api-key-flow.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass', '')
const keyName = arg('key-name', 'verify-proof')
const dir = arg('dir')
const token = arg('token', '')

mkdirSync(dir, { recursive: true })
let authHeader
if (token) {
  authHeader = { Authorization: `Bearer ${token}` }
} else {
  const loginRes = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: user, password: pass }),
  })
  if (!loginRes.ok) {
    console.error(`login failed: HTTP ${loginRes.status}`)
    process.exit(1)
  }
  authHeader = { Authorization: `Bearer ${(await loginRes.json()).token}` }
}

const browser = await chromium.launch()
let secret = null
let shotShown = null
let shotModal = null
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const tokenForPage = authHeader.Authorization.replace('Bearer ', '')
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, tokenForPage)
  await page.goto(`${base}/settings?tab=apikeys`, { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('.sidebar-nav', { timeout: 15000 })
  await page.goto(`${base}/settings?tab=apikeys`, { waitUntil: 'networkidle' })

  await page.click('button:has-text("Create Key")')
  await page.fill('input[placeholder="e.g. terraform, ci-pipeline"]', keyName)
  await page.locator('.modal button:has-text("Create")').last().click()
  await page.waitForSelector('h2:has-text("API Key Created")', { timeout: 10000 })
  secret = (await page.locator('.modal div[style*="word-break"]').innerText()).trim()

  shotShown = `${dir}/secret-shown.png`
  await page.screenshot({ path: shotShown, fullPage: true })
  writeFileSync(`${dir}/show-once-secret.txt`, `${secret}\n`)

  await page.click('.modal button:has-text("Done")')
  await page.waitForSelector('.modal', { state: 'detached' })
  await page.waitForTimeout(500)
  shotModal = `${dir}/keys-table.png`
  await page.screenshot({ path: shotModal, fullPage: true })
} finally {
  await browser.close()
}

const list = await (await fetch(`${base}/api/auth/keys`, { headers: authHeader })).json()
const row = Array.isArray(list) ? list.find((k) => k.name === keyName) : null

console.log(JSON.stringify({
  ok: row != null,
  keyName,
  secretShown: Boolean(secret),
  secretPrefix: secret ? `${secret.slice(0, 8)}…` : null,
  serverRow: row ? { name: row.name, kind: row.kind ?? 'full', prefix: row.keyPrefix } : null,
  screenshots: [shotShown, shotModal],
}))
process.exit(row ? 0 : 1)
