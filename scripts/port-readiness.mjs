#!/usr/bin/env node
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(scriptDir, "..");
const manifestPath = path.join(packageRoot, "PortReadiness", "port-readiness.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const args = new Set(process.argv.slice(2));

const allowedStatuses = new Set(["ported", "partial", "gap"]);

function validateManifest() {
  if (!Array.isArray(manifest.items) || manifest.items.length === 0) {
    throw new Error("Manifest must contain at least one item.");
  }

  const ids = new Set();
  for (const item of manifest.items) {
    if (!item.id || typeof item.id !== "string") {
      throw new Error("Every readiness item needs a string id.");
    }
    if (ids.has(item.id)) {
      throw new Error(`Duplicate readiness item id: ${item.id}`);
    }
    ids.add(item.id);

    if (!allowedStatuses.has(item.status)) {
      throw new Error(`Item ${item.id} has invalid status: ${item.status}`);
    }
    if (!Array.isArray(item.scopes) || item.scopes.length === 0) {
      throw new Error(`Item ${item.id} must list at least one scope.`);
    }
    if (typeof item.weight !== "number" || item.weight <= 0) {
      throw new Error(`Item ${item.id} must have a positive numeric weight.`);
    }
    if (typeof item.coverage !== "number" || item.coverage < 0 || item.coverage > 1) {
      throw new Error(`Item ${item.id} coverage must be between 0 and 1.`);
    }
    if (item.status === "ported" && item.coverage !== 1) {
      throw new Error(`Item ${item.id} is ported but coverage is not 1.`);
    }
    if (item.status === "gap" && item.coverage > 0.1) {
      throw new Error(`Item ${item.id} is marked gap but has coverage > 0.1.`);
    }
  }
}

function score(scope) {
  const items = manifest.items.filter((item) => item.scopes.includes(scope));
  const totalWeight = items.reduce((sum, item) => sum + item.weight, 0);
  const coveredWeight = items.reduce(
    (sum, item) => sum + item.weight * item.coverage,
    0
  );
  const pct = totalWeight === 0 ? 0 : coveredWeight / totalWeight;
  return { scope, items, totalWeight, coveredWeight, pct };
}

function pct(value) {
  return `${(value * 100).toFixed(1)}%`;
}

function fmt(value) {
  return Number.isInteger(value) ? `${value}` : value.toFixed(1);
}

function printHuman() {
  const scopes = Object.keys(manifest.scorePolicy.scopes);
  console.log(`Port readiness for agents ${manifest.generatedFrom.upstreamVersion}`);
  console.log(`Manifest: ${path.relative(packageRoot, manifestPath)}`);
  console.log("");
  console.log("Scope              Score   Covered / Weight");
  console.log("-----------------  ------  ----------------");
  for (const scope of scopes) {
    const s = score(scope);
    console.log(
      `${scope.padEnd(17)}  ${pct(s.pct).padEnd(6)}  ${fmt(s.coveredWeight).padStart(7)} / ${fmt(s.totalWeight)}`
    );
  }

  const requestedScope = process.argv.find((arg) => arg.startsWith("--gaps="))?.split("=")[1] ?? "swiftClient";
  const scored = score(requestedScope);
  const gaps = [...scored.items]
    .map((item) => ({
      ...item,
      missingWeight: item.weight * (1 - item.coverage)
    }))
    .filter((item) => item.missingWeight > 0)
    .sort((a, b) => b.missingWeight - a.missingWeight)
    .slice(0, 8);

  console.log("");
  console.log(`Largest remaining ${requestedScope} gaps:`);
  for (const item of gaps) {
    console.log(
      `- ${item.id}: ${pct(item.coverage)} covered, weight ${item.weight}; ${item.gap ?? item.title}`
    );
  }
}

validateManifest();

if (args.has("--json")) {
  const scopes = Object.keys(manifest.scorePolicy.scopes);
  const scores = Object.fromEntries(
    scopes.map((scopeName) => {
      const s = score(scopeName);
      return [
        scopeName,
        {
          score: Number(s.pct.toFixed(4)),
          percent: Number((s.pct * 100).toFixed(1)),
          coveredWeight: Number(s.coveredWeight.toFixed(2)),
          totalWeight: Number(s.totalWeight.toFixed(2))
        }
      ];
    })
  );
  console.log(JSON.stringify({ upstream: manifest.generatedFrom, scores }, null, 2));
} else {
  printHuman();
}
