#!/usr/bin/env node
// Patches GitHub Actions workflow files to skip codecov upload on Dependabot PRs.
//
// Usage: patch-codecov.mjs REPO_DIR
//
// Finds all .github/workflows/*.yml files containing codecov/codecov-action and
// adds `if: github.actor != 'dependabot[bot]'` to those steps if not already present.
//
// Prints patched file paths to stdout, one per line.
// Exits 0 if any files were changed, 1 if nothing needed patching, 2 on error.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

// Two step shapes to handle:
//
// Shape A — step starts with `- uses:` (most common in Julia CI):
//   Before:
//       - uses: codecov/codecov-action@v6
//         with:
//           files: lcov.info
//   After:
//       - if: github.actor != 'dependabot[bot]'
//         uses: codecov/codecov-action@v6
//         with:
//           files: lcov.info
//
// Shape B — step has a `name:` (or other key) before `uses:`:
//   Before:
//         uses: codecov/codecov-action@v6
//   After:
//         if: github.actor != 'dependabot[bot]'
//         uses: codecov/codecov-action@v6

const IF_CONDITION = "github.actor != 'dependabot[bot]'";

function patchContent(content) {
  const lines = content.split("\n");
  const result = [];
  let changed = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Shape A: "      - uses: codecov/codecov-action"
    const shapeA = line.match(/^(\s+)-\s+(uses:\s+codecov\/codecov-action.*)/);

    // Shape B: "        uses: codecov/codecov-action" (no leading -)
    const shapeB = !shapeA && line.match(/^(\s+)(uses:\s+codecov\/codecov-action.*)/);

    if (shapeA) {
      const listIndent = shapeA[1]; // spaces before -
      const keyIndent = listIndent + "  "; // sibling key indent
      const usesRest = shapeA[2]; // "uses: codecov/codecov-action..."

      // Check forward for an existing `if:` sibling key in this step
      const hasIf = linesHaveIfAt(lines, i + 1, keyIndent);

      if (!hasIf) {
        result.push(`${listIndent}- if: ${IF_CONDITION}`);
        result.push(`${keyIndent}${usesRest}`);
        changed = true;
      } else {
        result.push(line);
      }
    } else if (shapeB) {
      const indent = shapeB[1];

      // Check backward for an existing `if:` sibling key in this step
      const hasIf = resultHasIfAt(result, indent);

      if (!hasIf) {
        result.push(`${indent}if: ${IF_CONDITION}`);
        changed = true;
      }
      result.push(line);
    } else {
      result.push(line);
    }
  }

  return { content: result.join("\n"), changed };
}

// Look forward from `startIdx` for an `if:` key at exactly `keyIndent` indentation,
// stopping when we leave the step (line with shorter indent).
function linesHaveIfAt(lines, startIdx, keyIndent) {
  for (let j = startIdx; j < lines.length; j++) {
    const l = lines[j];
    if (l.trim() === "") continue;
    const indentLen = l.match(/^(\s*)/)[1].length;
    if (indentLen < keyIndent.length) return false;
    if (l.startsWith(`${keyIndent}if:`)) return true;
  }
  return false;
}

// Look backward through already-collected lines for an `if:` belonging to the
// same step as `indent` (the key indent, e.g. 8 spaces).
//
// Stops when it hits the step's own list marker (`      - something`) — if that
// marker is `- if:` we return true (already patched), otherwise false.
// Also stops if indentation drops below the list level entirely.
function resultHasIfAt(result, indent) {
  // listIndent is the indent before the `-` that opens this step (indent minus 2)
  const listIndent = indent.length >= 2 ? indent.slice(0, -2) : "";

  for (let j = result.length - 1; j >= 0; j--) {
    const l = result[j];
    if (l.trim() === "") continue;

    // Direct `if:` at key indent level (step already had a name: before uses:)
    if (l.startsWith(`${indent}if:`)) return true;

    // Step opened with `- if:` (already patched by us)
    if (l.startsWith(`${listIndent}- if:`)) return true;

    // Any other `- ` at the list level is a step boundary — stop
    if (l.match(new RegExp(`^${listIndent}-`))) return false;

    // Indentation shrank below the list level — left steps block entirely
    const lineIndentLen = l.match(/^(\s*)/)[1].length;
    if (lineIndentLen < listIndent.length) return false;
  }
  return false;
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
