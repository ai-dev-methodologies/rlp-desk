// install.sh curl-channel drift guard.
//
// TEXT-ONLY parity check between install.sh's `fetch` targets and the shared
// scripts/install-manifest.js runtimeSources() list — in both directions.
// This file performs no network access and never executes install.sh; the
// only child_process use here is a plain `bash -n` syntax check (never a
// real run). Campaign sv-oracle-nv, US-001.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const selfPath = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(selfPath), '..', '..');
const manifest = require(path.join(repoRoot, 'scripts', 'install-manifest.js'));

const installShPath = path.join(repoRoot, 'install.sh');
const installShContent = fs.readFileSync(installShPath, 'utf8');

// A stable, harmless placeholder HOME — install-manifest.js only builds path
// strings from it (path.join), it never touches the filesystem.
const FAKE_HOME = path.join(os.tmpdir(), 'rlp-desk-parity-guard-fake-home');

const manifestSourcePaths = manifest.runtimeSources(FAKE_HOME).map(([src]) => src);
const dirPrefixes = manifest.markdownDirectories(FAKE_HOME).map(([src]) => src);
const nodeSourceDir = manifest.NODE_SOURCE_RELATIVE_DIR.split(path.sep).join('/');

// ---------------------------------------------------------------------------
// Guard implementation (self-contained; text-only, no network, no exec).
// ---------------------------------------------------------------------------

// A line is an actual `fetch` invocation only if, after leading whitespace,
// it literally starts with the word `fetch` followed by whitespace — this
// excludes the `fetch() {` definition line and any comment/prose that merely
// mentions the word.
const FETCH_LINE_RE = /^\s*fetch\s+(.*)$/;
// A well-formed fetch call: exactly two double-quoted args, first one a
// literal `$REPO_URL/<path>` download source.
const FETCH_ARGS_RE = /^"\$REPO_URL\/([^"]+)"\s+"([^"]+)"\s*$/;
// The one sanctioned bare-curl download outside the fetch() helper (used for
// node/MANIFEST.txt, which is generated at release time and has no `src/`
// counterpart — see CURL_ONLY_ALLOWLIST below). Flags are NOT constrained to
// the current `-fsSL` order/set — a hypothetical `curl -sSL "..."` line must
// still be classified, never silently skipped (AC3).
const CURL_REPO_LINE_RE = /^\s*curl\s+.*"\$REPO_URL\/([^"]+)"/;
// Any curl invocation that references $REPO_URL at all, used as a fallback
// net: if a curl+$REPO_URL line doesn't match the parseable quoted-path shape
// above, it must land in `unparsable` rather than being silently skipped.
const CURL_ANY_REPO_URL_RE = /^\s*curl\s+.*\$REPO_URL/;
const DYNAMIC_MARKER = '$relpath';

// Explicit, commented curl-only allowlist (PRD boundary case): artifacts
// install.sh downloads with a bare `curl` (not the manifest-covered
// `fetch()` helper) that have no `src/` source counterpart in
// scripts/install-manifest.js. node/MANIFEST.txt is the generated file-list
// index the dynamic `src/node/$relpath` loop below consumes at install time;
// it is produced at release time, not authored under src/, so it can never
// appear in runtimeSources() and must be named here explicitly.
const CURL_ONLY_ALLOWLIST = new Set(['src/node/MANIFEST.txt']);

function parseDownloads(content) {
  const lines = content.split('\n');
  const entries = [];
  const unparsable = [];

  lines.forEach((raw, idx) => {
    const lineNumber = idx + 1;
    const fetchMatch = FETCH_LINE_RE.exec(raw);
    if (fetchMatch) {
      const argsMatch = FETCH_ARGS_RE.exec(fetchMatch[1]);
      if (!argsMatch) {
        // A line that starts with `fetch ` but doesn't match the strict
        // two-quoted-arg $REPO_URL shape must FAIL loudly (AC3) — it is
        // never silently skipped.
        unparsable.push({ lineNumber, raw });
        return;
      }
      const downloadPath = argsMatch[1];
      entries.push({
        path: downloadPath,
        dynamic: downloadPath.includes(DYNAMIC_MARKER),
        lineNumber,
        raw,
        curl: false,
      });
      return;
    }
    const curlMatch = CURL_REPO_LINE_RE.exec(raw);
    if (curlMatch) {
      entries.push({ path: curlMatch[1], dynamic: false, lineNumber, raw, curl: true });
      return;
    }
    if (CURL_ANY_REPO_URL_RE.test(raw)) {
      // A curl line that targets $REPO_URL but doesn't match the strict,
      // parseable quoted-path shape must FAIL loudly (AC3) — never silently
      // skipped, mirroring the fetch-line unparsable branch above.
      unparsable.push({ lineNumber, raw });
    }
  });

  return { entries, unparsable };
}

