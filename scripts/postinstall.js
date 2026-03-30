#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync } = require("child_process");

const home = os.homedir();
const claudeDir = path.join(home, ".claude");
const commandsDir = path.join(claudeDir, "commands");
const deskDir = path.join(claudeDir, "ralph-desk");
const pkgDir = path.join(__dirname, "..");
const pkg = require(path.join(pkgDir, "package.json"));

console.log("");
console.log("  RLP Desk v" + pkg.version);
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
  [
    "src/scripts/run_ralph_desk.zsh",
    path.join(deskDir, "run_ralph_desk.zsh"),
  ],
  [
    "src/scripts/lib_ralph_desk.zsh",
    path.join(deskDir, "lib_ralph_desk.zsh"),
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
  fs.chmodSync(path.join(deskDir, "run_ralph_desk.zsh"), 0o755);
  fs.chmodSync(path.join(deskDir, "lib_ralph_desk.zsh"), 0o755);
} catch (_) {
  // chmod may fail on Windows — not critical
}

// Check tmux availability
try {
  execSync("which tmux", { stdio: "ignore" });
} catch (_) {
  console.log("  [warn] tmux not found. Tmux execution mode (--mode tmux) will not be available.");
  console.log("         Install tmux to use lean mode: https://github.com/tmux/tmux/wiki/Installing");
  console.log("");
}

console.log("");
console.log("  Done! Open Claude Code and run:");
console.log("    /rlp-desk brainstorm \"your task description\"");
console.log("");
