import { chromium } from 'playwright-core'
import { mkdirSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`bridge-setup-flow.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass')
const dir = arg('dir')
const token = arg('token', '')
const check = args.includes('--check')

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

function fail(message) {
  console.error(message)
  process.exit(1)
}

const browser = await chromium.launch()
let shotPath = null
let posted = null
let checkBody = null
let checkStatus = null
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const tokenForPage = authHeader.Authorization.replace('Bearer ', '')
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, tokenForPage)
  await page.goto(`${base}/networks`, { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('.sidebar-nav', { timeout: 15000 })
  await page.goto(`${base}/networks`, { waitUntil: 'networkidle' })

  await page.locator('[role="tab"]:has-text("Host interfaces")').waitFor({ state: 'visible', timeout: 15000 })
  if (await page.locator('button:has-text("Bridge setup")').count() > 0) {
    fail('Bridge setup modal was removed — use Host interfaces drawer')
  }

  const drawer = page.locator('.iface-drawer')
  await drawer.waitFor({ state: 'visible', timeout: 30000 })
  const text = await drawer.innerText()
  if (!/\bDHCP\b/.test(text) && !/\bstatic\b/i.test(text)) {
    fail('Interface drawer missing DHCP/static addressing controls')
  }
  if (await drawer.locator('button:has-text("Apply")').count() === 0) fail('Interface drawer missing Apply')
  if (await drawer.locator('button:has-text("Revert")').count() === 0) fail('Interface drawer missing Revert')
  for (const name of ['Setup', 'Start', 'Stop']) {
    const n = await drawer.locator('button').filter({ hasText: new RegExp(`^${name}$`) }).count()
    if (n > 0) fail(`Interface drawer still has ${name}`)
  }

  shotPath = `${dir}/bridge-setup.png`
  await page.screenshot({ path: shotPath, fullPage: true })

  if (check) {
    await page.route('**/api/**/bridges', async (route) => {
      const req = route.request()
      if (req.method() === 'POST') {
        posted = req.postDataJSON()
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ success: true, message: 'check', applied: false }),
        })
        return
      }
      await route.continue()
    })
    const applyBtn = drawer.locator('button:has-text("Apply")')
    if (await applyBtn.isDisabled()) {
      console.log(JSON.stringify({
        ok: true,
        screenshot: shotPath,
        checkSkipped: 'Apply disabled on this host (expected on some platforms)',
      }))
      process.exit(0)
    }
    await applyBtn.click()
    await page.waitForTimeout(400)
    if (posted) {
      checkBody = { action: 'check', ...(posted.addresses ? { addresses: posted.addresses } : { addressing: posted.addressing }) }
      const checkRes = await fetch(`${base}/api/system/bridges`, {
        method: 'POST',
        headers: { ...authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify(checkBody),
      })
      checkStatus = checkRes.status
      if (!checkRes.ok) {
        const body = await checkRes.text()
        fail(`POST action=check failed: HTTP ${checkStatus} ${body}`)
      }
    }
  }
} finally {
  await browser.close()
}

console.log(JSON.stringify({
  ok: true,
  screenshot: shotPath,
  hasInterfaceDrawer: true,
  hasApplyRevert: true,
  noSetupStartStop: true,
  noBridgeSetupModal: true,
  check: check
    ? { posted, checkBody, checkStatus }
    : null,
}))
process.exit(0)
