import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`create-vm-flow.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass', '')
const dir = arg('dir')
const tokenArg = arg('token', '')
const vmName = arg('vm-name', `verify-debian-${Date.now()}`)

mkdirSync(dir, { recursive: true })

let authHeader
if (tokenArg) {
  authHeader = { Authorization: `Bearer ${tokenArg}` }
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

async function api(path) {
  const res = await fetch(`${base}${path}`, { headers: authHeader })
  if (!res.ok) throw new Error(`${path} HTTP ${res.status}`)
  return res.json()
}

function templateUsable(row) {
  const inputs = Array.isArray(row.inputs) ? row.inputs : []
  return !inputs.some((input) => input.id === 'password' && input.required && !input.default)
}

const templates = await api('/api/templates')
const rows = Array.isArray(templates) ? templates : []
const preferred = ['debian-cloud', 'ubuntu-cloud', 'debian-13-cloud', 'home-assistant', 'openwrt']
const template = preferred
  .map((slug) => rows.find((row) => row.slug === slug && templateUsable(row)))
  .find(Boolean)
  ?? rows.find((row) => templateUsable(row) && row.slug !== 'pi-hole')

if (!template) {
  console.error('no cloud OS template in catalog')
  process.exit(1)
}

const browser = await chromium.launch()
const shots = []
const flows = []
let magError = ''

try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const tokenForPage = authHeader.Authorization.replace('Bearer ', '')
  await page.addInitScript((t) => {
    localStorage.setItem('token', t)
    localStorage.setItem('userRole', 'admin')
  }, tokenForPage)
  await page.goto(`${base}/vms`, { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('.sidebar-nav', { timeout: 15000 })

  const lightBtn = page.locator('button:has-text("Light Mode")')
  if (await lightBtn.count()) {
    await lightBtn.click()
    await page.waitForTimeout(200)
  }
  await page.click('button:has-text("Create VM")')
  await page.waitForSelector('.mag-frame')
  const lightBg = await page.locator('.mag-frame').evaluate((el) => getComputedStyle(el).backgroundColor)
  shots.push(`${dir}/01-gallery-light.png`)
  await page.screenshot({ path: shots.at(-1), fullPage: true })
  const lightNums = (lightBg.match(/\d+/g) || []).map(Number)
  const lightOk = lightNums.length >= 3 && lightNums[0] + lightNums[1] + lightNums[2] > 500
  flows.push({ flow: 'light-gallery', ok: lightOk, backgroundColor: lightBg })
  await page.click('.mag-btn.ghost:has-text("Cancel")')

  const darkBtn = page.locator('button:has-text("Dark Mode")')
  if (await darkBtn.count()) await darkBtn.click()

  await page.click('button:has-text("Create VM")')
  await page.waitForSelector('.mag-shelf')
  shots.push(`${dir}/02-gallery.png`)
  await page.screenshot({ path: shots.at(-1), fullPage: true })
  flows.push({
    flow: 'gallery',
    ok: await page.locator('.mag-card b', { hasText: 'Windows' }).count() > 0
      && await page.locator('.mag-custom').count() > 0,
  })

  await page.locator('.mag-card b', { hasText: 'Windows' }).click()
  await page.waitForSelector('h2:has-text("Set up Windows")')
  const winHint = await page.locator('.mag-hostname').count()
  shots.push(`${dir}/03-windows.png`)
  await page.screenshot({ path: shots.at(-1), fullPage: true })
  flows.push({ flow: 'windows', ok: winHint === 0 })
  await page.click('.mag-btn.ghost:has-text("Back")')

  await page.locator('.mag-custom').click()
  await page.waitForSelector('h2:has-text("Name it and pick a size")')
  const customNext = await page.locator('.mag-btn.primary').isDisabled()
  shots.push(`${dir}/04-custom.png`)
  await page.screenshot({ path: shots.at(-1), fullPage: true })
  flows.push({ flow: 'custom-needs-image', ok: customNext })
  await page.click('.mag-btn.ghost:has-text("Back")')

  await page.locator('.mag-card', { hasText: template.name }).click()
  await page.waitForSelector('h2:has-text("Name it and pick a size")')
  const passwordLabels = await page.locator('.mag-flabel', { hasText: 'Password' }).count()
  await page.fill('.mag-frame input', vmName)
  const sshRow = await page.locator('.mag-fwrow', { hasText: 'SSH key' }).count()
  shots.push(`${dir}/05-configure-template.png`)
  await page.screenshot({ path: shots.at(-1), fullPage: true })
  flows.push({ flow: 'template-configure', ok: passwordLabels === 0, sshRow })

  const nextBtn = page.locator('.mag-btn.primary:has-text("Next")')
  if (await nextBtn.isDisabled()) {
    magError = ((await page.locator('.mag-error').textContent().catch(() => '')) || 'Next disabled').trim()
    shots.push(`${dir}/05b-next-disabled.png`)
    await page.screenshot({ path: shots.at(-1), fullPage: true })
  } else {
    await nextBtn.click()
    await page.waitForSelector('h2:has-text("Disk")')
  }
  if (await page.locator('h2:has-text("Disk")').count()) {
    await page.locator('.mag-dcard', { hasText: 'Existing disk' }).click()
    shots.push(`${dir}/06-disk-existing.png`)
    await page.screenshot({ path: shots.at(-1), fullPage: true })
    const existingCreateDisabled = await page.locator('.mag-btn.primary:has-text("Create")').isDisabled()
    await page.locator('.mag-dcard', { hasText: 'New disk' }).click()
    shots.push(`${dir}/07-disk-new.png`)
    await page.screenshot({ path: shots.at(-1), fullPage: true })
    const rawCard = page.locator('.mag-dcard', { hasText: 'Raw host device' })
    const rawOff = await rawCard.evaluate((el) => el.classList.contains('off'))
    flows.push({
      flow: 'disk-existing',
      ok: await page.locator('.mag-dcard', { hasText: 'Existing disk' }).count() > 0,
      createDisabled: existingCreateDisabled,
    })
    flows.push({ flow: 'disk-new', ok: await page.locator('.mag-dcard.on', { hasText: 'New disk' }).count() > 0 })
    flows.push({ flow: 'disk-raw-macos', ok: rawOff })
    await page.locator('.mag-btn.primary:has-text("Create")').click()
    await page.waitForSelector('.mag-frame', { state: 'hidden', timeout: 15000 }).catch(() => {})
    magError = ((await page.locator('.mag-error').textContent().catch(() => '')) || magError || '').trim()
    const magOpen = await page.locator('.mag-frame').count()
    const listRow = page.locator('tr', { hasText: vmName })
    const listVisible = magOpen === 0
      && await listRow.waitFor({ timeout: 8000 }).then(() => true).catch(() => false)
    const listText = listVisible ? ((await listRow.innerText().catch(() => '')) || '') : ''
    flows.push({ flow: 'magazine-closes', ok: magOpen === 0 && !magError })
    flows.push({
      flow: 'list-progress',
      ok: listVisible && /Downloading|Decompressing|Provisioning|Starting|Running|Stopped/i.test(listText),
      statusText: listText,
    })
    shots.push(`${dir}/08-after-create.png`)
    await page.screenshot({ path: shots.at(-1), fullPage: true })
  }
} finally {
  await browser.close()
}

const vms = await api('/api/vms')
const vmRow = Array.isArray(vms) ? vms.find((row) => row.name === vmName) : null
const images = await api('/api/images')
const downloading = Array.isArray(images)
  ? images.filter((row) => row.status === 'downloading' || row.status === 'pending')
  : []

if (/password/i.test(magError)) {
  console.log(JSON.stringify({
    ok: false,
    error: magError,
    flows,
    screenshots: shots,
  }, null, 2))
  process.exit(1)
}

const passwordLeak = /password/i.test(magError)
const deployStarted = vmRow != null || downloading.length > 0
const ok = !passwordLeak && flows.every((row) => row.ok) && deployStarted
writeFileSync(`${dir}/result.json`, JSON.stringify({
  ok,
  vmName,
  template: { slug: template.slug, name: template.name },
  magError: magError || null,
  vm: vmRow ? { id: vmRow.id, name: vmRow.name, state: vmRow.state } : null,
  downloading: downloading.map((row) => ({ id: row.id, name: row.name, status: row.status })),
  flows,
  screenshots: shots,
}, null, 2) + '\n')

console.log(JSON.stringify({
  ok,
  vmName,
  templateSlug: template.slug,
  magError: magError || null,
  vmCreated: Boolean(vmRow),
  downloading: downloading.length,
  flows,
  screenshots: shots,
}))
process.exit(ok ? 0 : 1)
