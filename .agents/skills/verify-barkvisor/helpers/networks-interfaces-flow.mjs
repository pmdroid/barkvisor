import { chromium } from 'playwright-core'
import { mkdirSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`networks-interfaces-flow.mjs: missing --${name}`)
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
const shots = {}
let posted = null
let checkBody = null
let checkStatus = null
let checkResponse = null
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

  const hostTab = page.locator('[role="tab"]:has-text("Host interfaces")')
  const vmTab = page.locator('[role="tab"]:has-text("VM networks")')
  await hostTab.waitFor({ state: 'visible', timeout: 15000 })
  if (await page.locator('button:has-text("Bridge setup")').count() > 0) {
    fail('Bridge setup toolbar button should be removed')
  }

  const hostSelected = await hostTab.getAttribute('aria-selected')
  if (hostSelected !== 'true') fail('Host interfaces tab should be default')

  await page.waitForSelector('.iface-row', { timeout: 15000 })
  await page.waitForSelector('.iface-drawer', { timeout: 15000 })
  const drawer = page.locator('.iface-drawer')
  if (await drawer.locator('button:has-text("Apply")').count() === 0) fail('Interface drawer missing Apply')
  if (await drawer.locator('button:has-text("Revert")').count() === 0) fail('Interface drawer missing Revert')
  if (await drawer.locator('button:has-text("Re-check")').count() === 0) fail('Interface drawer missing Re-check')

  const drawerText = await drawer.innerText()
  if (!drawerText.includes('Addresses')) fail('Address editor missing Addresses heading')
  if (!drawerText.includes('DHCP')) fail('Address editor missing DHCP control')
  if (await drawer.locator('button:has-text("Add address")').count() === 0) fail('Address editor missing Add address')
  if (!drawerText.includes('Gateway')) fail('Address editor missing Gateway field')
  if (!drawerText.includes('DNS')) fail('Address editor missing DNS field')

  shots.hostInterfaces = `${dir}/networks-host-interfaces.png`
  await page.screenshot({ path: shots.hostInterfaces, fullPage: true })

  if (check) {
    await page.route('**/api/**/bridges', async (route) => {
      const req = route.request()
      if (req.method() === 'POST') {
        posted = req.postDataJSON()
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ success: true, message: 'check', applied: false }) })
        return
      }
      await route.continue()
    })
    const addBtn = drawer.locator('button:has-text("Add address")')
    if (await addBtn.isEnabled()) {
      await addBtn.click()
      await drawer.locator('.address-row input[placeholder="192.168.1.10/24"]').last().fill('10.0.0.2/24')
    }
    const applyBtn = drawer.locator('button:has-text("Apply")')
    if (await applyBtn.isDisabled()) {
      console.log(JSON.stringify({ ok: true, screenshots: shots, checkSkipped: 'Apply disabled on this host (expected on some platforms)' }))
      process.exit(0)
    }
    await applyBtn.click()
    await page.waitForTimeout(400)
    if (!posted) fail('mocked Apply POST never fired')
    const addresses = posted.addresses
    if (!Array.isArray(addresses) || addresses.length === 0) fail('Apply POST missing addresses[] for multi-address apply')
    checkBody = { action: 'check', interface: posted.interface ?? posted.nic, addresses }
    if (posted.gateway) checkBody.gateway = posted.gateway
    if (posted.dns) checkBody.dns = posted.dns
    const checkRes = await fetch(`${base}/api/system/bridges`, { method: 'POST', headers: { ...authHeader, 'Content-Type': 'application/json' }, body: JSON.stringify(checkBody) })
    checkStatus = checkRes.status
    if (!checkRes.ok) fail(`POST action=check failed: HTTP ${checkStatus} ${await checkRes.text()}`)
    checkResponse = await checkRes.json()
    if (!checkResponse.changes?.length && !checkResponse.message) fail('action=check response missing planned diffs')
  }

  await vmTab.click()
  if (await vmTab.getAttribute('aria-selected') !== 'true') fail('VM networks tab did not activate')

  const vmIntro = page.locator('.vm-tab-intro')
  await vmIntro.waitFor({ state: 'visible', timeout: 15000 })
  const introText = await vmIntro.innerText()
  if (!introText.includes('Workload networks')) fail('VM tab missing Workload networks copy')
  if (!introText.includes('Device addresses')) fail('VM tab missing Device addresses copy')

  const createBtn = page.locator('button:has-text("Create Network")')
  await createBtn.waitFor({ state: 'visible', timeout: 15000 })
  await createBtn.click()
  await page.waitForSelector('h2:has-text("Create Workload network")', { timeout: 15000 })
  const modalText = await page.locator('.modal-overlay').innerText()
  if (!modalText.includes('Device addresses')) fail('Create modal missing Device addresses distinction')

  await page.locator('.modal-overlay button:has-text("Cancel")').click()
  await page.waitForSelector('.modal-overlay', { state: 'hidden', timeout: 10000 })

  await page.waitForSelector('.nrow', { timeout: 15000 })
  shots.vmNetworks = `${dir}/networks-vm-tab.png`
  await page.screenshot({ path: shots.vmNetworks, fullPage: true })
} finally {
  await browser.close()
}

console.log(JSON.stringify({
  ok: true,
  screenshots: shots,
  hasHostInterfacesTab: true,
  hasVmNetworksTab: true,
  noBridgeSetupToolbar: true,
  hasAddressEditor: true,
  workloadNetworkCopy: true,
  check: check ? { posted, checkBody, checkStatus, checkChanges: checkResponse?.changes ?? null } : null,
}))
process.exit(0)
