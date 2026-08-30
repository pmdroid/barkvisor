export const meta = {
  name: 'create-progress-stack',
  description: 'GH #410-413 create progress: server projector, types, web, iOS. Sequential. Composer review. Do not merge.',
  phases: [{ title: 'Implement' }, { title: 'Close' }],
}

const projectId = (args && args.projectId) || 'e180fa4a-6d6e-43cd-ae7e-624cd6ce6c89'
const projectName = (args && args.projectName) || 'BarkVisor product ideas'
const implAgent = (args && args.agent) || 'grok-build'
const reviewAgent = (args && args.reviewAgent) || 'cursor-agent'
const reviewModel = (args && args.reviewModel) || 'composer-2.5'
const maxReviewRounds = Number((args && args.maxReviewRounds) || 2)
const onlyNumber = args && args.onlyNumber ? Number(args.onlyNumber) : null

const TICKETS = [
  {
    number: 410,
    id: 'GH-410',
    slug: 'creation-progress-server',
    title: 'Create progress: server WorkloadCreationProgress on VM responses',
    branch: 'feature/create-progress-server',
    notes: [
      'GitHub https://github.com/pmdroid/barkvisor/issues/410',
      'Add WorkloadCreationProgress phase enum: initiating|downloading|decompressing|provisioning|created|failed.',
      'Project at VMResponse build time from PendingVMImageOverlay, ImageDownloader lastProgress, BackgroundTaskManager task for vm provision, VM.state.',
      'Do NOT persist progress ticks to DB.',
      'Attach to GET /vms, GET /vms/:id, TemplateController deploy 202, VMController create 202.',
      'Keep pendingImageId + downloadPercent on VMResponse for compat.',
      'Tests: BarkVisorTests phase projection cases.',
      'Read: PendingVMImageOverlay.swift, TemplateDeployService.swift, VMLifecycleService.swift, VMController.swift, frontend/src/stores/createProgress.ts (client expectations).',
    ].join('\n'),
  },
  {
    number: 411,
    id: 'GH-411',
    slug: 'creation-progress-types',
    title: 'Create progress: OpenAPI + shared client types',
    branch: 'feature/create-progress-types',
    notes: [
      'GitHub https://github.com/pmdroid/barkvisor/issues/411',
      'Stack on origin/feature/create-progress-server if that branch exists on origin, else origin/main.',
      'openapi.yaml + APIContract.swift + frontend/src/api/types.ts + Apps/BarkVisorConsole Swift models.',
      'Add phase label helper (user copy: Downloading image, Preparing workload, Starting, Ready).',
      'Update contract.test.ts and APIDecodingTests.',
    ].join('\n'),
  },
  {
    number: 412,
    id: 'GH-412',
    slug: 'creation-progress-web',
    title: 'Create progress: web createProgress + list row UX',
    branch: 'feature/create-progress-web',
    notes: [
      'GitHub https://github.com/pmdroid/barkvisor/issues/412',
      'Stack on origin/feature/create-progress-types if present else origin/main.',
      'Refactor frontend/src/stores/createProgress.ts to prefer vm.creationProgress; keep legacy fallback.',
      'Polish CreateVMDrawer / workload list: determinate bar when progress known, indeterminate for preparing/starting, Ready pulse, failed row with dismiss.',
      'Update createProgress.test.ts.',
    ].join('\n'),
  },
  {
    number: 413,
    id: 'GH-413',
    slug: 'creation-progress-ios',
    title: 'Create progress: iOS CreateProgressObserver + wizard handoff',
    branch: 'feature/create-progress-ios',
    notes: [
      'GitHub https://github.com/pmdroid/barkvisor/issues/413',
      'Stack on origin/feature/create-progress-web if present else origin/main.',
      'CreateProgressObserver: poll scoped GET /vms/:id, UserDefaults persistence for pending creates.',
      'CreateVMWizardView: dismiss to Workloads tab with pending row; haptic on ready.',
      'Wire createFromWizard for template deploy + POST /vms 202 paths.',
      'xcodebuild test -destination platform=macOS.',
      'Regenerate xcodeproj if new Swift files.',
    ].join('\n'),
  },
]

const TEST_GATE = [
  'TEST GATE: git config core.hooksPath .githooks; user.name "Pascal Matthiesen"; user.email "me@pascal.sh".',
  'mise run prepush before every push/PR. NEVER --no-verify.',
  'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer for Console tests.',
].join('\n')

const COMMON = [
  'Repo: BarkVisor. THIS worktree only.',
  'Linear project: ' + projectName + ' (' + projectId + '). GitHub issues #410-413.',
  'Glossary: Home / Device / Workload / Library — not VM/host in product copy.',
  'Do not close GitHub issues. Do not merge. Refs #NNN not Fixes.',
  TEST_GATE,
].join('\n')

const REVIEW = [
  'Reviewer: Cursor Composer 2.5 ONLY.',
  'Run: ~/.agents/skills/autoreview/scripts/autoreview --mode branch --base origin/main --engine cursor --model composer-2.5',
  'Never omit --engine (defaults to Codex).',
].join('\n')

const ImplSchema = {
  type: 'object',
  required: ['status', 'summary', 'issueId', 'testsOk'],
  properties: {
    status: { type: 'string' },
    summary: { type: 'string' },
    issueId: { type: 'string' },
    number: { type: 'number' },
    branch: { type: 'string' },
    testsOk: { type: 'boolean' },
    blockedReason: { type: 'string' },
  },
}

