#!/usr/bin/env bun
import { spawn, spawnSync } from "bun"
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "fs"
import { homedir } from "os"
import { join, resolve } from "path"
import type { Browser, BrowserContext, Page } from "playwright"

type Instance = {
  pid: number
  port: number
  agentPort: number
  url: string
  dataDir: string
  logFile: string
  binary: string
  frontendDir: string
  username: string
  password: string
  setupComplete: boolean
  startedAt: string
}

type Session = {
  page: Page
  context: BrowserContext
  browser: Browser
  instance: Instance
  evidenceDir: string
  capture: (label: string) => Promise<void>
}

const skillDir = import.meta.dir
const repoRoot = (() => {
  let dir = resolve(skillDir)
  for (let i = 0; i < 8; i++) {
    if (existsSync(join(dir, "Package.swift"))) return dir
    dir = resolve(dir, "..")
  }
  throw new Error("Package.swift not found above skill dir")
})()

function argFlag(name: string): string | undefined {
  const i = process.argv.indexOf(name)
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1]
  return undefined
}

function runId(): string {
  return argFlag("--run") || process.env.VERIFY_RUN || "default"
}

function cacheRoot(): string {
  return join(homedir(), ".cache", "barkvisor", "verify-barkvisor")
}

function runDir(): string {
  return join(cacheRoot(), "runs", runId())
}

function evidenceDir(): string {
  return join(cacheRoot(), "evidence", runId())
}

function instancePath(): string {
  return join(runDir(), "instance.json")
}

function storageStatePath(): string {
  return join(runDir(), "storageState.json")
}

function portForRun(id: string): number {
  const override = argFlag("--port") || process.env.BARKVISOR_PORT
  if (override) {
    const n = Number(override)
    if (!Number.isInteger(n) || n < 1 || n > 65535) throw new Error("bad --port")
    return n
  }
  if (id === "default") return 17777
  let h = 0
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0
  return 18000 + (h % 1000)
}

function loadInstance(): Instance | null {
  if (!existsSync(instancePath())) return null
  return JSON.parse(readFileSync(instancePath(), "utf8")) as Instance
}

function saveInstance(inst: Instance): void {
  mkdirSync(runDir(), { recursive: true })
  writeFileSync(instancePath(), JSON.stringify(inst, null, 2) + "\n")
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function listenPid(port: number): number | null {
  const r = spawnSync(["lsof", "-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"], {
    stdout: "pipe",
    stderr: "pipe",
  })
  const text = r.stdout.toString().trim()
  if (!text) return null
  const pid = Number(text.split("\n")[0])
  return Number.isInteger(pid) ? pid : null
}

async function httpJson(
  url: string,
  init?: { method?: string; body?: unknown; token?: string },
): Promise<{ status: number; body: unknown; text: string }> {
  const headers: Record<string, string> = { Accept: "application/json" }
  if (init?.body !== undefined) headers["Content-Type"] = "application/json"
  if (init?.token) headers.Authorization = `Bearer ${init.token}`
  const res = await fetch(url, {
    method: init?.method || "GET",
    headers,
    body: init?.body !== undefined ? JSON.stringify(init.body) : undefined,
  })
  const text = await res.text()
  let body: unknown = text
  try {
    body = JSON.parse(text)
  } catch {
    body = text
  }
  return { status: res.status, body, text }
}

function findBinary(): string {
  const shown = spawnSync(["swift", "build", "--show-bin-path", "--product", "BarkVisorApp"], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
  })
  const dir = shown.stdout.toString().trim()
  const candidate = dir ? join(dir, "BarkVisorApp") : ""
  if (candidate && existsSync(candidate)) return candidate
  const fallbacks = [
    join(repoRoot, ".build", "arm64-apple-macosx", "debug", "BarkVisorApp"),
    join(repoRoot, ".build", "debug", "BarkVisorApp"),
    join(repoRoot, ".build", "release", "BarkVisorApp"),
  ]
  for (const p of fallbacks) if (existsSync(p)) return p
  const built = spawnSync(["swift", "build", "--product", "BarkVisorApp"], {
    cwd: repoRoot,
    stdout: "inherit",
    stderr: "inherit",
  })
  if (built.exitCode !== 0) throw new Error("swift build failed")
  const again = spawnSync(["swift", "build", "--show-bin-path", "--product", "BarkVisorApp"], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
  })
  const path = join(again.stdout.toString().trim(), "BarkVisorApp")
  if (!existsSync(path)) throw new Error("BarkVisorApp missing after build")
  return path
}

