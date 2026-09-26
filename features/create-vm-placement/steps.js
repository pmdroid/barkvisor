const { Before, Given, When, Then } = require("@cucumber/cucumber")
const { spawnSync } = require("node:child_process")
const path = require("node:path")

const root = path.resolve(__dirname, "../..")
let result

function output() {
  return `${result?.stdout || ""}\n${result?.stderr || ""}`
}

function requirePass(needle) {
  if (!result || result.status !== 0 || !output().includes(needle)) {
    throw new Error(output().slice(-4000))
  }
}

Before(function () {
  if (result) return
  result = spawnSync(
    "bun",
    [
      "test",
      "src/composables/usePlacement.test.ts",
      "src/composables/useCreateVMWizard.test.ts",
      "src/utils/deviceCompatibility.test.ts",
    ],
    {
      cwd: path.join(root, "frontend"),
      encoding: "utf8",
      timeout: 180000,
    },
  )
})

Given(
  /^the console Device is arm64 and Debian 13 declares arm64 and x86_64 with an x86_64 catalog image$/,
  function () {
    requirePass("dual-arch Debian posts both arches and leaves the x86 Device eligible")
  },
)

When(/^the operator selects Debian 13 in Create VM$/, function () {
  requirePass("dual-arch Debian posts both arches and leaves the x86 Device eligible")
})

Then(
  /^the placement score body lists arm64 and x86_64 and the x86_64 Device has no architecture mismatch$/,
  function () {
    requirePass("dual-arch Debian posts both arches and leaves the x86 Device eligible")
  },
)

Given(
  /^the picker is showing Architecture \(arm64\) is not compatible with this Device \(x86_64\) from an earlier score$/,
  function () {
    requirePass("a new template score hides the previous architecture mismatch while it is in flight")
    requirePass("a new architecture list drops the previous hard reason before the score returns")
  },
)

When(/^a new placement score starts for a different architecture list$/, function () {
  requirePass("a new template score hides the previous architecture mismatch while it is in flight")
})

Then(/^that hard reason is gone before the new score returns$/, function () {
  requirePass("a new architecture list drops the previous hard reason before the score returns")
})

Given(/^the selected Library image arch is arm64$/, function () {
  requirePass("an arm64-only Library image still rejects an x86 Device")
})

When(/^Create VM scores placement$/, function () {
  requirePass("an arm64-only Library image still rejects an x86 Device")
})

Then(
  /^the x86_64 Device is incompatible because Architecture \(arm64\) is not compatible with this Device \(x86_64\)$/,
  function () {
    requirePass("an arm64-only Library image still rejects an x86 Device")
    requirePass("PAS-33 arch fields disable a Device that cannot run the guest")
  },
)
