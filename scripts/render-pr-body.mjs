#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";
import ejs from "ejs";

const [templatePath, outputPath] = process.argv.slice(2);

if (!templatePath || !outputPath) {
  console.error("Usage: render-pr-body.mjs TEMPLATE OUTPUT");
  process.exit(2);
}

const template = fs.readFileSync(templatePath, "utf8");
const data = {
  automationRepo: process.env.AUTOMATION_REPO ?? "shravangoswami-bot/dependabot-config-bot",
  workflowRunUrl: process.env.WORKFLOW_RUN_URL ?? "",
  compathelperBefore: process.env.COMPATHELPER_BEFORE ?? "missing",
  dependabotBefore: process.env.DEPENDABOT_BEFORE ?? "missing",
  existingDependabotPath: process.env.EXISTING_DEPENDABOT_PATH ?? "",
  juliaDirectories: process.env.JULIA_DIRECTORIES ?? "",
  npmDirectories: process.env.NPM_DIRECTORIES ?? "",
  npmEnabled: process.env.NPM_ENABLED === "true",
  cargoDirectories: process.env.CARGO_DIRECTORIES ?? "",
  cargoEnabled: process.env.CARGO_ENABLED === "true",
  changesMade: process.env.CHANGES_MADE ?? "- Updated dependency automation.",
};

fs.writeFileSync(outputPath, ejs.render(template, data).trimEnd() + "\n");