function ensureFrontend(): string {
  const dist = join(repoRoot, "frontend", "dist")
  const index = join(dist, "index.html")
  if (existsSync(index)) return dist
  const install = spawnSync(["bun", "install"], {
    cwd: join(repoRoot, "frontend"),
    stdout: "inherit",
    stderr: "inherit",
  })
  if (install.exitCode !== 0) throw new Error("frontend bun install failed")
  const build = spawnSync(["bun", "run", "build"], {
    cwd: join(repoRoot, "frontend"),
    stdout: "inherit",
    stderr: "inherit",
  })
  if (build.exitCode !== 0) throw new Error("frontend build failed")
  if (!existsSync(index)) throw new Error("frontend/dist/index.html missing after build")
  return dist
}

function ensureSkillDeps(): void {
  if (!existsSync(join(skillDir, "node_modules", "playwright"))) {
    const r = spawnSync(["bun", "install"], {
      cwd: skillDir,
      stdout: "inherit",
      stderr: "inherit",
    })
    if (r.exitCode !== 0) throw new Error("skill bun install failed")
  }
}

async function loadPlaywright() {
  ensureSkillDeps()
  const mod = await import("playwright")
  try {
    const b = await mod.chromium.launch({ headless: true })
    await b.close()
  } catch {
    const r = spawnSync(["bunx", "playwright", "install", "chromium"], {
      cwd: skillDir,
      stdout: "inherit",
      stderr: "inherit",
    })
    if (r.exitCode !== 0) throw new Error("playwright install chromium failed")
  }
  return mod
}

async function waitHealth(url: string, timeoutMs: number): Promise<void> {
  const start = Date.now()
  let last = ""
  while (Date.now() - start < timeoutMs) {
    try {
      const r = await httpJson(`${url}/api/health`)
      if (r.status === 200) return
      last = `${r.status} ${r.text.slice(0, 120)}`
    } catch (e) {
      last = String(e)
    }
    await Bun.sleep(300)
  }
  throw new Error(`daemon not ready: ${last}`)
}

function print(obj: unknown): void {
  process.stdout.write(JSON.stringify(obj, null, 2) + "\n")
}

function fail(msg: string, extra?: unknown): never {
  print({ ok: false, error: msg, ...(extra && typeof extra === "object" ? extra : {}) })
  process.exit(1)
}

async function cmdLaunch(): Promise<void> {
  ensureSkillDeps()
  mkdirSync(runDir(), { recursive: true })
  mkdirSync(evidenceDir(), { recursive: true })
  const existing = loadInstance()
  if (existing && pidAlive(existing.pid)) {
    const owner = listenPid(existing.port)
    if (owner === existing.pid) {
      print({
        ok: true,
        joined: false,
        reused: true,
        pid: existing.pid,
        url: existing.url,
        dataDir: existing.dataDir,
        evidenceDir: evidenceDir(),
        setupComplete: existing.setupComplete,
      })
      return
    }
  }
  const port = portForRun(runId())
  const agentPort = port + 1
  const owner = listenPid(port)
  if (owner !== null) {
    fail("port already in use by another process; pick --port / VERIFY_RUN", {
      port,
      ownerPid: owner,
    })
  }
  const dataDir = join(runDir(), "data")
  mkdirSync(dataDir, { recursive: true })
  const frontendDir = ensureFrontend()
  const binary = findBinary()
  const logFile = join(runDir(), "daemon.log")
  writeFileSync(logFile, "")
  const logFd = Bun.file(logFile)
  const proc = spawn([binary], {
    cwd: repoRoot,
    env: {
      ...process.env,
      BARKVISOR_DATA_DIR: dataDir,
      BARKVISOR_PORT: String(port),
      BARKVISOR_AGENT_PORT: String(agentPort),
      BARKVISOR_FRONTEND_DIR: frontendDir,
      BARKVISOR_LOG_DIR: join(dataDir, "logs"),
      BARKVISOR_LOG_LEVEL: "info",
    },
    stdin: "ignore",
    stdout: logFd,
    stderr: logFd,
  })
  if (!proc.pid) fail("failed to spawn BarkVisorApp")
  proc.unref()
  const url = `http://127.0.0.1:${port}`
  try {
    await waitHealth(url, 90_000)
  } catch (e) {
    try {
      process.kill(proc.pid, "SIGTERM")
    } catch {}
    fail(String(e), { logFile })
  }
  const setup = await httpJson(`${url}/api/setup/status`)
  const complete =
    setup.status === 200 &&
    typeof setup.body === "object" &&
    setup.body !== null &&
    (setup.body as { complete?: boolean }).complete === true
  const inst: Instance = {
    pid: proc.pid,
    port,
    agentPort,
    url,
    dataDir,
    logFile,
    binary,
    frontendDir,
    username: "admin",
    password: "verify-admin-10",
    setupComplete: complete,
    startedAt: new Date().toISOString(),
  }
  saveInstance(inst)
  print({
    ok: true,
    joined: false,
    reused: false,
    pid: inst.pid,
    url: inst.url,
    dataDir: inst.dataDir,
    evidenceDir: evidenceDir(),
    setupComplete: inst.setupComplete,
    logFile: inst.logFile,
  })
}

