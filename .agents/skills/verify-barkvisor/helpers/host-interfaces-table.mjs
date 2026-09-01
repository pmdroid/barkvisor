import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`host-interfaces-table.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass')
const dir = arg('dir')
mkdirSync(dir, { recursive: true })

function fail(message) {
  console.error(message)
  process.exit(1)
}

const loginRes = await fetch(`${base}/api/auth/login`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: user, password: pass }),
})
if (!loginRes.ok) fail(`login failed: HTTP ${loginRes.status}`)
const session = await loginRes.json()
const token = session.token
const auth = { Authorization: `Bearer ${token}` }

const apiIfaces = await (await fetch(`${base}/api/system/interfaces`, { headers: auth })).json()
const apiNames = (Array.isArray(apiIfaces) ? apiIfaces : apiIfaces.interfaces || []).map((row) => row.name)

const browser = await chromium.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, token)
  await page.goto(`${base}/networks`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.sidebar-nav', { timeout: 15000 })
  const hostTab = page.locator('[role="tab"]:has-text("Host interfaces")')
  await hostTab.waitFor({ state: 'visible', timeout: 15000 })
  if ((await hostTab.getAttribute('aria-selected')) !== 'true') {
    await hostTab.click()
  }
  await page.waitForSelector('.iface-row', { timeout: 15000 })

  const rows = await page.locator('.iface-row').evaluateAll((trs) =>
    trs.map((tr) => {
      const cells = [...tr.querySelectorAll('td')].map((td) => td.innerText.trim())
      const hasDevice = cells.length >= 6
      return {
        device: hasDevice ? cells[0] : '',
        name: hasDevice ? cells[1] : cells[0],
        role: hasDevice ? cells[2] : cells[1],
        addresses: hasDevice ? cells[3] : cells[2],
        bridge: hasDevice ? cells[4] : cells[3],
        route: hasDevice ? cells[5] : cells[4],
      }
    }),
  )

  const shot = `${dir}/host-interfaces-table.png`
  await page.screenshot({ path: shot, fullPage: true })

  const names = rows.map((row) => row.name)
  const appleBridges = names.filter((name) => /^bridge\d+$/i.test(name))
  const loopbacks = names.filter((name) => name === 'lo' || name === 'lo0')
  const roleNorm = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase()
  const en0 = rows.find((row) => row.name === 'en0')
  const enUplinksAsBridge = rows.filter((row) => /^en\d+$/i.test(row.name) && roleNorm(row.role) === 'bridge')

  const failures = []
  if (appleBridges.length) failures.push(`Apple vmnet bridges listed: ${appleBridges.join(', ')}`)
  if (loopbacks.length) failures.push(`loopback listed: ${loopbacks.join(', ')}`)
  if (en0 && roleNorm(en0.role) !== 'uplink') failures.push(`en0 role is ${en0.role}, expected Uplink`)
  if (enUplinksAsBridge.length) {
    failures.push(`physical en* labeled Bridge: ${enUplinksAsBridge.map((row) => `${row.name}=${row.role}`).join(', ')}`)
  }
  if (!names.includes('en0') && apiNames.includes('en0')) {
    failures.push('API has en0 but table hid it')
  }

  const result = {
    ok: failures.length === 0,
    url: base,
    apiNames,
    rows,
    failures,
    screenshot: shot,
  }
  writeFileSync(`${dir}/table.json`, JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result, null, 2))
  if (failures.length) process.exit(1)
} finally {
  await browser.close()
}
