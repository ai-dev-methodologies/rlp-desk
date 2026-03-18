#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");

const home = os.homedir();
const claudeDir = path.join(home, ".claude");
const commandsDir = path.join(claudeDir, "commands");
const deskDir = path.join(claudeDir, "ralph-desk");
const pkgDir = path.join(__dirname, "..");

console.log("");
console.log("  RLP Desk v0.0.1");
console.log("  ================");
console.log("");

// Create directories
fs.mkdirSync(commandsDir, { recursive: true });
fs.mkdirSync(deskDir, { recursive: true });

// Copy files
const copies = [
  ["src/commands/rlp-desk.md", path.join(commandsDir, "rlp-desk.md")],
  [
    "src/scripts/init_ralph_desk.zsh",
    path.join(deskDir, "init_ralph_desk.zsh"),
  ],
  ["src/governance.md", path.join(deskDir, "governance.md")],
];

for (const [src, dest] of copies) {
  fs.copyFileSync(path.join(pkgDir, src), dest);
  console.log("  + " + dest);
}

// Make scripts executable
try {
  fs.chmodSync(path.join(deskDir, "init_ralph_desk.zsh"), 0o755);
} catch (_) {
  // chmod may fail on Windows — not critical
}

console.log("");
console.log("  Done! Open Claude Code and run:");
console.log("    /rlp-desk brainstorm \"your task description\"");
console.log("");
