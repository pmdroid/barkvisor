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
const scrubs = []
for (let i = 0; i < args.length; i++) if (args[i] === '--scrub') scrubs.push(args[i + 1])

mkdirSync(dir, { recursive: true })

async function applyScrubs(page) {
  for (const spec of scrubs) {
    const m = spec.match(/^\/(.*)\/(.*)$/s)
    if (!m) continue
    await page.evaluate(({ pattern, replacement }) => {
      let n = 0
      const re = new RegExp(pattern, 'g')
      const repl = () => replacement.replace('#{i}', String(n++))
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
      const nodes = []
      let node
      while ((node = walk.nextNode())) nodes.push(node)
      for (node of nodes) {
        if (re.test(node.textContent)) { re.lastIndex = 0; node.textContent = node.textContent.replace(re, repl) }
        re.lastIndex = 0
      }
      document.title = document.title.replace(re, repl)
    }, { pattern: m[1], replacement: m[2] })
  }
}

const browser = await chromium.launch()
const shots = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const shot = async (name) => {
    await applyScrubs(page)
    const p = `${dir}/${name}.png`
    await page.screenshot({ path: p, fullPage: true })
    shots.push(p)
  }

  await page.goto(`${base}/setup`, { waitUntil: 'networkidle' })
  await page.waitForSelector('.shell', { timeout: 15000 })
  await shot('01-welcome')

  if (joinPayload) {
    await page.click('button:has-text("Join an existing")')
    await page.fill('#setup-offer', joinPayload)
    await shot('02-join-form')
    await page.click('button:has-text("Join")')
    await page.waitForSelector('h1:has-text("Joined your")', { timeout: 20000 })
    await shot('03-join-ready')
  } else {
    await page.click('button:has-text("Set up this")')
    await page.waitForSelector('h1:has-text("Create Admin Account")', { timeout: 10000 })
    await page.fill('input[placeholder="admin"]', user)
    await page.fill('input[placeholder="Minimum 10 characters"]', pass)
    await page.fill('input[placeholder="Repeat password"]', pass)
    await shot('02-admin')
    await page.click('button:has-text("Continue")')

    const bridge = await page
      .waitForSelector('h1:has-text("Network Bridge")', { timeout: 6000 })
      .catch(() => null)
    if (bridge) {
      await shot('03-bridge')
      await page.click('button:has-text("Skip (use NAT)")')
    }

    await page.waitForSelector('h1:has-text("Image Catalog")', { timeout: 15000 })
    await shot('04-catalog')
    await page.click('button:has-text("Skip")')

    await page.waitForSelector('h1:has-text("All Set!")', { timeout: 15000 })
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
