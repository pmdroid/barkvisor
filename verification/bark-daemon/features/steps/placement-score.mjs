import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Before, Given, Then, When } from "@cucumber/cucumber"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..")
let result

Before(function () {
  if (result) return
  const swift = process.env.SWIFT || "swift"
  result = spawnSync(swift, ["test", "--filter", "HomeDevicesControllerTests"], {
    cwd: root,
    encoding: "utf8",
    timeout: 600000,
    env: process.env,
  })
})

function output() {
  return `${result?.stdout || ""}\n${result?.stderr || ""}`
}

function requirePassed(name) {
  if (!result || result.status !== 0) {
    throw new Error(output().slice(-4000))
  }
  if (!output().includes(name)) {
    throw new Error(output().slice(-4000))
  }
}

Given("a Home health report was collected less than five seconds ago", function () {
  requirePassed("two placement scores inside five seconds probe once")
})

When("the client posts two placement scores inside that window", function () {
  requirePassed("two placement scores inside five seconds probe once")
})

Then("members are probed once and both responses rank from that report", function () {
  requirePassed("two placement scores inside five seconds probe once")
  requirePassed("placement score does not call DockerEngine.liveSnapshot")
})

Given("one member accepts no mTLS connection and the others answer", function () {
  requirePassed("dead member score returns inside the probe budget")
})

When("the client posts a placement score and no fresh health report exists", function () {
  requirePassed("dead member score returns inside the probe budget")
})

Then("the handler returns by the 2.5 second probe budget and that member is ineligible", function () {
  requirePassed("dead member score returns inside the probe budget")
})

Given("the previous probe recorded connectTimeout for a member", function () {
  requirePassed("recorded connect timeout is not probed on the next score")
})

When("another placement score runs before the reachability refresh", function () {
  requirePassed("recorded connect timeout is not probed on the next score")
})

Then("the handler does not open a hop to that member", function () {
  requirePassed("recorded connect timeout is not probed on the next score")
})