function forwardCoverage(sourcePaths, entries) {
  const literalPaths = new Set(entries.filter((e) => !e.dynamic).map((e) => e.path));
  const missing = sourcePaths.filter((p) => !literalPaths.has(p));
  return { missing };
}

function isDirectoryCovered(downloadPath, prefixes, repoRootForExistence) {
  const matchesPrefix = prefixes.some((prefix) => downloadPath === prefix || downloadPath.startsWith(`${prefix}/`));
  if (!matchesPrefix) return false;
  // A fetch path that merely matches a covered directory prefix textually is
  // not proof the file exists — this is exactly the class of bug that broke
  // the curl channel for docs/rlp-desk/internal/* (gitignored/absent files
  // 404'd, `curl -f` aborted the whole install, yet the prefix-only check
  // certified it as "covered"). Require the source file to actually exist.
  return fs.existsSync(path.join(repoRootForExistence, downloadPath));
}

function reverseCoverage(entries, sourcePaths, prefixes, allowlist, repoRootForExistence) {
  const manifestSet = new Set(sourcePaths);
  const unexplained = [];
  for (const entry of entries) {
    if (entry.dynamic) continue; // covered by the dynamic-line check, not a literal path
    if (manifestSet.has(entry.path)) continue;
    if (isDirectoryCovered(entry.path, prefixes, repoRootForExistence)) continue;
    if (allowlist.has(entry.path)) continue;
    unexplained.push(entry);
  }
  return { unexplained };
}

function checkInstallShSyntax(shPath) {
  return execFileSync('bash', ['-n', shPath], { encoding: 'utf8' });
}

function fullGuardIsClean(content, sourcePaths, prefixes, allowlist, repoRootForExistence) {
  const { entries, unparsable } = parseDownloads(content);
  const { missing } = forwardCoverage(sourcePaths, entries);
  const { unexplained } = reverseCoverage(entries, sourcePaths, prefixes, allowlist, repoRootForExistence);
  return { missing, unexplained, unparsable };
}

const SELF_SOURCE = fs.readFileSync(selfPath, 'utf8');
const PKG = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));

const { entries: realEntries, unparsable: realUnparsable } = parseDownloads(installShContent);

// ---------------------------------------------------------------------------
// AC1 — forward coverage: every manifest single-file source is fetched.
// ---------------------------------------------------------------------------

test('AC1 happy: every manifest single-file source is fetched by install.sh', () => {
  const { missing } = forwardCoverage(manifestSourcePaths, realEntries);
  assert.deepEqual(missing, [], `install.sh is missing fetch lines for: ${missing.join(', ')}`);
  assert.ok(manifestSourcePaths.length >= 10, 'sanity: the manifest should list a nontrivial number of sources');
});

test('AC1 negative (mutation, L2 required evidence): an injected synthetic manifest source is reported missing', () => {
  const fakePath = 'src/does-not-exist-injected-by-test.md';
  const injected = manifestSourcePaths.concat([fakePath]);
  const { missing } = forwardCoverage(injected, realEntries);
  assert.deepEqual(missing, [fakePath], 'the guard must name the synthetic missing source — proves it is not vacuous');
});

test('AC1 boundary: forward coverage matches on the source path, independent of a differing destination basename', () => {
  const syntheticSources = ['src/foo/bar.md'];
  const syntheticContent = 'fetch "$REPO_URL/src/foo/bar.md" "$TARGET_DIR/renamed-totally-different.md"\n';
  const { entries } = parseDownloads(syntheticContent);
  const { missing } = forwardCoverage(syntheticSources, entries);
  assert.deepEqual(missing, [], 'a differing destination basename must not cause a false missing report');
  assert.equal(entries[0].path, 'src/foo/bar.md');
});

// ---------------------------------------------------------------------------
// AC2 — reverse coverage: every install.sh download path is explained.
// ---------------------------------------------------------------------------

