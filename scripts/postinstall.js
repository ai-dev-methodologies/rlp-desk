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
  // v5.7 §4.15: all rlp-desk docs (user-facing + dev meta) under docs/rlp-desk/.
  ["docs/rlp-desk/architecture.md", path.join(docsDir, "rlp-desk", "architecture.md")],
  ["docs/rlp-desk/getting-started.md", path.join(docsDir, "rlp-desk", "getting-started.md")],
  ["docs/rlp-desk/protocol-reference.md", path.join(docsDir, "rlp-desk", "protocol-reference.md")],
  ["docs/rlp-desk/TODO-verification-next.md", path.join(docsDir, "rlp-desk", "TODO-verification-next.md")],
  ["docs/rlp-desk/multi-mission-orchestration.md", path.join(docsDir, "rlp-desk", "multi-mission-orchestration.md")],
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

function unlockTree(targetPath) {
  // v5.7 §4.10: walk and chmod u+w every entry so rmSync(recursive) does not
  // ENOTEMPTY on a directory full of 0o444 children. Idempotent on missing paths.
  // Security review v5.7 follow-up: lstatSync first; SKIP symlinks entirely so
  // a hostile symlink (e.g., ~/.claude/ralph-desk/foo -> /etc/passwd) cannot
  // be chmod'd via unlockTree's chmodSync (which follows symlinks).
  if (!fs.existsSync(targetPath)) return;
  const stat = fs.lstatSync(targetPath);
  if (stat.isSymbolicLink()) {
    // Don't chmod the symlink target. lchmod is unsupported on Linux; safest
    // action is to leave symlinks alone — they're not part of our install set.
    return;
  }
  try { fs.chmodSync(targetPath, stat.isDirectory() ? 0o755 : 0o644); } catch {}
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(targetPath, { withFileTypes: true })) {
      unlockTree(path.join(targetPath, entry.name));
    }
  }
}

function removePath(targetPath) {
  // v5.7 §4.10: existing target tree may contain 0o444 files. Walk and unlock
  // before rmSync so EACCES/ENOTEMPTY don't break the upgrade path.
  unlockTree(targetPath);
  fs.rmSync(targetPath, { recursive: true, force: true });
}

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

let _chmodWarningEmitted = false;
function tryLockFile(targetPath) {
  // Best-effort write-protect. Some filesystems (WSL1/NTFS, tmpfs noexec, certain
  // bind mounts) silently no-op chmod. R-V5-5: emit ONE warning per install run.
  try {
    fs.chmodSync(targetPath, 0o444);
    const stat = fs.statSync(targetPath);
    if ((stat.mode & 0o222) !== 0 && !_chmodWarningEmitted) {
      console.log("  [install] WARNING: filesystem does not honor chmod a-w; cross-session edit protection unavailable.");
      _chmodWarningEmitted = true;
    }
  } catch (err) {
    if (!_chmodWarningEmitted) {
      console.log("  [install] WARNING: chmod a-w failed (" + err.code + "); cross-session edit protection unavailable.");
      _chmodWarningEmitted = true;
    }
  }
}

function injectBannerAndLock(targetPath, sourceRelativePath) {
  const ext = path.extname(targetPath).toLowerCase();
  const banner = bannerFor(ext, sourceRelativePath);
  if (banner) {
    const original = fs.readFileSync(targetPath);
    // Idempotency guard (code-review v5.7 follow-up): the source file in the
    // package tarball already contains an injected banner from a prior install
    // ONLY if a developer ran sync from an installed copy back to the source —
    // which is forbidden by CLAUDE.md. But re-running install over an existing
    // installed file (e.g., npm i again) does NOT need re-injection because
    // copyFileSync replaced the file with the source contents. The check below
    // is defensive — only inject when the file does not already start with a
    // DO NOT EDIT marker.
    const head = original.subarray(0, 200).toString('utf8');
    if (head.includes('DO NOT EDIT — generated from')) {
      // Already banner-headed (rare: source somehow shipped with banner). Skip
      // injection but still apply chmod for consistency.
      tryLockFile(targetPath);
      return;
    }
    // Shebang preservation: if first line starts with `#!`, banner goes on line 2.
    if (original.length >= 2 && original[0] === 0x23 && original[1] === 0x21) {
      const newlineIdx = original.indexOf(0x0a);
      if (newlineIdx >= 0) {
        const headBuf = original.subarray(0, newlineIdx + 1);
        const tailBuf = original.subarray(newlineIdx + 1);
        fs.writeFileSync(targetPath, Buffer.concat([headBuf, Buffer.from(banner), tailBuf]));
      } else {
        fs.writeFileSync(targetPath, Buffer.concat([original, Buffer.from("\n" + banner)]));
      }
    } else {
      fs.writeFileSync(targetPath, Buffer.concat([Buffer.from(banner), original]));
    }
  }
  tryLockFile(targetPath);
}

