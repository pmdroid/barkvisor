const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const { Then } = require("@cucumber/cucumber");

const root = path.resolve(__dirname, "../..");
const swiftBin = "/home/pascal/.local/share/mise/installs/swift/6.4.0/usr/bin";

let suiteOutput;

function suite() {
  if (suiteOutput) return suiteOutput;
  const env = { ...process.env, PATH: `${swiftBin}:${process.env.PATH}` };
  const result = spawnSync(
    "swift",
    ["test", "--filter", "WorkloadOperationCoordinatorTests"],
    { cwd: root, env, encoding: "utf8", maxBuffer: 20 * 1024 * 1024 },
  );
  suiteOutput = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  if (result.status !== 0) {
    throw new Error(suiteOutput.slice(-4000));
  }
  return suiteOutput;
}

Then("the coordinator test {string} passed", function (name) {
  const output = suite();
  assert.match(output, new RegExp(`Test "${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}" passed`));
});