async function doctorChecks(inst: Instance): Promise<Record<string, unknown>> {
  const alive = pidAlive(inst.pid)
  const owner = listenPid(inst.port)
  const portOwnedByUs = owner === inst.pid
  let healthStatus: number | null = null
  let healthOk = false
  let setupStatus: number | null = null
  let setupComplete: boolean | null = null
  let spa = false
  let contract: unknown = null
  try {
    const h = await httpJson(`${inst.url}/api/health`)
    healthStatus = h.status
    healthOk =
      h.status === 200 &&
      typeof h.body === "object" &&
      h.body !== null &&
      (h.body as { status?: string }).status === "ok"
  } catch {}
  try {
    const s = await httpJson(`${inst.url}/api/setup/status`)
    setupStatus = s.status
    if (s.status === 200 && typeof s.body === "object" && s.body !== null) {
      setupComplete = (s.body as { complete?: boolean }).complete === true
    }
  } catch {}
  try {
    const page = await fetch(inst.url)
    const html = await page.text()
    spa = page.ok && (html.includes("BarkVisor") || html.includes("app-icon"))
  } catch {}
  try {
    const c = await httpJson(`${inst.url}/api/contract`)
    if (c.status === 200 && typeof c.body === "object" && c.body !== null) {
      contract = { apiVersion: (c.body as { apiVersion?: unknown }).apiVersion }
    }
  } catch {}
  const dataDirOurs = inst.dataDir.startsWith(runDir()) && existsSync(inst.dataDir)
  const ok =
    alive &&
    portOwnedByUs &&
    healthOk &&
    spa &&
    dataDirOurs &&
    setupStatus === 200
  return {
    ok,
    pid: inst.pid,
    url: inst.url,
    dataDir: inst.dataDir,
    evidenceDir: evidenceDir(),
    checks: {
      alive,
      portOwnedByUs,
      listenPid: owner,
      healthStatus,
      healthOk,
      spa,
      dataDirOurs,
      setupStatus,
      setupComplete,
      frontendIndex: existsSync(join(inst.frontendDir, "index.html")),
      contract,
    },
  }
}

async function cmdDoctor(): Promise<void> {
  const inst = loadInstance()
  if (!inst) fail("no instance.json; run launch first")
  const result = await doctorChecks(inst)
  print(result)
  if (!result.ok) process.exit(1)
}

async function capturePage(page: Page, dir: string, label: string, extra?: Record<string, unknown>): Promise<void> {
  mkdirSync(dir, { recursive: true })
  const png = join(dir, `${label}.png`)
  const ariaPath = join(dir, `${label}.aria.txt`)
  const metaPath = join(dir, `${label}.json`)
  await page.screenshot({ path: png, fullPage: true, animations: "disabled" })
  const aria = await page.locator("html").ariaSnapshot()
  writeFileSync(ariaPath, aria + "\n")
  const token = await page.evaluate(() => localStorage.getItem("token"))
  writeFileSync(
    metaPath,
    JSON.stringify(
      {
        url: page.url(),
        title: await page.title(),
        hasToken: Boolean(token),
        capturedAt: new Date().toISOString(),
        ...extra,
      },
      null,
      2,
    ) + "\n",
  )
}

async function openBrowser(inst: Instance): Promise<{ browser: Browser; context: BrowserContext; page: Page }> {
  const { chromium } = await loadPlaywright()
  const headed = process.argv.includes("--headed")
  const browser = await chromium.launch({ headless: !headed })
  const state = existsSync(storageStatePath()) ? storageStatePath() : undefined
  const context = await browser.newContext({
    baseURL: inst.url,
    viewport: { width: 1280, height: 800 },
    storageState: state,
  })
  const page = await context.newPage()
  return { browser, context, page }
}