function copyFile(sourceRelativePath, targetPath) {
  ensureDir(path.dirname(targetPath));
  // v5.7 §4.10: unlock target if it exists and is write-protected from a prior
  // install (R-V5-1: copyFileSync over 0o444 fails EACCES on upgrade).
  if (fs.existsSync(targetPath)) {
    try { fs.chmodSync(targetPath, 0o644); } catch { /* may be already writable */ }
  }
  fs.copyFileSync(path.join(pkgDir, sourceRelativePath), targetPath);
  injectBannerAndLock(targetPath, sourceRelativePath);
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
      // v5.7 §4.10: unlock prior-install write-protected target before copy.
      if (fs.existsSync(targetPath)) {
        try { fs.chmodSync(targetPath, 0o644); } catch {}
      }
      fs.copyFileSync(sourcePath, targetPath);
      injectBannerAndLock(targetPath, path.join(sourceRelativeDir, entry.name));
      console.log("  + " + targetPath);
    }
  }
}

function copyNodeRuntime(sourceDir, targetDir, sourceRelativeBase) {
  // removePath already handles 0o444 unlock per v5.7 §4.10.
  removePath(targetDir);
  ensureDir(targetDir);
  const baseRel = sourceRelativeBase || "src/node";

  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    const childRel = path.join(baseRel, entry.name);
    if (entry.isDirectory()) {
      copyNodeRuntime(sourcePath, targetPath, childRel);
      continue;
    }
    if (entry.isFile()) {
      ensureDir(path.dirname(targetPath));
      fs.copyFileSync(sourcePath, targetPath);
      injectBannerAndLock(targetPath, childRel);
      console.log("  + " + targetPath);
    }
  }
}

// v5.7 §4.10: Documented escape hatch for debug sessions.
function writeUnlockDoc() {
  const unlockPath = path.join(deskDir, "UNLOCK.md");
  const content = `# UNLOCK — Debug edit escape hatch

Files in \`~/.claude/ralph-desk/\` and \`~/.claude/commands/rlp-desk.md\` are
installed read-only (\`chmod a-w\`) so cross-session AI agents cannot silently
corrupt them. Source of truth: the rlp-desk source repository.

If you need to edit an installed file for **temporary debug** (e.g., add a
\`set -x\` line, insert a \`print\` statement):

\`\`\`bash
chmod -R u+w ~/.claude/ralph-desk
chmod u+w ~/.claude/commands/rlp-desk.md
# ... edit, test, then revert ...
\`\`\`

To re-apply protection without a full reinstall, run npm install rlp-desk
from the source repo or rerun \`scripts/postinstall.js\`.

**For permanent fixes**, edit the source repo and re-publish — never edit
installed files directly. The banner at the top of every installed file
points back to its source path.
`;
  if (fs.existsSync(unlockPath)) {
    try { fs.chmodSync(unlockPath, 0o644); } catch {}
  }
  fs.writeFileSync(unlockPath, content);
  console.log("  + " + unlockPath);
  // UNLOCK.md is itself NOT locked — users may want to add their own notes.
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

// v5.7 §4.15: dev meta docs live under docs/rlp-desk/ to avoid mixing with
// user-facing operational docs (per user feedback).
copyMarkdownDirectory("docs/rlp-desk/internal", path.join(docsDir, "rlp-desk", "internal"));
copyMarkdownDirectory("docs/rlp-desk/blueprints", path.join(docsDir, "rlp-desk", "blueprints"));
copyMarkdownDirectory("docs/rlp-desk/plans", path.join(docsDir, "rlp-desk", "plans"));
copyNodeRuntime(path.join(pkgDir, "src", "node"), nodeDir);

// v5.7 §4.10: write the UNLOCK.md escape-hatch doc for debug sessions.
writeUnlockDoc();

console.log("");
console.log("  Done! Open Claude Code and run:");
console.log("    /rlp-desk brainstorm \"your task description\"");
console.log("");
