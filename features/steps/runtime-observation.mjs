import assert from "node:assert/strict"
import fs from "node:fs"
import { Given, When, Then } from "@cucumber/cucumber"

let evidence

Given("the runtime observation evidence file", function () {
  const path = process.env.BARKVISOR_OBSERVATION_EVIDENCE
  assert.ok(path, "BARKVISOR_OBSERVATION_EVIDENCE is set")
  assert.ok(fs.existsSync(path), `missing evidence ${path}`)
  this.evidencePath = path
})

When("the evidence is loaded", function () {
  evidence = JSON.parse(fs.readFileSync(this.evidencePath, "utf8"))
})

Then(
  "twenty polling rounds resolve discovery once and a context change resolves it again",
  function () {
    assert.equal(evidence.discoveryResolutionsFor20Polls, 1)
    assert.equal(evidence.discoveryResolutionsAfterContextChange, 2)
  },
)

Then(
  "one running app and four running apps each use two docker commands in a round",
  function () {
    assert.equal(evidence.subprocessesPerRound.apps1, 2)
    assert.equal(evidence.subprocessesPerRound.apps4, 2)
  },
)

Then(
  "the legacy per-app round used two commands for one app and eight commands for four apps",
  function () {
    assert.equal(evidence.subprocessesPerRound.legacyApps1, 2)
    assert.equal(evidence.subprocessesPerRound.legacyApps4, 8)
  },
)

Then("event delivery stays under 50 milliseconds", function () {
  assert.ok(evidence.eventToProjectionNanoseconds < 50_000_000)
})

Then("idle observation keeps the process under 50 cpu ticks", function () {
  assert.ok(evidence.idleCpuTicks < 50)
})

Then("the evidence records idle rss and the failed-probe flag", function () {
  assert.equal(typeof evidence.idleRssKilobytes, "number")
  assert.ok(evidence.idleRssKilobytes > 0)
  assert.equal(evidence.failedProbeKeepsStale, true)
  assert.equal(evidence.bufferCap, 4)
})