async function persistState(context: BrowserContext, inst: Instance, setupComplete: boolean): Promise<void> {
  await context.storageState({ path: storageStatePath() })
  inst.setupComplete = setupComplete
  saveInstance(inst)
}

export async function withBarkVisor(fn: (s: Session) => Promise<void>): Promise<void> {
  const inst = loadInstance()
  if (!inst) fail("no instance.json; run launch first")
  const doc = await doctorChecks(inst)
  if (!doc.ok) fail("doctor failed", doc)
  const { browser, context, page } = await openBrowser(inst)
  const dir = evidenceDir()
  try {
    await fn({
      page,
      context,
      browser,
      instance: inst,
      evidenceDir: dir,
      capture: (label) => capturePage(page, dir, label, { feature: label }),
    })
  } finally {
    await browser.close()
  }
}

async function cmdSetup(): Promise<void> {
  const inst = loadInstance()
  if (!inst) fail("no instance.json; run launch first")
  const doc = await doctorChecks(inst)
  if (!doc.ok) fail("doctor failed", doc)
  const skipCatalog = !process.argv.includes("--sync-catalog")
  const { browser, context, page } = await openBrowser(inst)
  const dir = evidenceDir()
  try {
    await page.goto("/setup", { waitUntil: "networkidle" })
    await page.getByRole("heading", { name: "Welcome to BarkVisor" }).waitFor({ timeout: 15_000 })
    await capturePage(page, dir, "setup-welcome")
    await page.getByRole("button", { name: "Set up this Device" }).click()
    await page.getByRole("heading", { name: "Create Admin Account" }).waitFor()
    await page.getByPlaceholder("admin").fill(inst.username)
    await page.getByPlaceholder("Minimum 10 characters").fill(inst.password)
    await page.getByPlaceholder("Confirm password").fill(inst.password)
    await capturePage(page, dir, "setup-admin")
    await page.getByRole("button", { name: "Continue" }).click()
    const bridge = page.getByRole("heading", { name: "Network Bridge" })
    const catalog = page.getByRole("heading", { name: "Image Catalog" })
    await Promise.race([
      bridge.waitFor({ timeout: 10_000 }).then(() => "bridge"),
      catalog.waitFor({ timeout: 10_000 }).then(() => "catalog"),
    ])
    if (await bridge.isVisible().catch(() => false)) {
      await capturePage(page, dir, "setup-bridge")
      await page.getByRole("button", { name: "Skip (use NAT)" }).click()
      await catalog.waitFor({ timeout: 10_000 })
    }
    await capturePage(page, dir, "setup-catalog")
    if (skipCatalog) {
      await page.getByRole("button", { name: "Skip" }).click()
    } else {
      await page.getByRole("button", { name: "Sync Catalog" }).click()
      await page.getByRole("button", { name: "Continue" }).waitFor({ timeout: 120_000 })
      await page.getByRole("button", { name: "Continue" }).click()
    }
    await page.getByRole("heading", { name: "All Set!" }).waitFor({ timeout: 15_000 })
    await capturePage(page, dir, "setup-ready")
    await page.getByRole("button", { name: "Launch Dashboard" }).click()
    await page.getByRole("heading", { name: "Dashboard" }).waitFor({ timeout: 20_000 })
    await persistState(context, inst, true)
    const status = await httpJson(`${inst.url}/api/setup/status`)
    const complete =
      status.status === 200 &&
      typeof status.body === "object" &&
      status.body !== null &&
      (status.body as { complete?: boolean }).complete === true
    const token = await page.evaluate(() => localStorage.getItem("token"))
    await capturePage(page, dir, "setup-dashboard", {
      setupComplete: complete,
      hasToken: Boolean(token),
    })
    print({
      ok: true,
      setupComplete: complete,
      hasToken: Boolean(token),
      url: page.url(),
      evidenceDir: dir,
      skippedCatalog: skipCatalog,
    })
    if (!complete || !token) process.exit(1)
  } finally {
    await browser.close()
  }
}

