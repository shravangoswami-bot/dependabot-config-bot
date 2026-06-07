#!/usr/bin/env node
// Patches GitHub Actions workflow files to skip codecov upload on Dependabot PRs.
//
// Usage: patch-codecov.mjs REPO_DIR
//
// For each codecov/codecov-action step:
//   - No `if:` after `uses:` → inserts `if: github.actor != 'dependabot[bot]'`
//   - `if:` already exists → combines as `(existing) && github.actor != 'dependabot[bot]'`
//   - Already contains our condition → no change (idempotent)
//
// Prints patched file paths to stdout.
// Exits 0 if changes were made, 1 if nothing to do, 2 on error.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const OUR_CONDITION = "github.actor != 'dependabot[bot]'";

function patchContent(content) {
  const lines = content.split("\n");
  const result = [];
  let changed = false;
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Shape A: "      - uses: codecov/codecov-action..." (first key in step)
    const shapeA = line.match(/^(\s+)-\s+(uses:\s+codecov\/codecov-action.*)/);
    // Shape B: "        uses: codecov/codecov-action..." (step has name: or similar before)
    const shapeB = !shapeA && line.match(/^(\s+)(uses:\s+codecov\/codecov-action.*)/);

    if (!shapeA && !shapeB) {
      result.push(line);
      i++;
      continue;
    }

    // keyIndent: the indentation level of sibling keys (if:, with:, etc.)
    const keyIndent = shapeA ? shapeA[1] + "  " : shapeB[1];

    result.push(line);
    i++;

    // Pass through any blank lines immediately after uses:
    while (i < lines.length && lines[i].trim() === "") {
      result.push(lines[i]);
      i++;
    }

    if (i >= lines.length) continue;

    const nextLine = lines[i];
    const ifMatch = nextLine.match(new RegExp(`^${keyIndent}if:\\s+(.*)`));

    if (ifMatch) {
      const existing = ifMatch[1].trim();

      if (existing.includes(OUR_CONDITION)) {
        // Already patched — output unchanged
        result.push(nextLine);
        i++;
      } else {
        // Combine: wrap in parens if existing uses || or && to preserve precedence
        const combined =
          existing.match(/\|\||&&/)
            ? `(${existing}) && ${OUR_CONDITION}`
            : `${existing} && ${OUR_CONDITION}`;
        result.push(`${keyIndent}if: ${combined}`);
        changed = true;
        i++; // skip original if: line
      }
    } else {
      // No if: — insert one before whatever comes next
      result.push(`${keyIndent}if: ${OUR_CONDITION}`);
      changed = true;
      // don't increment i — nextLine not yet handled
    }
  }

  return { content: result.join("\n"), changed };
}

function main() {
  const repoDir = process.argv[2];
  if (!repoDir) {
    console.error("Usage: patch-codecov.mjs REPO_DIR");
    process.exit(2);
  }

  const workflowsDir = path.join(repoDir, ".github", "workflows");
  if (!fs.existsSync(workflowsDir)) {
    process.exit(1);
  }

  const files = fs
    .readdirSync(workflowsDir)
    .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
    .sort();

  let anyChanged = false;

  for (const file of files) {
    const filePath = path.join(workflowsDir, file);
    const content = fs.readFileSync(filePath, "utf8");

    if (!content.includes("codecov/codecov-action")) continue;

    const { content: patched, changed } = patchContent(content);
    if (changed) {
      fs.writeFileSync(filePath, patched, "utf8");
      console.log(path.relative(repoDir, filePath));
      anyChanged = true;
    }
  }

  process.exit(anyChanged ? 0 : 1);
}

main();
