const { When, Then, Before } = require("@cucumber/cucumber");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

let result;

Before(function () {
  if (result) return;
  const root = path.resolve(__dirname, "../..");
  const swift = process.env.SWIFT || "swift";
  result = spawnSync(swift, ["test", "--filter", "WorkloadFactTests"], {
    cwd: root,
    encoding: "utf8",
    timeout: 600000,
  });
});

When("the workload fact tests run", function () {
  if (!result || result.status !== 0) {
    const output = `${result?.stdout || ""}\n${result?.stderr || ""}`;
    throw new Error(output.slice(-4000));
  }
});

Then("those tests pass", function () {
  const output = `${result.stdout}\n${result.stderr}`;
  if (!output.includes('Suite "Workload facts" passed')) {
    throw new Error(output.slice(-4000));
  }
});