async function cmdLogin(): Promise<void> {
  const inst = loadInstance()
  if (!inst) fail("no instance.json; run launch first")
  const doc = await doctorChecks(inst)
  if (!doc.ok) fail("doctor failed", doc)
  const { browser, context, page } = await openBrowser(inst)
  const dir = evidenceDir()
  try {
    await context.clearCookies()
    await page.goto("/login", { waitUntil: "networkidle" })
    await page.evaluate(() => localStorage.removeItem("token"))
    await page.reload({ waitUntil: "networkidle" })
    await page.getByRole("heading", { name: "BarkVisor" }).waitFor({ timeout: 10_000 })
    await capturePage(page, dir, "login-form")
    await page.locator('input[type="text"]').fill(inst.username)
    await page.locator('input[type="password"]').fill(inst.password)
    await page.getByRole("button", { name: "Sign In" }).click()
    await page.getByRole("heading", { name: "Virtual Machines" }).waitFor({ timeout: 15_000 })
    const token = await page.evaluate(() => localStorage.getItem("token"))
    await persistState(context, inst, true)
    await capturePage(page, dir, "login-vms")
    print({
      ok: true,
      url: page.url(),
      hasToken: Boolean(token),
      evidenceDir: dir,
    })
    if (!token) process.exit(1)
  } finally {
    await browser.close()
  }
}

async function cmdOpen(): Promise<void> {
  const path = process.argv.find((a, i) => i >= 2 && a.startsWith("/"))
  if (!path) fail("open requires a path starting with /")
  const label = argFlag("--label") || path.replace(/[^\w]+/g, "-").replace(/^-|-$/g, "") || "page"
  const inst = loadInstance()
  if (!inst) fail("no instance.json; run launch first")
  const doc = await doctorChecks(inst)
  if (!doc.ok) fail("doctor failed", doc)
  if (!inst.setupComplete && !existsSync(storageStatePath())) {
    fail("setup is not complete; run setup first")
  }
  const { browser, context, page } = await openBrowser(inst)
  const dir = evidenceDir()
  try {
    if (!existsSync(storageStatePath())) {
      const login = await httpJson(`${inst.url}/api/auth/login`, {
        method: "POST",
        body: { username: inst.username, password: inst.password },
      })
      if (login.status !== 200 || typeof login.body !== "object" || login.body === null) {
        fail("API login failed", { status: login.status, body: login.body })
      }
      const token = (login.body as { token?: string }).token
      if (!token) fail("login response missing token")
      await page.addInitScript((t) => localStorage.setItem("token", t), token)
    }
    await page.goto(path, { waitUntil: "networkidle" })
    await capturePage(page, dir, label)
    print({
      ok: true,
      url: page.url(),
      title: await page.title(),
      evidenceDir: dir,
      png: join(dir, `${label}.png`),
      aria: join(dir, `${label}.aria.txt`),
    })
  } finally {
    await browser.close()
  }
}

async function cmdCleanup(): Promise<void> {
  const inst = loadInstance()
  if (!inst) {
    print({ ok: true, action: "nothing", evidenceDir: evidenceDir() })
    return
  }
  if (pidAlive(inst.pid)) {
    try {
      process.kill(inst.pid, "SIGTERM")
    } catch {}
    const start = Date.now()
    while (Date.now() - start < 8000 && pidAlive(inst.pid)) await Bun.sleep(200)
    if (pidAlive(inst.pid)) {
      try {
        process.kill(inst.pid, "SIGKILL")
      } catch {}
    }
  }
  const owner = listenPid(inst.port)
  if (owner !== null && owner !== inst.pid) {
    print({
      ok: false,
      error: "port still held by a different pid; not killed",
      ownerPid: owner,
      evidenceDir: evidenceDir(),
    })
    process.exit(1)
  }
  rmSync(runDir(), { recursive: true, force: true })
  print({
    ok: true,
    action: "stopped",
    pid: inst.pid,
    evidenceDir: evidenceDir(),
    evidenceExists: existsSync(evidenceDir()),
  })
}

const cmd = process.argv[2]
if (import.meta.main) {
  try {
    if (cmd === "launch") await cmdLaunch()
    else if (cmd === "doctor") await cmdDoctor()
    else if (cmd === "setup") await cmdSetup()
    else if (cmd === "login") await cmdLogin()
    else if (cmd === "open") await cmdOpen()
    else if (cmd === "cleanup") await cmdCleanup()
    else {
      print({
        ok: false,
        error: "usage: bun drive.ts launch|doctor|setup|login|open|cleanup",
      })
      process.exit(2)
    }
  } catch (e) {
    fail(e instanceof Error ? e.message : String(e))
  }
}
