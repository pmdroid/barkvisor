import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`linux-host-interfaces-flow.mjs: missing --${name}`)
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
const { token } = await loginRes.json()
const auth = { Authorization: `Bearer ${token}` }

const apiIfaces = await (await fetch(`${base}/api/system/interfaces`, { headers: auth })).json()
const apiRows = (Array.isArray(apiIfaces) ? apiIfaces : []).map((row) => ({
  name: row.name,
  operState: row.operState ?? null,
  carrier: row.carrier ?? null,
  ipAddress: row.ipAddress,
  addresses: row.addresses ?? [],
}))

const browser = await chromium.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, token)
  await page.goto(`${base}/networks`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.iface-row', { timeout: 20000 })

  const tableRows = await page.locator('.iface-row').evaluateAll((trs) =>
    trs.map((tr) => {
      const cells = [...tr.querySelectorAll('td')].map((td) => td.innerText.trim())
      const hasDevice = cells.length >= 6
      return {
        device: hasDevice ? cells[0] : '',
        name: hasDevice ? cells[1] : cells[0],
        role: hasDevice ? cells[2] : cells[1],
        link: hasDevice ? cells[3] : cells[2],
        addresses: hasDevice ? cells[4] : cells[3],
      }
    }),
  )

  const names = tableRows.map((row) => row.name)
  const failures = []
  for (const need of ['br0', 'enp1s0', 'enp2s0']) {
    if (!names.includes(need)) failures.push(`table missing ${need} (got ${names.join(', ')})`)
  }
  const enp1 = tableRows.find((row) => row.name === 'enp1s0')
  const enp2 = tableRows.find((row) => row.name === 'enp2s0')
  if (enp1 && !/unplugged|no cable|down/i.test(enp1.link)) {
    failures.push(`enp1s0 Link should show unplugged/down, got ${enp1.link}`)
  }
  if (enp2 && !/plugged|up/i.test(enp2.link)) {
    failures.push(`enp2s0 Link should show plugged/up, got ${enp2.link}`)
  }

  const tableShot = `${dir}/01-host-interfaces.png`
  await page.screenshot({ path: tableShot, fullPage: true })

  const editTarget = names.includes('enp2s0') ? 'enp2s0' : names.includes('br0') ? 'br0' : names[0]
  await page.locator('.iface-row').filter({ has: page.locator('strong.mono', { hasText: new RegExp(`^${editTarget}$`) }) }).click()
  const drawer = page.locator('.iface-drawer')
  await drawer.waitFor({ state: 'visible', timeout: 15000 })

  const drawerText = await drawer.innerText()
  const aliasSelect = await drawer.locator('select option[value="alias"]').count()
  if (aliasSelect > 0) failures.push('Drawer still exposes static/alias dropdown')

  const addBtn = drawer.locator('button:has-text("Add address")')
  const hasEditor = (await addBtn.count()) > 0
  let extraAfterAdd = null
  let applyEnabled = null
  if (hasEditor) {
    if (await addBtn.isDisabled()) failures.push('Add address disabled')
    else {
      await addBtn.click()
      const additional = drawer.locator('.address-row input[placeholder="192.168.1.20/24"]')
      await additional.last().fill('10.20.30.40/24')
      extraAfterAdd = await additional.last().inputValue()
    }
    const applyBtn = drawer.getByRole('button', { name: 'Apply addresses' })
    applyEnabled = await applyBtn.isEnabled().catch(() => false)
  }

  const drawerShot = `${dir}/02-drawer.png`
  await page.screenshot({ path: drawerShot, fullPage: true })

  const checkBody = {
    action: 'check',
    interface: editTarget,
    addresses: [
      { kind: 'static', cidr: '192.168.30.1/16' },
      { kind: 'alias', cidr: '10.20.30.40/24' },
    ],
    gateway: '192.168.8.1',
  }
  const checkRes = await fetch(`${base}/api/system/bridges`, {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify(checkBody),
  })
  const checkText = await checkRes.text()
  let checkResponse = null
  try { checkResponse = JSON.parse(checkText) } catch { checkResponse = { raw: checkText } }
  const checkBlob = checkText.toLowerCase()
  if (checkBlob.includes('socket_vmnet')) failures.push(`check plans socket_vmnet: ${checkText.slice(0, 400)}`)

  const result = {
    ok: failures.length === 0,
    apiRows,
    tableRows,
    editTarget,
    hasEditor,
    extraAfterAdd,
    applyEnabled,
    checkStatus: checkRes.status,
    check: checkResponse,
    failures,
    screenshots: { tableShot, drawerShot },
  }
  writeFileSync(`${dir}/result.json`, JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result, null, 2))
  if (failures.length) process.exit(1)
} finally {
  await browser.close()
}
