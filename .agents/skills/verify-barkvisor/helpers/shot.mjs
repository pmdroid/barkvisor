import { chromium } from 'playwright-core'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const args = process.argv.slice(2)
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`)
  if (i >= 0 && args[i + 1] !== undefined) return args[i + 1]
  if (fallback !== undefined) return fallback
  console.error(`shot.mjs: missing --${name}`)
  process.exit(64)
}

const base = arg('base').replace(/\/$/, '')
const user = arg('user', 'admin')
const pass = arg('pass', '')
const route = arg('route', '/dashboard')
const out = arg('out')
const waitMs = Number(arg('wait-ms', '1200'))
const raw = args.includes('--raw')
const token = arg('token', '')
const scrubs = []
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--scrub') scrubs.push(args[i + 1])
}

mkdirSync(dirname(out), { recursive: true })

const browser = await chromium.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 })
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))

  if (token) {
    await page.addInitScript((t) => {
      localStorage.setItem('token', t)
      localStorage.setItem('userRole', 'admin')
    }, token)
  } else if (!raw) {
    await page.goto(`${base}/login`, { waitUntil: 'networkidle' })
    await page.fill('.login-card input[type=text]', user)
    await page.fill('.login-card input[type=password]', pass)
    await page.click('button:has-text("Sign In")')
    await page.waitForSelector('.sidebar-nav', { timeout: 15000 })
  }

  await page.goto(`${base}${route}`, { waitUntil: 'networkidle' })
  await page.waitForTimeout(waitMs)
  for (const spec of scrubs) {
    const m = spec.match(/^\/(.*)\/(.*)$/s)
    if (!m) {
      console.error(`shot.mjs: --scrub expects /from/to — got: ${spec}`)
      process.exit(64)
    }
    await page.evaluate(({ pattern, replacement }) => {
      let n = 0
      const re = new RegExp(pattern, 'g')
      const repl = () => replacement.replace('#{i}', String(n++))
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
      const nodes = []
      let node
      while ((node = walk.nextNode())) nodes.push(node)
      for (node of nodes) {
        if (re.test(node.textContent)) {
          re.lastIndex = 0
          node.textContent = node.textContent.replace(re, repl)
        }
        re.lastIndex = 0
      }
      document.title = document.title.replace(re, repl)
    }, { pattern: m[1], replacement: m[2] })
  }
  await page.screenshot({ path: out, fullPage: true })

  console.log(JSON.stringify({ ok: true, url: page.url(), title: await page.title(), screenshot: out, pageErrors: errors }))
} finally {
  await browser.close()
}
