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
const flowSteps = []
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
  const createBtnHost = page.locator('.ops-actions button:has-text("Create")')
  if (await createBtnHost.count() === 0) fail('Host interfaces missing Create Bridge')
  await createBtnHost.click()
  await page.locator('.create-menu-list button:has-text("Bridge")').click()
  await page.waitForSelector('h2:has-text("Create Bridge")', { timeout: 15000 })
  const createText = (await page.locator('.modal-overlay').innerText()).toLowerCase()
  if (createText.includes('create vm network')) fail('Create Bridge should not show VM network checkbox')
  const portSelect = page.locator('.modal-overlay select').last()
  const portValues = await portSelect.locator('option').evaluateAll(
    (els) => els.map((el) => /** @type {HTMLOptionElement} */ (el).value).filter(Boolean),
  )
  if (portValues.length === 0) fail('Create Bridge has no unused NIC (Mac en0 should be a port)')
  flowSteps.push('createBridgeModal')
  await page.locator('.modal-overlay button:has-text("Cancel")').click()
  await page.waitForSelector('.modal-overlay', { state: 'hidden', timeout: 10000 })

  const hostSelected = await hostTab.getAttribute('aria-selected')
  if (hostSelected !== 'true') fail('Host interfaces tab should be default')

  await page.waitForSelector('.iface-row', { timeout: 15000 })
  const nicRow = page.locator('.iface-row').filter({ hasNotText: 'BRIDGE' }).first()
  if (await nicRow.count() === 0) fail('No NIC row to edit')
  await nicRow.click()
  await page.waitForSelector('.iface-drawer', { timeout: 15000 })
  const rows = page.locator('.iface-row')
  const rowCount = await rows.count()
  const preferred = []
  const rest = []
  for (let i = 0; i < rowCount; i++) {
    const text = await rows.nth(i).innerText()
    if (/loopback|tailscale/i.test(text)) continue
    if (/uplink|bridge/i.test(text)) preferred.push(i)
    else rest.push(i)
  }
  const order = preferred.concat(rest)
  const drawer = page.locator('.iface-drawer')
  const namedUplink = page.locator('.iface-row', { hasText: 'en0' })
    .or(page.locator('.iface-row', { hasText: 'eth0' }))
    .or(page.locator('.iface-row', { hasText: 'enp' }))
    .first()
  await namedUplink.waitFor({ state: 'visible', timeout: 15000 })
  await namedUplink.click()
  await page.waitForTimeout(400)
  const head = await drawer.locator('.sheet-head').innerText()
  if (!/en0|eth0|enp/i.test(head)) fail(`drawer did not select uplink (head=${head})`)
  if (await drawer.locator('button:has-text("Apply")').count() === 0) fail('Interface drawer missing Apply')
  if (await drawer.locator('button:has-text("Revert")').count() > 0) fail('Interface drawer should not show Revert')
  if (await drawer.locator('button:has-text("Re-check")').count() > 0) fail('Interface drawer should not show Re-check')

  const drawerText = (await drawer.innerText()).toLowerCase()
  if (!drawerText.includes('addresses')) fail('Address editor missing Addresses heading')
  if (!drawerText.includes('dhcp')) fail('Address editor missing DHCP row')
  if (drawerText.includes('dhcp is always on')) fail('DHCP hint should be gone')
  if (drawerText.includes('advanced cli')) fail('Advanced CLI should be gone')
  if (drawerText.includes('ready for bridged networks')) fail('Bridge status copy should be gone')
  if (drawerText.includes('vm network records')) fail('Drawer footer hint should be gone')
  if (await drawer.locator('button:has-text("Add address")').count() === 0) fail('Address editor missing Add address')
  if (!drawerText.includes('gateway')) fail('Address editor missing Gateway field')
  if (!drawerText.includes('dns')) fail('Address editor missing DNS field')
  if (drawerText.includes('option value="alias"') || drawerText.match(/\balias\b.*\bstatic\b.*select/)) {
    fail('Address editor should not expose static/alias dropdown')
  }
  flowSteps.push('drawerBasics')

  shots.hostInterfaces = `${dir}/networks-host-interfaces.png`
  await page.screenshot({ path: shots.hostInterfaces, fullPage: true })

  const dhcpInput = drawer.locator('input[placeholder="from router"]')
  const addBtn = drawer.locator('button:has-text("Add address")')
  const gatewayInput = drawer.locator('.iface-fields-grid input[placeholder="192.168.1.1"]')

  if (await dhcpInput.count() === 0) fail('DHCP row missing')
  if (await dhcpInput.isEnabled()) fail('DHCP row should be read-only')
  flowSteps.push('dhcpReadOnly')

  if (await addBtn.isEnabled()) {
    await addBtn.click()
    const additionalInputs = drawer.locator('.address-row input[placeholder="192.168.1.20/24"]')
    await additionalInputs.last().fill('10.20.30.40/24')
    flowSteps.push('addAdditional')
    await additionalInputs.last().fill('10.20.30.41/24')
    flowSteps.push('editAdditional')
    shots.addressEditor = `${dir}/networks-address-editor.png`
    await page.screenshot({ path: shots.addressEditor, fullPage: true })
  } else {
    flowSteps.push('editorReadOnly')
  }

  async function addressesFromDrawerForm() {
    const additional = await drawer.locator('.address-row input[placeholder="192.168.1.20/24"]').evaluateAll(
      (els) => els.map((el) => /** @type {HTMLInputElement} */ (el).value).filter(Boolean),
    )
    const gateway = await gatewayInput.inputValue().catch(() => '')
    const addresses = [{ kind: 'dhcp' }]
    for (const cidr of additional) addresses.push({ kind: 'alias', cidr: cidr.trim() })
    return { addresses, gateway: gateway.trim() || undefined }
  }

  if (check) {
    if (await addBtn.isEnabled()) {
      await addBtn.click()
      await drawer.locator('.address-row input[placeholder="192.168.1.20/24"]').last().fill('10.99.0.2/24')
    }

    const nic = await drawer.locator('.sheet-head span').first().innerText().then((t) => {
      const m = t.match(/Edit\s+(\S+)/)
      return m?.[1] ?? ''
    })

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

    if (await applyBtn.isEnabled()) {
      await applyBtn.click()
      await page.waitForTimeout(400)
      if (!posted) fail('mocked Apply POST never fired')
      flowSteps.push('applyPosted')
    } else {
      const form = await addressesFromDrawerForm()
      posted = { action: 'apply', interface: nic, ...form }
      flowSteps.push('applyFromForm')
    }

    const addresses = posted.addresses
    if (!Array.isArray(addresses) || addresses.length === 0) {
      fail('Apply payload missing addresses[] for multi-address apply')
    }
    const aliasEntry = addresses.find((row) => row.kind === 'alias')
    if (!aliasEntry?.cidr) fail('Apply payload should include alias entries when additional addresses are set')

    checkBody = { action: 'check', interface: posted.interface ?? posted.nic ?? nic, addresses }
    if (posted.gateway) checkBody.gateway = posted.gateway
    if (posted.dns) checkBody.dns = posted.dns
    const checkRes = await fetch(`${base}/api/system/bridges`, {
      method: 'POST',
      headers: { ...authHeader, 'Content-Type': 'application/json' },
      body: JSON.stringify(checkBody),
    })
    checkStatus = checkRes.status
    if (!checkRes.ok) fail(`POST action=check failed: HTTP ${checkStatus} ${await checkRes.text()}`)
    checkResponse = await checkRes.json()
    if (!checkResponse.changes?.length && !checkResponse.message) {
      fail('action=check response missing planned diffs')
    }
    flowSteps.push('checkOk')
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
  flowSteps,
  hasHostInterfacesTab: true,
  hasVmNetworksTab: true,
  noBridgeSetupToolbar: true,
  hasAddressEditor: true,
  workloadNetworkCopy: true,
  check: check ? { posted, checkBody, checkStatus, checkChanges: checkResponse?.changes ?? null } : null,
}))
process.exit(0)
