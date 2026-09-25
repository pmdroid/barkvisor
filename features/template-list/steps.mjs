import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Before, Given, Then, When } from "@cucumber/cucumber"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
let result

Before(function () {
  if (result) return
  const swift = process.env.SWIFT || "swift"
  result = spawnSync(swift, ["test", "--filter", "TemplateCatalogListTests"], {
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

Given("the Docker discovery cache is cold and a catalog with Debian 13 is stored", function () {
  requirePassed("template list skips live docker probe")
})

When("the client GET /api/templates", function () {
  requirePassed("template list skips live docker probe")
})

Then(
  "the response includes Debian 13 and both catalog image arches and the handler did not call DockerEngine.liveSnapshot",
  function () {
    requirePassed("template list skips live docker probe")
  },
)

Given("a template requires dockerEngine and this Device does not have it", function () {
  requirePassed("deploy rejects missing docker engine")
})

When("the operator dry-runs or deploys that template", function () {
  requirePassed("deploy rejects missing docker engine")
})

Then("template compatibility rejects the deploy for the missing feature", function () {
  requirePassed("deploy rejects missing docker engine")
})
