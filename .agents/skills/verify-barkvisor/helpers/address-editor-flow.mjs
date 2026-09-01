import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`address-editor-flow.mjs: missing --${name}`)
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

const browser = await chromium.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, token)
  await page.goto(`${base}/networks`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.iface-row', { timeout: 15000 })
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
  const en0Row = tableRows.find((row) => row.name === 'en0')
  if (!en0Row) fail(`en0 missing from table: ${JSON.stringify(tableRows)}`)
  if (!en0Row.link || en0Row.link === '—') fail(`en0 Link empty: ${en0Row.link}`)
  const en0 = page.locator('.iface-row', { hasText: 'en0' })
  if (await en0.count() === 0) fail('en0 row missing')
  await en0.click()
  const drawer = page.locator('.iface-drawer')
  await drawer.waitFor({ state: 'visible', timeout: 15000 })

  const asLoaded = `${dir}/01-drawer-as-loaded.png`
  await page.screenshot({ path: asLoaded, fullPage: true })

  const aliasSelect = drawer.locator('select option[value="alias"]')
  const staticSelect = drawer.locator('select option[value="static"]')
  if (await aliasSelect.count() > 0 || await staticSelect.count() > 0) {
    fail('Drawer still exposes static/alias dropdown')
  }
  const drawerText = await drawer.innerText()
  if (/\balias\b/i.test(drawerText) && !drawerText.includes('additional')) {
    fail(`Drawer text still mentions alias: ${drawerText.slice(0, 400)}`)
  }

  const dhcp = drawer.locator('.dhcp-row input[type="checkbox"]')
  if (!(await dhcp.isEnabled())) fail('DHCP checkbox disabled — cannot edit addresses')
  if (!(await dhcp.isChecked())) fail('Expected DHCP on for live en0')

  const extraInputs = drawer.locator('.address-row input')
  const extraValues = await extraInputs.evaluateAll((els) =>
    els.map((el) => /** @type {HTMLInputElement} */ (el).value),
  )
  if (!extraValues.some((value) => /^\d+\.\d+\.\d+\.\d+\//.test(value))) {
    fail(`Expected IP CIDRs in address rows, got ${JSON.stringify(extraValues)}`)
  }
  const labels = await drawer.locator('.row-label').evaluateAll((els) => els.map((el) => el.textContent.trim()))
  if (labels.some((label) => /alias|static/i.test(label))) {
    fail(`Row labels still use alias/static: ${JSON.stringify(labels)}`)
  }
  if (!labels.includes('Primary address')) fail('Primary address row missing while DHCP is on')

  const primary = drawer.locator('.address-row input[placeholder="192.168.1.10/24"]')
  await primary.waitFor({ state: 'visible', timeout: 5000 })
  const lease = await primary.inputValue()
  if (!lease) fail('Primary address empty under DHCP (should show live lease CIDR)')
  if (!(await primary.isDisabled())) fail('DHCP primary should be read-only until DHCP is off')

  await dhcp.uncheck()
  if (await primary.isDisabled()) fail('Primary address input disabled after leaving DHCP')
  const before = await primary.inputValue()
  if (before !== lease) fail(`Unchecking DHCP dropped lease ${lease} -> ${before}`)
  await primary.fill('192.168.50.10/24')
  const after = await primary.inputValue()
  if (after !== '192.168.50.10/24') fail(`Could not edit primary IP, value=${after}`)

  const gateway = drawer.locator('.iface-fields-grid input[placeholder="192.168.1.1"]')
  await gateway.fill('192.168.50.1')

  const addBtn = drawer.locator('button:has-text("Add address")')
  if (await addBtn.isDisabled()) fail('Add address disabled')
  await addBtn.click()
  const additional = drawer.locator('.address-row input[placeholder="192.168.1.20/24"]')
  await additional.last().fill('10.20.30.40/24')
  const extraAfterAdd = await additional.last().inputValue()
  if (extraAfterAdd !== '10.20.30.40/24') fail('Could not type additional IP')

  const staticShot = `${dir}/02-static-primary-and-add.png`
  await page.screenshot({ path: staticShot, fullPage: true })

  const applyBtn = drawer.getByRole('button', { name: 'Apply addresses' })
  const applyEnabled = await applyBtn.isEnabled()
  if (!applyEnabled) fail('Apply addresses disabled after editing IPs')

  const checkBody = {
    action: 'check',
    interface: 'en0',
    addresses: [
      { kind: 'static', cidr: after },
      { kind: 'alias', cidr: extraAfterAdd },
    ],
    gateway: '192.168.50.1',
  }
  const checkRes = await fetch(`${base}/api/system/bridges`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(checkBody),
  })
  const checkText = await checkRes.text()
  if (!checkRes.ok) fail(`POST action=check failed: HTTP ${checkRes.status} ${checkText}`)
  const checkResponse = JSON.parse(checkText)
  const checkBlob = JSON.stringify(checkResponse).toLowerCase()
  if (checkBlob.includes('socket_vmnet')) {
    fail(`action=check still plans socket_vmnet: ${checkText.slice(0, 800)}`)
  }
  if (!checkResponse.changes?.length && !checkResponse.message) {
    fail('action=check missing planned diffs')
  }

  const result = {
    ok: true,
    tableRows,
    extraValuesAsLoaded: extraValues,
    labels,
    dhcpLease: lease,
    primaryBefore: before,
    primaryAfter: after,
    additionalAfterAdd: extraAfterAdd,
    applyEnabled,
    aliasDropdown: false,
    check: checkResponse,
    screenshots: { asLoaded, staticShot },
  }
  writeFileSync(`${dir}/result.json`, JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result, null, 2))
} finally {
  await browser.close()
}
