#!/usr/bin/env node
// Scans an org's repos and adds missing entries to repo-inventory.yml.
//
// Usage:
//   update-inventory.mjs ORG [options]
//
// Options:
//   --inventory PATH   Path to inventory file (default: ../repo-inventory.yml)
//   --gh CMD           GitHub CLI command (default: gh; use scripts/gh-bot for bot creds)
//   --dry-run          Print the updated YAML without writing
//   --overwrite        Replace existing repo entries instead of skipping them

import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import yaml from "js-yaml";

const scriptDir = path.dirname(new URL(import.meta.url).pathname);

function usage() {
  console.error(
    "Usage: update-inventory.mjs ORG [--inventory PATH] [--gh CMD] [--dry-run] [--overwrite]",
  );
}

function parseArgs(args) {
  const opts = {
    org: null,
    inventory: path.resolve(scriptDir, "..", "repo-inventory.yml"),
    gh: "gh",
    dryRun: false,
    overwrite: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--inventory") opts.inventory = args[++i];
    else if (a === "--gh") opts.gh = args[++i];
    else if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--overwrite") opts.overwrite = true;
    else if (!a.startsWith("--") && opts.org === null) opts.org = a;
    else {
      console.error(`error: unknown argument: ${a}`);
      usage();
      process.exit(1);
    }
  }
  if (!opts.org) {
    usage();
    process.exit(1);
  }
  return opts;
}

function ghJson(opts, ...args) {
  const cmd = [opts.gh, ...args].join(" ");
  return JSON.parse(execSync(cmd, { encoding: "utf8", stdio: ["pipe", "pipe", "inherit"] }));
}

// Skip directories that are research, archive, or misc — not maintained production code.
const SKIP_DIR_RE = /(?:^|\/)(?:research|archive|misc|node_modules)(?:\/|$)/;

function dirOf(filePath) {
  const d = path.posix.dirname(filePath);
  return d === "." ? "/" : `/${d}`;
}

function detectDirs(treeItems, filename) {
  const dirs = new Set();
  for (const item of treeItems) {
    if (item.type !== "blob") continue;
    if (SKIP_DIR_RE.test(item.path)) continue;
    if (item.path === filename || item.path.endsWith(`/${filename}`)) {
      dirs.add(dirOf(item.path));
    }
  }
  return [...dirs].sort();
}

function fetchTree(opts, org, repoName) {
  // Try HEAD first, fall back to main
  for (const ref of ["HEAD", "main", "master"]) {
    try {
      const url = `repos/${org}/${repoName}/git/trees/${ref}?recursive=1`;
      const resp = ghJson(opts, "api", `"${url}"`);
      if (resp.truncated) {
        console.error(`    warning: tree truncated for ${repoName}, some dirs may be missing`);
      }
      return resp.tree ?? [];
    } catch {
      // try next ref
    }
  }
  return null;
}

function buildEntry(org, repoName, tree) {
  const juliaDirs = detectDirs(tree, "Project.toml");
  const npmDirs = detectDirs(tree, "package.json");
  const cargoDirs = detectDirs(tree, "Cargo.toml");

  if (juliaDirs.length === 0 && npmDirs.length === 0 && cargoDirs.length === 0) return null;

  const entry = { name: `${org}/${repoName}` };

  if (juliaDirs.length > 0) entry.julia_directories = juliaDirs;
  if (npmDirs.length > 0) entry.npm_directories = npmDirs;
  if (cargoDirs.length > 0) entry.cargo_directories = cargoDirs;

  const dependabot = {};
  if (npmDirs.length > 0) dependabot.npm = { enabled: true };
  if (cargoDirs.length > 0) dependabot.cargo = { enabled: true };
  if (Object.keys(dependabot).length > 0) entry.dependabot = dependabot;

  return entry;
}

function loadInventory(inventoryPath) {
  if (!fs.existsSync(inventoryPath)) return { defaults: {}, repositories: [] };
  const raw = yaml.load(fs.readFileSync(inventoryPath, "utf8")) ?? {};
  return { defaults: raw.defaults ?? {}, repositories: raw.repositories ?? [] };
}

function writeInventory(inventoryPath, inventory) {
  const header = "# Editable inventory for the Dependabot configuration rollout.\n";
  const body = yaml.dump(
    { defaults: inventory.defaults, repositories: inventory.repositories },
    { lineWidth: 120 },
  );
  return header + body;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { org } = opts;

  console.error(`Fetching repo list for ${org}...`);
  const repos = ghJson(
    opts,
    "repo",
    "list",
    org,
    "--limit",
    "200",
    "--json",
    "name,isArchived,isFork",
  );
  const active = repos
    .filter((r) => !r.isArchived && !r.isFork)
    .map((r) => r.name)
    .sort();
  console.error(`Found ${active.length} active non-fork repos`);

  const inventory = loadInventory(opts.inventory);
  const existingNames = new Set(inventory.repositories.map((r) => r.name));

  let added = 0;
  let skipped = 0;
  let noManifests = 0;
  const newEntries = [];

  for (const repoName of active) {
    const fullName = `${org}/${repoName}`;

    if (!opts.overwrite && existingNames.has(fullName)) {
      console.error(`  skip (exists): ${repoName}`);
      skipped++;
      continue;
    }

    process.stderr.write(`  scanning: ${repoName} ... `);
    const tree = fetchTree(opts, org, repoName);

    if (!tree) {
      console.error("could not fetch tree, skipping");
      continue;
    }

    const entry = buildEntry(org, repoName, tree);
    if (!entry) {
      console.error("no manifests");
      noManifests++;
      continue;
    }

    console.error(
      `julia:${entry.julia_directories?.length ?? 0} npm:${entry.npm_directories?.length ?? 0} cargo:${entry.cargo_directories?.length ?? 0}`,
    );
    newEntries.push(entry);
    added++;
  }

  if (opts.overwrite) {
    const newNames = new Set(newEntries.map((e) => e.name));
    inventory.repositories = [
      ...inventory.repositories.filter((r) => !newNames.has(r.name)),
      ...newEntries,
    ].sort((a, b) => a.name.localeCompare(b.name));
  } else {
    inventory.repositories = [...inventory.repositories, ...newEntries].sort((a, b) =>
      a.name.localeCompare(b.name),
    );
  }

  const output = writeInventory(opts.inventory, inventory);

  if (opts.dryRun) {
    process.stdout.write(output);
  } else {
    fs.writeFileSync(opts.inventory, output);
    console.error(`\nWrote ${opts.inventory}`);
  }
  console.error(`Added: ${added}  Skipped (exists): ${skipped}  No manifests: ${noManifests}`);
}

try {
  main();
} catch (e) {
  console.error(`error: ${e.message}`);
  process.exit(1);
}