test('AC2 happy: every install.sh fetch/curl path is explained by the manifest, a markdown directory, or the allowlist', () => {
  const { unexplained } = reverseCoverage(realEntries, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
  assert.deepEqual(unexplained.map((e) => e.path), [], `unexplained install.sh downloads: ${unexplained.map((e) => e.path).join(', ')}`);
});

test('AC2 negative: an unexplained extra fetch path in install.sh is reported by name', () => {
  const syntheticContent = `${installShContent}\nfetch "$REPO_URL/src/totally-unlisted-rogue-file.md" "$DESK_DIR/rogue.md"\n`;
  const { entries } = parseDownloads(syntheticContent);
  const { unexplained } = reverseCoverage(entries, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
  assert.equal(unexplained.length, 1);
  assert.equal(unexplained[0].path, 'src/totally-unlisted-rogue-file.md');
});

// NOTE: this test previously asserted against docs/rlp-desk/internal/ — that
// directory's fetch lines were deleted from install.sh (2026-08-10, the
// gitignored/absent-path curl-channel break this file guards against), so the
// directory-prefix sanity check below now uses docs/rlp-desk/blueprints/,
// which install.sh still fetches for real.
test('AC2 boundary: MANIFEST.txt is covered ONLY via the explicit allowlist; docs directories via prefix', () => {
  const manifestTxtEntry = realEntries.find((e) => e.path === 'src/node/MANIFEST.txt');
  assert.ok(manifestTxtEntry, 'install.sh must still curl node/MANIFEST.txt');
  assert.ok(manifestTxtEntry.curl, 'MANIFEST.txt is fetched via bare curl, not the fetch() helper');

  const { unexplained: withoutAllowlist } = reverseCoverage(realEntries, manifestSourcePaths, dirPrefixes, new Set(), repoRoot);
  assert.ok(
    withoutAllowlist.some((e) => e.path === 'src/node/MANIFEST.txt'),
    'removing the allowlist must surface MANIFEST.txt as unexplained — proves the allowlist is actually consulted'
  );

  const blueprintFileEntry = realEntries.find((e) => e.path.startsWith('docs/rlp-desk/blueprints/'));
  assert.ok(blueprintFileEntry, 'sanity: install.sh fetches at least one docs/rlp-desk/blueprints file');
  const { unexplained: withDirs } = reverseCoverage(realEntries, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
  assert.ok(
    !withDirs.some((e) => e.path === blueprintFileEntry.path),
    'markdown-directory files must be covered by directory prefix (and must actually exist), not individually flagged'
  );
});

test('AC2 negative (existence): a fetch line under a covered directory pointing to a nonexistent file is reported — regression guard for the 2026-08-10 docs/rlp-desk/internal/* curl-channel break', () => {
  const fakePath = 'docs/rlp-desk/internal/nonexistent-injected-by-test.md';
  assert.equal(
    fs.existsSync(path.join(repoRoot, fakePath)),
    false,
    'sanity: the synthetic path must not exist in the repo (docs/rlp-desk/internal is gitignored/absent)'
  );
  const syntheticContent = `fetch "$REPO_URL/${fakePath}" "$DESK_DIR/nonexistent-injected-by-test.md"\n`;
  const { entries } = parseDownloads(syntheticContent);
  const { unexplained } = reverseCoverage(entries, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
  assert.equal(unexplained.length, 1);
  assert.equal(
    unexplained[0].path,
    fakePath,
    'a fetch of a nonexistent file under a covered directory must be named, never silently certified as covered by the directory-prefix escape hatch alone'
  );
});

// ---------------------------------------------------------------------------
// AC3 — parser integrity: unparsable fetch lines must FAIL, never be skipped.
// ---------------------------------------------------------------------------

test('AC3 happy: every real fetch line in install.sh parses cleanly', () => {
  assert.deepEqual(realUnparsable, [], `unparsable fetch lines: ${JSON.stringify(realUnparsable)}`);
  assert.ok(realEntries.length >= 10);
});

test('AC3 negative: a structurally malformed fetch line fails loudly and names the exact line', () => {
  const badLine = 'fetch "$REPO_URL/broken-missing-second-arg.md"';
  const syntheticContent = `${badLine}\nfetch "$REPO_URL/ok.md" "$TARGET"\n`;
  const { entries, unparsable } = parseDownloads(syntheticContent);
  assert.equal(unparsable.length, 1);
  assert.equal(unparsable[0].lineNumber, 1);
  assert.equal(unparsable[0].raw, badLine);
  assert.equal(entries.length, 1, 'the well-formed line after the broken one must still parse');
  assert.equal(entries[0].path, 'ok.md');
});

test('AC3 boundary: the dynamic $relpath fetch line is a legitimate call, classified not rejected', () => {
  const dynamicEntry = realEntries.find((e) => e.dynamic);
  assert.ok(dynamicEntry, 'install.sh must contain the manifest-driven dynamic fetch line');
  assert.equal(dynamicEntry.path, `${nodeSourceDir}/${DYNAMIC_MARKER}`);
  assert.equal(
    realUnparsable.some((u) => u.raw.includes(DYNAMIC_MARKER)),
    false,
    'the dynamic line must never be misclassified as unparsable'
  );
});

test('AC3 boundary: a comment merely mentioning "fetch" is never mistaken for an invocation', () => {
  const syntheticContent = '# call fetch for the docs section below\nfetch "$REPO_URL/x.md" "$TARGET"\n';
  const { entries, unparsable } = parseDownloads(syntheticContent);
  assert.equal(unparsable.length, 0);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].path, 'x.md');
});

test('AC3 negative (curl flag generalization): a curl -sSL variant against $REPO_URL is classified, never silently skipped', () => {
  const syntheticContent = 'curl -sSL "$REPO_URL/src/some-file.md" -o "$TARGET"\n';
  const { entries, unparsable } = parseDownloads(syntheticContent);
  assert.equal(unparsable.length, 0);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].path, 'src/some-file.md');
  assert.equal(entries[0].curl, true);
});