const ReviewSchema = {
  type: 'object',
  required: ['status', 'summary', 'issueId', 'clean'],
  properties: {
    status: { type: 'string' },
    summary: { type: 'string' },
    issueId: { type: 'string' },
    clean: { type: 'boolean' },
    findings: { type: 'array' },
  },
}

const PrSchema = {
  type: 'object',
  required: ['status', 'summary', 'issueId'],
  properties: {
    status: { type: 'string' },
    summary: { type: 'string' },
    issueId: { type: 'string' },
    number: { type: 'number' },
    branch: { type: 'string' },
    prUrl: { type: 'string' },
    prNumber: { type: 'number' },
    autoreviewClean: { type: 'boolean' },
    testsOk: { type: 'boolean' },
  },
}

async function workTicket(item, stackHint) {
  const label = 'gh-' + item.number + '-' + item.slug
  let branch = item.branch
  const impl = await agent(
    [
      'Implement GitHub #' + item.number + ': ' + item.title,
      COMMON,
      stackHint || '',
      item.notes,
      'Branch ' + item.branch + '. mise run prepush before push. Open PR only after review loop.',
      'Return JSON: {"status":"implemented|blocked","summary":"...","issueId":"' + item.id + '","number":' + item.number + ',"branch":"...","testsOk":true}',
    ].join('\n'),
    {
      label: label + '-impl',
      phase: 'Implement',
      role: 'implementer',
      agent: implAgent,
      timeout_sec: 5400,
      schema: ImplSchema,
    },
  )
  if (!impl || impl.status === 'blocked' || impl.testsOk !== true) {
    return {
      status: (impl && impl.status) || 'blocked',
      summary: (impl && impl.summary) || 'implement failed',
      issueId: item.id,
      number: item.number,
      branch,
      testsOk: false,
      autoreviewClean: false,
    }
  }
  if (impl.branch) branch = impl.branch

  let clean = false
  for (let round = 1; round <= maxReviewRounds && budget.ok(); round++) {
    const rev = await agent(
      [
        'Cross-review GitHub #' + item.number + ' branch ' + branch + ' vs origin/main.',
        REVIEW,
        'Return JSON: {"status":"clean|findings","summary":"...","issueId":"' + item.id + '","clean":true|false,"findings":[]}',
      ].join('\n'),
      {
        label: label + '-review' + round,
        phase: 'Implement',
        role: 'reviewer',
        agent: reviewAgent,
        model: reviewModel,
        timeout_sec: 2400,
        schema: ReviewSchema,
      },
    )
    if (rev && (rev.clean || rev.status === 'clean')) {
      clean = true
      break
    }
    const findings = JSON.stringify((rev && rev.findings) || [])
    const fix = await agent(
      ['Fix review findings only for #' + item.number + ' on ' + branch + '.', COMMON, findings].join('\n'),
      {
        label: label + '-fix' + round,
        phase: 'Implement',
        role: 'implementer',
        agent: implAgent,
        timeout_sec: 2400,
        schema: ImplSchema,
      },
    )
    if (!fix || fix.testsOk !== true) break
    if (fix.branch) branch = fix.branch
  }

  phase('Close')
  const pr = await agent(
    [
      'Open READY PR for GitHub #' + item.number + ' on branch ' + branch + '.',
      'Base main unless stacking — say so in PR body.',
      'Review clean=' + String(clean) + '. Do not merge. Do not close issue.',
      'Return JSON with prUrl, prNumber, testsOk, autoreviewClean.',
    ].join('\n'),
    {
      label: label + '-pr',
      phase: 'Close',
      role: 'implementer',
      agent: implAgent,
      timeout_sec: 1800,
      schema: PrSchema,
    },
  )
  return Object.assign(
    { issueId: item.id, number: item.number, branch, autoreviewClean: clean, testsOk: impl.testsOk },
    pr || { status: 'partial' },
  )
}

phase('Implement')
const queue = onlyNumber ? TICKETS.filter((t) => t.number === onlyNumber) : TICKETS
if (!queue.length) throw new Error('No tickets matched onlyNumber=' + onlyNumber)

const results = []
for (let i = 0; i < queue.length; i++) {
  if (!budget.ok()) break
  const t = queue[i]
  const stackHint =
    i > 0
      ? 'Stack on origin/' + queue[i - 1].branch + ' if that branch exists on origin, else previous merged main.'
      : 'Branch from origin/main.'
  results.push(await workTicket(t, stackHint))
  const last = results[results.length - 1]
  if (last.status === 'blocked' || last.testsOk === false) {
    log('blocked at #' + t.number + ' — stopping stack')
    break
  }
}

const blocked = results.filter((r) => r.status === 'blocked' || r.testsOk === false).length
if (blocked) {
  await host.ask({
    question: blocked + ' ticket(s) blocked in create-progress stack. What next?',
    options: [
      { id: 'retry', label: 'Retry blocked ticket only (eve_run onlyNumber)' },
      { id: 'continue', label: 'Continue with next ticket anyway' },
      { id: 'stop', label: 'Stop here' },
    ],
  })
}

return { results, blocked, next: blocked ? null : 'merge stack PRs in order 410→413' }
