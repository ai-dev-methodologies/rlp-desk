#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const pkg = require(path.join(__dirname, "..", "package.json"));

const home = os.homedir();
const claudeDir = path.join(home, ".claude");
const commandsDir = path.join(claudeDir, "commands");
const deskDir = path.join(claudeDir, "ralph-desk");
const docsDir = path.join(deskDir, "docs");
const nodeDir = path.join(deskDir, "node");
const pkgDir = path.join(__dirname, "..");
const runtimeSources = [
  ["src/commands/rlp-desk.md", path.join(commandsDir, "rlp-desk.md")],
  ["src/governance.md", path.join(deskDir, "governance.md")],
  ["src/model-upgrade-table.md", path.join(deskDir, "model-upgrade-table.md")],
  ["README.md", path.join(deskDir, "README.md")],
  ["install.sh", path.join(deskDir, "install.sh")],
  ["docs/architecture.md", path.join(docsDir, "architecture.md")],
  ["docs/getting-started.md", path.join(docsDir, "getting-started.md")],
  ["docs/protocol-reference.md", path.join(docsDir, "protocol-reference.md")],
  ["docs/TODO-verification-next.md", path.join(docsDir, "TODO-verification-next.md")],
];
const legacyFiles = [
  path.join(deskDir, "init_ralph_desk.zsh"),
  path.join(deskDir, "run_ralph_desk.zsh"),
  path.join(deskDir, "lib_ralph_desk.zsh"),
];

function getNodeVersion() {
  return process.env.RLP_DESK_NODE_VERSION_OVERRIDE || process.version;
}

function isSupportedNodeVersion(version) {
  const match = /^v(\d+)/.exec(version || "");
  return Boolean(match) && Number(match[1]) >= 16;
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function removePath(targetPath) {
  fs.rmSync(targetPath, { recursive: true, force: true });
}

function copyFile(sourceRelativePath, targetPath) {
  ensureDir(path.dirname(targetPath));
  fs.copyFileSync(path.join(pkgDir, sourceRelativePath), targetPath);
  console.log("  + " + targetPath);
}

function copyMarkdownDirectory(sourceRelativeDir, targetDir) {
  const sourceDir = path.join(pkgDir, sourceRelativeDir);
  if (!fs.existsSync(sourceDir)) {
    return;
  }

  ensureDir(targetDir);
  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    if (entry.isDirectory()) {
      copyMarkdownDirectory(path.join(sourceRelativeDir, entry.name), targetPath);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".md")) {
      ensureDir(path.dirname(targetPath));
      fs.copyFileSync(sourcePath, targetPath);
      console.log("  + " + targetPath);
    }
  }
}

function copyNodeRuntime(sourceDir, targetDir) {
  removePath(targetDir);
  ensureDir(targetDir);

  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    if (entry.isDirectory()) {
      copyNodeRuntime(sourcePath, targetPath);
      continue;
    }
    if (entry.isFile()) {
      ensureDir(path.dirname(targetPath));
      fs.copyFileSync(sourcePath, targetPath);
      console.log("  + " + targetPath);
    }
  }
}

console.log("");
console.log("  RLP Desk v" + pkg.version);
console.log("  ================");
console.log("");

if (!isSupportedNodeVersion(getNodeVersion())) {
  console.log("  [warn] RLP Desk requires Node.js >= 16 for the Node rewrite runtime.");
  console.log("         Existing zsh installation was left unchanged.");
  console.log("");
  process.exit(0);
}

ensureDir(commandsDir);
ensureDir(deskDir);
ensureDir(docsDir);

for (const legacyFile of legacyFiles) {
  removePath(legacyFile);
}

for (const [sourcePath, targetPath] of runtimeSources) {
  copyFile(sourcePath, targetPath);
}

copyMarkdownDirectory("docs/internal", path.join(docsDir, "internal"));
copyMarkdownDirectory("docs/blueprints", path.join(docsDir, "blueprints"));
copyNodeRuntime(path.join(pkgDir, "src", "node"), nodeDir);

console.log("");
console.log("  Done! Open Claude Code and run:");
console.log("    /rlp-desk brainstorm \"your task description\"");
console.log("");
