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
  path.join(deskDir, "init_ralph_desk.zsh"),
  path.join(deskDir, "run_ralph_desk.zsh"),
  path.join(deskDir, "governance.md"),
];

for (const f of files) {
  try {
    fs.unlinkSync(f);
    console.log("  - " + f);
  } catch (_) {
    // File may not exist
  }
}

// Remove ralph-desk dir if empty
try {
  const remaining = fs.readdirSync(deskDir);
  if (remaining.length === 0) {
    fs.rmdirSync(deskDir);
    console.log("  - " + deskDir);
  }
} catch (_) {
  // Directory may not exist
}

console.log("");
console.log("  RLP Desk uninstalled.");
console.log("");
