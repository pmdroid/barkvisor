import { chromium } from 'playwright-core'
import { mkdirSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`setup-flow.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass', 'setup-verify-pass')
const dir = arg('dir')
const joinPayload = arg('join-payload', '')

mkdirSync(dir, { recursive: true })

const browser = await chromium.launch()
const shots = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const shot = async (name) => {
    const p = `${dir}/${name}.png`
    await page.screenshot({ path: p, fullPage: true })
    shots.push(p)
  }

  await page.goto(`${base}/setup`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.setup-card', { timeout: 15000 })
  await shot('01-welcome')

  if (joinPayload) {
    await page.click('button:has-text("Join an existing")')
    await page.fill('textarea.pairing-input', joinPayload)
    await shot('02-join-form')
    await page.click('button:has-text("Join")')
    await page.waitForSelector('h2:has-text("Joined your")', { timeout: 20000 })
    await shot('03-join-ready')
  } else {
    await page.click('button:has-text("Set up this")')
    await page.waitForSelector('h2:has-text("Create Admin Account")', { timeout: 10000 })
    await page.fill('input[placeholder="admin"]', user)
    await page.fill('input[placeholder="Minimum 10 characters"]', pass)
    await page.fill('input[placeholder="Confirm password"]', pass)
    await shot('02-admin')
    await page.click('button:has-text("Continue")')

    const bridge = await page
      .waitForSelector('h2:has-text("Network Bridge")', { timeout: 6000 })
      .catch(() => null)
    if (bridge) {
      await shot('03-bridge')
      await page.click('button:has-text("Skip (use NAT)")')
    }

    await page.waitForSelector('h2:has-text("Image Catalog")', { timeout: 15000 })
    await shot('04-catalog')
    await page.click('button:has-text("Skip")')

    await page.waitForSelector('h2:has-text("All Set!")', { timeout: 15000 })
    await shot('05-ready')
    await page.click('button:has-text("Launch Dashboard")')
  }

  await page.waitForSelector('.sidebar-nav', { timeout: 20000 })
  await shot('06-landed')

  const status = await (await fetch(`${base}/api/setup/status`)).json()
  writeFileSync(`${dir}/result.json`, JSON.stringify({ ok: status.complete === true, setupStatus: status, shots }, null, 2))
  console.log(JSON.stringify({ ok: status.complete === true, setupStatus: status, shots }))
  process.exit(status.complete ? 0 : 1)
} finally {
  await browser.close()
}
