#!/usr/bin/env node
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(scriptDir, "..");
const upstreamRoot = process.env.CF_AGENTS_REPO ?? path.resolve(packageRoot, "../agents");
const port = Number(process.env.CF_AGENTS_TEST_WORKER_PORT ?? "18787");
const workerURL = `http://127.0.0.1:${port}`;

const upstreamPackageJSON = path.join(upstreamRoot, "package.json");
if (!existsSync(upstreamPackageJSON)) {
  console.error(`Missing upstream cloudflare/agents repo: ${upstreamRoot}`);
  console.error("Set CF_AGENTS_REPO to the local cloudflare/agents checkout.");
  process.exit(1);
}

const requireFromUpstream = createRequire(upstreamPackageJSON);
let wranglerURL;
try {
  wranglerURL = pathToFileURL(requireFromUpstream.resolve("wrangler")).href;
} catch {
  console.error(`Missing npm dependencies in ${upstreamRoot}`);
  console.error(`Run: cd ${upstreamRoot} && npm install`);
  process.exit(1);
}

const { unstable_dev } = await import(wranglerURL);

const testsDir = path.join(upstreamRoot, "packages/agents/src/tests");
const workerPath = path.join(testsDir, "worker.ts");
const configPath = path.join(testsDir, "wrangler.jsonc");

let worker;
try {
  console.log(`[compat] Starting upstream test worker at ${workerURL}`);
  worker = await unstable_dev(workerPath, {
    config: configPath,
    experimental: {
      disableExperimentalWarning: true
    },
    port,
    ip: "127.0.0.1",
    persist: false,
    logLevel: "warn"
  });

  const env = {
    ...process.env,
    CF_AGENTS_TEST_WORKER_URL: workerURL
  };
  const child = spawn("swift", ["test", "--filter", "UpstreamCompatibilityTests"], {
    cwd: packageRoot,
    env,
    stdio: "inherit"
  });

  const exitCode = await new Promise((resolve) => {
    child.on("exit", (code) => resolve(code ?? 1));
  });

  process.exitCode = exitCode;
} finally {
  if (worker) {
    console.log("[compat] Stopping upstream test worker");
    await worker.stop();
  }
}
