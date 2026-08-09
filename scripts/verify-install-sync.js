#!/usr/bin/env node
"use strict";

// Install-sync oracle — proves ~/.claude/ralph-desk matches this source tree.
//
// WHY THIS EXISTS (2026-08-10): the previous oracle was a hand-copied bash
// recipe that stripped the install banner with `grep -v` and diffed the
// remainder. Two defects:
//
//   1. `grep` classifies any file containing a NUL byte as binary and emits
//      nothing. src/node/util/gate-receipt.mjs carried two raw NUL bytes, so
//      its "stripped" body was the EMPTY STRING — a permanent false FAIL.
//      Worse failure direction: the natural way to silence that noise is to
//      loosen the check, which then masks real drift.
//   2. `diff -rq A B | grep -v 'DO NOT EDIT'` never filtered anything, because
//      `diff -rq` prints "Files A and B differ" — a line that does not contain
//      the banner text. Every banner-headed file therefore counted as drift,
//      making the recursive check unconditionally red.
//
// The fix is to stop parsing installed files at all. The installer is a pure
// function (source bytes + banner rule) -> installed bytes, so the verifier
// reconstructs the expected bytes with the SAME manifest and compares with
// Buffer.compare. No text decoding, no line splitting, no regex: NUL bytes,
// invalid UTF-8 and CRLF are all handled by construction, and the banner's
// own content is verified as a side effect.
//
// Usage:
//   node scripts/verify-install-sync.js [--home DIR] [--pkg DIR]
//                                       [--strict-chmod] [--quiet]
//
// Exit 0 = installed tree matches source. Exit 1 = drift (details on stdout).
// chmod deviations are warnings by default (some filesystems silently ignore
// chmod, per scripts/postinstall.js tryLockFile) and failures under
// --strict-chmod, which is what the release runbook's P4 step requires.

const fs = require("fs");
const os = require("os");
const path = require("path");

const manifest = require(path.join(__dirname, "install-manifest.js"));

const BANNER_MARKER = "DO NOT EDIT — generated from";
const EXPECTED_MODE = 0o444;

// Exact inverse of postinstall.js injectBannerAndLock: given the source bytes
// and the source's relative path, return the bytes the installer must have
// written. Mirrors the shebang-preservation and idempotency branches verbatim.
function expectedInstalledBytes(sourceBytes, sourceRelativePath) {
  const ext = path.extname(sourceRelativePath).toLowerCase();
  const banner = manifest.bannerFor(ext, sourceRelativePath);
  if (!banner) {
    return sourceBytes; // .json and unknown types: no banner, chmod only
  }
  // Idempotency guard mirror: the installer skips injection when the copied
  // source already carries a banner in its first 200 bytes.
  if (sourceBytes.subarray(0, 200).toString("utf8").includes(BANNER_MARKER)) {
    return sourceBytes;
  }
  const bannerBytes = Buffer.from(banner);
  const hasShebang =
    sourceBytes.length >= 2 && sourceBytes[0] === 0x23 && sourceBytes[1] === 0x21;
  if (!hasShebang) {
    return Buffer.concat([bannerBytes, sourceBytes]);
  }
  const newlineIdx = sourceBytes.indexOf(0x0a);
  if (newlineIdx < 0) {
    return Buffer.concat([sourceBytes, Buffer.from("\n" + banner)]);
  }
  return Buffer.concat([
    sourceBytes.subarray(0, newlineIdx + 1),
    bannerBytes,
    sourceBytes.subarray(newlineIdx + 1),
  ]);
}

// Verify one source -> target pair. Returns { failures: [], warnings: [] }.
function verifyOne(sourceAbsolutePath, sourceRelativePath, targetPath, options) {
  const failures = [];
  const warnings = [];
  const label = `${sourceRelativePath} -> ${targetPath}`;

  if (!fs.existsSync(targetPath)) {
    failures.push(`MISSING   ${label}`);
    return { failures, warnings };
  }
  const stat = fs.lstatSync(targetPath);
  if (stat.isSymbolicLink()) {
    failures.push(`SYMLINK   ${label} (installed entry must be a regular file)`);
    return { failures, warnings };
  }

  const sourceBytes = fs.readFileSync(sourceAbsolutePath);
  const installedBytes = fs.readFileSync(targetPath);
  const expected = expectedInstalledBytes(sourceBytes, sourceRelativePath);

  if (Buffer.compare(installedBytes, expected) !== 0) {
    failures.push(
      `DRIFT     ${label} (installed ${installedBytes.length}B, expected ${expected.length}B)`,
    );
  }

  const mode = stat.mode & 0o777;
  if (mode !== EXPECTED_MODE) {
    const message = `CHMOD     ${targetPath} mode=${mode.toString(8)} (expected 444)`;
    if (options.strictChmod) {
      failures.push(message);
    } else {
      warnings.push(`${message} — filesystem may not honor chmod`);
    }
  }
  return { failures, warnings };
}

