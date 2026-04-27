#!/usr/bin/env node
"use strict";

// v5.7 §4.4 — generate src/node/MANIFEST.txt listing every Node runtime file.
// install.sh reads this manifest line-by-line and curls each file. Without
// this, the curl-pipe-shell install path has no Node leader (release-blocker).
//
// Run as `prepublishOnly` AND on every CI build to keep the manifest in sync.
// CI drift check: `node scripts/build-node-manifest.js --check` returns
// non-zero exit if the on-disk manifest does not match the regenerated form.

const fs = require("fs");
const path = require("path");

const repoRoot = path.join(__dirname, "..");
const nodeDir = path.join(repoRoot, "src", "node");
const manifestPath = path.join(nodeDir, "MANIFEST.txt");

function walk(dir, base) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const sourcePath = path.join(dir, entry.name);
    const relPath = path.posix.join(base, entry.name);
    if (entry.isDirectory()) {
      files.push(...walk(sourcePath, relPath));
    } else if (entry.isFile() && entry.name.endsWith(".mjs")) {
      files.push(relPath);
    }
  }
  return files;
}

const generated = walk(nodeDir, "").join("\n") + "\n";

const isCheck = process.argv.includes("--check");

if (isCheck) {
  const onDisk = fs.existsSync(manifestPath) ? fs.readFileSync(manifestPath, "utf8") : "";
  if (onDisk !== generated) {
    console.error("MANIFEST.txt drift detected. Run: node scripts/build-node-manifest.js");
    console.error("--- ON-DISK ---");
    console.error(onDisk);
    console.error("--- GENERATED ---");
    console.error(generated);
    process.exit(1);
  }
  console.log("MANIFEST.txt in sync (" + generated.split("\n").filter(Boolean).length + " entries).");
} else {
  fs.writeFileSync(manifestPath, generated);
  console.log("Wrote " + manifestPath + " (" + generated.split("\n").filter(Boolean).length + " entries).");
}
