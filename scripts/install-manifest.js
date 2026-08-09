#!/usr/bin/env node
"use strict";

// Shared install manifest: the single source of truth for WHAT gets installed
// and WHAT banner each installed file carries.
//
// Both sides of the install contract consume this module:
//   - scripts/postinstall.js        writes the files
//   - scripts/verify-install-sync.js reads them back and proves byte equality
//
// Keeping one list means the verifier can never drift out of sync with the
// installer (a verifier holding its own copy of the file list is the exact
// class of bug it exists to catch).

const path = require("path");

// v5.7 §4.10: per-extension banner format. `# DO NOT EDIT` text leaks into
// rendered Markdown, so .md uses HTML comment; .mjs/.js uses //; shell uses #.
function bannerFor(extension, sourceRelativePath) {
  const msg = `DO NOT EDIT — generated from ${sourceRelativePath}. Edit source and re-sync. See ~/.claude/ralph-desk/UNLOCK.md for debug unlock.`;
  switch (extension) {
    case ".md":
      return `<!-- ${msg} -->\n`;
    case ".mjs":
    case ".js":
      return `// ${msg}\n`;
    case ".zsh":
    case ".sh":
      return `# ${msg}\n`;
    default:
      return null; // .json and unknown types: rely on chmod alone
  }
}

function installLayout(home) {
  const claudeDir = path.join(home, ".claude");
  const deskDir = path.join(claudeDir, "ralph-desk");
  return {
    claudeDir,
    deskDir,
    commandsDir: path.join(claudeDir, "commands"),
    docsDir: path.join(deskDir, "docs"),
    nodeDir: path.join(deskDir, "node"),
  };
}

// [sourceRelativePath, absoluteTargetPath] pairs for single-file copies.
function runtimeSources(home) {
  const { commandsDir, deskDir, docsDir } = installLayout(home);
  return [
    ["src/commands/rlp-desk.md", path.join(commandsDir, "rlp-desk.md")],
    ["src/governance.md", path.join(deskDir, "governance.md")],
    ["src/model-upgrade-table.md", path.join(deskDir, "model-upgrade-table.md")],
    ["README.md", path.join(deskDir, "README.md")],
    ["install.sh", path.join(deskDir, "install.sh")],
    // v0.14.0: zsh runner is the canonical --mode tmux backend again.
    // src/node/run.mjs spawns it as a subprocess for tmux mode invocations.
    // injectBannerAndLock preserves the shebang and adds a `# DO NOT EDIT`
    // line on line 2 so the verification scripts in CLAUDE.md still
    // recognize the file as installed.
    ["src/scripts/init_ralph_desk.zsh", path.join(deskDir, "init_ralph_desk.zsh")],
    ["src/scripts/run_ralph_desk.zsh", path.join(deskDir, "run_ralph_desk.zsh")],
    ["src/scripts/lib_ralph_desk.zsh", path.join(deskDir, "lib_ralph_desk.zsh")],
    // v5.7 §4.15: all rlp-desk docs (user-facing + dev meta) under docs/rlp-desk/.
    ["docs/rlp-desk/architecture.md", path.join(docsDir, "rlp-desk", "architecture.md")],
    ["docs/rlp-desk/getting-started.md", path.join(docsDir, "rlp-desk", "getting-started.md")],
    ["docs/rlp-desk/protocol-reference.md", path.join(docsDir, "rlp-desk", "protocol-reference.md")],
    ["docs/rlp-desk/TODO-verification-next.md", path.join(docsDir, "rlp-desk", "TODO-verification-next.md")],
    ["docs/rlp-desk/multi-mission-orchestration.md", path.join(docsDir, "rlp-desk", "multi-mission-orchestration.md")],
    // Plan v6 PR-0a: signal protocol documentation (Architect/Critic codex iter 6).
    ["docs/rlp-desk/signal-protocol.md", path.join(docsDir, "rlp-desk", "signal-protocol.md")],
    // 2026-08-09 owner standing rule: SV/dogfood verification ledger (append-only).
    ["docs/rlp-desk/verification-history.md", path.join(docsDir, "rlp-desk", "verification-history.md")],
  ];
}

// Markdown-only recursive copies: [sourceRelativeDir, absoluteTargetDir] pairs.
function markdownDirectories(home) {
  const { docsDir } = installLayout(home);
  return [
    ["docs/rlp-desk/internal", path.join(docsDir, "rlp-desk", "internal")],
    ["docs/rlp-desk/blueprints", path.join(docsDir, "rlp-desk", "blueprints")],
    ["docs/rlp-desk/plans", path.join(docsDir, "rlp-desk", "plans")],
  ];
}

// Full recursive copy (every file, not just .md).
const NODE_SOURCE_RELATIVE_DIR = path.join("src", "node");

module.exports = {
  bannerFor,
  installLayout,
  runtimeSources,
  markdownDirectories,
  NODE_SOURCE_RELATIVE_DIR,
};
