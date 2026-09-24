import { spawnSync } from "node:child_process";
import { BeforeAll, Then, When, setDefaultTimeout } from "@cucumber/cucumber";
import { fileURLToPath } from "node:url";
import path from "node:path";

setDefaultTimeout(600_000);

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
let output = "";
let status = 1;

BeforeAll(function () {
  const result = spawnSync(
    "mise",
    ["exec", "--", "swift", "test", "--filter", "LocalManagementBoundaryTests"],
    {
      cwd: repo,
      encoding: "utf8",
      env: {
        ...process.env,
        LD_LIBRARY_PATH: ["/usr/local/lib/barkvisor/compat", process.env.LD_LIBRARY_PATH]
          .filter(Boolean)
          .join(":"),
      },
    },
  );
  output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  status = result.status ?? 1;
});

When("the local management boundary suite runs", function () {
  if (status !== 0) {
    throw new Error(output.slice(-4000));
  }
});

Then("the boundary suite passes", function () {
  if (!output.includes("LocalManagementBoundaryTests")) {
    throw new Error(output.slice(-4000));
  }
});