test('AC3 negative (curl generalization, unparsable fallback): a curl line against $REPO_URL that does not match the parseable quoted-path shape is reported unparsable, not silently skipped', () => {
  const badLine = 'curl -fsSL $REPO_URL/no-quotes.md -o "$TARGET"';
  const syntheticContent = `${badLine}\n`;
  const { entries, unparsable } = parseDownloads(syntheticContent);
  assert.equal(entries.length, 0, 'the malformed curl+$REPO_URL line must not be silently classified as a valid entry');
  assert.equal(unparsable.length, 1);
  assert.equal(unparsable[0].raw, badLine, 'the guard must name the exact unparsable curl line');
});

// ---------------------------------------------------------------------------
// AC4 — no side effects: text-only, no network, install.sh is never executed.
// ---------------------------------------------------------------------------

test('AC4 happy: the guard performs no network access while computing coverage', () => {
  const originalFetch = globalThis.fetch;
  let called = false;
  globalThis.fetch = () => {
    called = true;
    throw new Error('network access attempted by the guard');
  };
  try {
    reverseCoverage(realEntries, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
    forwardCoverage(manifestSourcePaths, realEntries);
    parseDownloads(installShContent);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(called, false, 'the guard must never call global fetch()');
});

test('AC4 negative: this guard file imports no networking module (http/https/net/dgram)', () => {
  // Match actual import/require statements only — a bare substring check
  // would false-positive on this very test's own forbidden-module list.
  for (const forbidden of ['node:http', 'node:https', 'node:net', 'node:dgram']) {
    const importRe = new RegExp(`from ['"]${forbidden}['"]|require\\(['"]${forbidden}['"]\\)`);
    assert.equal(importRe.test(SELF_SOURCE), false, `must not import ${forbidden}`);
  }
});

test('AC4 boundary: install.sh is only ever syntax-checked (bash -n), never executed', () => {
  const forbiddenExec = /execFileSync\(\s*['"]bash['"]\s*,\s*\[\s*(?!['"]-n['"])/;
  assert.equal(forbiddenExec.test(SELF_SOURCE), false, 'install.sh must only be invoked with the -n syntax-check flag');
  assert.ok(SELF_SOURCE.includes("'-n'"), 'expected the -n syntax-check flag to be present in this file');
});

// ---------------------------------------------------------------------------
// AC5 — suite green: test:fast and verify:sync both exit 0.
// ---------------------------------------------------------------------------

test('AC5 happy: package.json defines the test:fast and verify:sync scripts the suite gate depends on', () => {
  assert.equal(typeof PKG.scripts?.['test:fast'], 'string');
  assert.equal(typeof PKG.scripts?.['verify:sync'], 'string');
});

test('AC5 boundary: install.sh remains syntactically valid bash', () => {
  const stdout = checkInstallShSyntax(installShPath);
  assert.equal(stdout, '', 'bash -n must produce no output for syntactically valid input');
});

test('AC5 negative: the parity guard is fully green end-to-end — zero missing, zero unexplained, zero unparsable', () => {
  const result = fullGuardIsClean(installShContent, manifestSourcePaths, dirPrefixes, CURL_ONLY_ALLOWLIST, repoRoot);
  assert.deepEqual(result.missing, []);
  assert.deepEqual(result.unexplained, []);
  assert.deepEqual(result.unparsable, []);
});
