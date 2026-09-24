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

let socketOutput = "";
let socketStatus = 1;

When("the socket operation suite runs", function () {
  const result = spawnSync(
    "mise",
    ["exec", "--", "swift", "test", "--filter", "WorkloadSocketOperationTests"],
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
  socketOutput = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  socketStatus = result.status ?? 1;
  if (socketStatus !== 0) {
    throw new Error(socketOutput.slice(-4000));
  }
});

let publicOutput = "";
let publicStatus = 1;

When("the public listener suite runs", function () {
  const result = spawnSync(
    "mise",
    ["exec", "--", "swift", "test", "--filter", "PublicListenerTests"],
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
  publicOutput = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  publicStatus = result.status ?? 1;
  if (publicStatus !== 0) {
    throw new Error(publicOutput.slice(-4000));
  }
});

let recoveryOutput = "";
let recoveryStatus = 1;

When("the daemon recovery suite runs", function () {
  const result = spawnSync(
    "mise",
    ["exec", "--", "swift", "test", "--filter", "DaemonRecoveryTests"],
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
  recoveryOutput = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  recoveryStatus = result.status ?? 1;
  if (recoveryStatus !== 0) {
    throw new Error(recoveryOutput.slice(-4000));
  }
});

Then("the daemon recovery suite passes", function () {
  if (!recoveryOutput.includes("DaemonRecoveryTests")) {
    throw new Error(recoveryOutput.slice(-4000));
  }
});

Then("the public listener suite passes", function () {
  if (!publicOutput.includes("PublicListenerTests")) {
    throw new Error(publicOutput.slice(-4000));
  }
});

Then("the socket operation suite passes", function () {
  if (!socketOutput.includes("WorkloadSocketOperationTests")) {
    throw new Error(socketOutput.slice(-4000));
  }
});
