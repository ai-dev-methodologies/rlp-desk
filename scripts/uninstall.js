#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");

const home = os.homedir();
const claudeDir = path.join(home, ".claude");
const commandsDir = path.join(claudeDir, "commands");
const deskDir = path.join(claudeDir, "ralph-desk");

console.log("");
console.log("  Uninstalling RLP Desk...");
console.log("");

const files = [
  path.join(commandsDir, "rlp-desk.md"),
  path.join(deskDir, "governance.md"),
  path.join(deskDir, "model-upgrade-table.md"),
  path.join(deskDir, "README.md"),
  path.join(deskDir, "install.sh"),
  // v0.14.0: zsh tmux runner is part of the install set again — clean it up
  // on uninstall so users do not end up with orphaned 0o444 files.
  path.join(deskDir, "init_ralph_desk.zsh"),
  path.join(deskDir, "run_ralph_desk.zsh"),
  path.join(deskDir, "lib_ralph_desk.zsh"),
];

for (const targetPath of files) {
  try {
    fs.rmSync(targetPath, { recursive: true, force: true });
    console.log("  - " + targetPath);
  } catch (_) {
    // Ignore missing files.
  }
}

for (const subdir of ["docs", "node"]) {
  const targetPath = path.join(deskDir, subdir);
  try {
    fs.rmSync(targetPath, { recursive: true, force: true });
    console.log("  - " + targetPath);
  } catch (_) {
    // Ignore missing directories.
  }
}

try {
  const remaining = fs.readdirSync(deskDir);
  if (remaining.length === 0) {
    fs.rmdirSync(deskDir);
    console.log("  - " + deskDir);
  }
} catch (_) {
  // Directory may not exist.
}

console.log("");
console.log("  RLP Desk uninstalled.");
console.log("");