function listFilesRecursive(dir, filter) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      for (const child of listFilesRecursive(abs, filter)) {
        out.push(path.join(entry.name, child));
      }
      continue;
    }
    if (entry.isFile() && (!filter || filter(entry.name))) {
      out.push(entry.name);
    }
  }
  return out;
}

// Recursive tree check with orphan detection in BOTH directions. An installed
// file with no source counterpart is drift too — it is usually a leftover from
// a previous version whose source file was deleted.
function verifyTree(sourceDir, sourceRelativeDir, targetDir, filter, options) {
  const failures = [];
  const warnings = [];
  const sourceFiles = listFilesRecursive(sourceDir, filter).sort();

  for (const rel of sourceFiles) {
    const result = verifyOne(
      path.join(sourceDir, rel),
      path.join(sourceRelativeDir, rel),
      path.join(targetDir, rel),
      options,
    );
    failures.push(...result.failures);
    warnings.push(...result.warnings);
  }

  const sourceSet = new Set(sourceFiles);
  for (const rel of listFilesRecursive(targetDir, filter).sort()) {
    if (!sourceSet.has(rel)) {
      failures.push(`ORPHAN    ${path.join(targetDir, rel)} (no source counterpart)`);
    }
  }
  return { failures, warnings, checked: sourceFiles.length };
}

function runVerification(options) {
  const { home, pkgDir } = options;
  const failures = [];
  const warnings = [];
  let checked = 0;

  for (const [sourceRelativePath, targetPath] of manifest.runtimeSources(home)) {
    const sourceAbsolutePath = path.join(pkgDir, sourceRelativePath);
    if (!fs.existsSync(sourceAbsolutePath)) {
      failures.push(`NO SOURCE ${sourceRelativePath} (manifest lists a file that does not exist)`);
      continue;
    }
    const result = verifyOne(sourceAbsolutePath, sourceRelativePath, targetPath, options);
    failures.push(...result.failures);
    warnings.push(...result.warnings);
    checked += 1;
  }

  const isMarkdown = (name) => name.endsWith(".md");
  for (const [sourceRelativeDir, targetDir] of manifest.markdownDirectories(home)) {
    const sourceDir = path.join(pkgDir, sourceRelativeDir);
    if (!fs.existsSync(sourceDir)) continue; // installer skips missing dirs too
    const result = verifyTree(sourceDir, sourceRelativeDir, targetDir, isMarkdown, options);
    failures.push(...result.failures);
    warnings.push(...result.warnings);
    checked += result.checked;
  }

  const nodeResult = verifyTree(
    path.join(pkgDir, manifest.NODE_SOURCE_RELATIVE_DIR),
    manifest.NODE_SOURCE_RELATIVE_DIR,
    manifest.installLayout(home).nodeDir,
    null,
    options,
  );
  failures.push(...nodeResult.failures);
  warnings.push(...nodeResult.warnings);
  checked += nodeResult.checked;

  return { failures, warnings, checked };
}

function parseArgs(argv) {
  const options = {
    home: os.homedir(),
    pkgDir: path.join(__dirname, ".."),
    strictChmod: false,
    quiet: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--home") {
      options.home = argv[i + 1];
      i += 1;
    } else if (arg === "--pkg") {
      options.pkgDir = argv[i + 1];
      i += 1;
    } else if (arg === "--strict-chmod") {
      options.strictChmod = true;
    } else if (arg === "--quiet") {
      options.quiet = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!options.home) throw new Error("--home requires a directory");
  if (!options.pkgDir) throw new Error("--pkg requires a directory");
  return options;
}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (err) {
    console.error(`verify-install-sync: ${err.message}`);
    return 2;
  }
  const { failures, warnings, checked } = runVerification(options);

  if (!options.quiet) {
    for (const warning of warnings) console.log(`  WARN  ${warning}`);
    for (const failure of failures) console.log(`  FAIL  ${failure}`);
  }
  if (failures.length > 0) {
    console.log(
      `install-sync: FAIL — ${failures.length} problem(s) across ${checked} file(s) checked`,
    );
    return 1;
  }
  console.log(
    `install-sync: OK — ${checked} file(s) byte-identical to source` +
      (warnings.length > 0 ? ` (${warnings.length} warning(s))` : ""),
  );
  return 0;
}

module.exports = {
  expectedInstalledBytes,
  verifyOne,
  verifyTree,
  runVerification,
  parseArgs,
  main,
};

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}
