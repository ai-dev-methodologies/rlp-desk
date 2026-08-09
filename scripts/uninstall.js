#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");

// The install set lives in install-manifest.js — the same module postinstall.js
// writes from and verify-install-sync.js verifies against. Deriving the removal
// set from it means a new install entry can never be forgotten here (a private
// copy of the list is the exact class of bug the manifest exists to prevent).
const manifest = require(path.join(__dirname, "install-manifest.js"));

// Everything this uninstaller deletes, for a given HOME.
// Read the manifest at call time (not at module load) so the relationship —
// not a snapshot — is what tests can pin down.
function removalTargets(home) {
  const { deskDir, docsDir, nodeDir } = manifest.installLayout(home);
  return {
    files: [
      ...manifest.runtimeSources(home).map(([, targetPath]) => targetPath),
      // UNLOCK.md is deliberately NOT a manifest entry: postinstall generates it
      // from an inline template (writeUnlockDoc) rather than copying a source
      // file, so it has no source/target pair to derive. It still has to be
      // removed here — otherwise the empty-directory check below always sees one
      // leftover file and ralph-desk/ is never removed (PKG-6).
      path.join(deskDir, "UNLOCK.md"),
    ],
    directories: [docsDir, nodeDir],
    deskDir,
  };
}

function uninstall(home) {
  const { files, directories, deskDir } = removalTargets(home);

  for (const targetPath of files) {
    try {
      // Installed files are write-locked (chmod 0o444) per postinstall v5.7
      // §4.10. Restore write permission before unlink so removal is robust
      // across filesystems (mirrors postinstall's unlock-before-remove).
      try {
        fs.chmodSync(targetPath, 0o644);
      } catch (_) {
        // File may be missing or already writable.
      }
      fs.rmSync(targetPath, { recursive: true, force: true });
      console.log("  - " + targetPath);
    } catch (_) {
      // Ignore missing files.
    }
  }

  for (const targetPath of directories) {
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
}

if (require.main === module) {
  console.log("");
  console.log("  Uninstalling RLP Desk...");
  console.log("");

  uninstall(os.homedir());

  console.log("");
  console.log("  RLP Desk uninstalled.");
  console.log("");
}

module.exports = { removalTargets, uninstall };
