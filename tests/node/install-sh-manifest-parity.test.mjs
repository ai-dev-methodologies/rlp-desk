// install.sh curl-channel drift guard.
//
// TEXT-ONLY parity check between install.sh's `fetch` targets and the shared
// scripts/install-manifest.js runtimeSources() list — in both directions.
// This file performs no network access and never executes install.sh. Its
// only child_process uses are read-only: a plain `bash -n` syntax check
// (never a real run) and `git ls-files` to determine which files under a
// shipped-in-full markdown directory are tracked (never mutates state).
// Campaign sv-oracle-nv, US-001, US-005.

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

// ---------------------------------------------------------------------------
// US-005a — markdown-directory shipping decision pin (AC1-AC6).
//
// Dated decision (2026-08-10, US-005a of manifest-followup-wave.md, Option
// A — "curl = user-facing minimum"): npm/postinstall ships every markdown
// directory in full (postinstall.js consumes markdownDirectories()
// directly); the curl channel (install.sh) is the user-facing minimum and
// ships blueprints in full while explicitly excluding plans + internal:
//   - docs/rlp-desk/internal is gitignored (0 tracked files) — a fetch line
//     for a file under it 404s, and `curl -f` aborts the WHOLE install.
//     That is exactly the 2026-08-10 break this exclusion set pins as a
//     decision, not an accident (the fetch lines were deleted in 251f766).
//   - docs/rlp-desk/plans is maintainer-facing planning history, not needed
//     for a fresh curl install; npm/postinstall ships plans, curl does not.
// A directory added to markdownDirectories() later must be added to one of
// the two sets below, or the AC1 test FAILS naming it (never silently
// defaults into either bucket).
// ---------------------------------------------------------------------------
const MARKDOWN_DIR_CURL_EXCLUSIONS = new Set(['docs/rlp-desk/plans', 'docs/rlp-desk/internal']);
const MARKDOWN_DIR_SHIPPED_IN_FULL = new Set(['docs/rlp-desk/blueprints']);

function classifyMarkdownDirs(prefixes, excluded, shippedInFull) {
  const unclassified = prefixes.filter((dir) => !excluded.has(dir) && !shippedInFull.has(dir));
  return { unclassified };
}

// AC2/AC3: for a shipped-in-full directory, every git-tracked file (never
// readdir — the directory may hold untracked local scratch in normal
// maintainer use) must have a literal fetch line in install.sh. This is a
// read-only, non-mutating `git ls-files` query — see US-005b below for why
// this does not conflict with the no-exec property that file guards.
function gitTrackedFiles(repoRootPath, relativeDir) {
  const output = execFileSync('git', ['ls-files', relativeDir], { cwd: repoRootPath, encoding: 'utf8' });
  return output.split('\n').filter(Boolean);
}

function shippedInFullCoverage(relativeDir, entries, repoRootPath) {
  const tracked = gitTrackedFiles(repoRootPath, relativeDir);
  const fetchedPaths = new Set(entries.filter((e) => !e.dynamic).map((e) => e.path));
  const missing = tracked.filter((p) => !fetchedPaths.has(p));
  return { tracked, missing };
}

// AC4: exclusion is bidirectional — any fetch line under an excluded dir
// (plans/internal) is itself a failure, not merely a non-requirement.
function exclusionViolations(entries, excludedPrefixes) {
  return entries.filter(
    (e) => !e.dynamic && excludedPrefixes.some((prefix) => e.path === prefix || e.path.startsWith(`${prefix}/`))
  );
}

// ---------------------------------------------------------------------------
// US-005b — no-exec broadening (AC7-AC10).
//
// Enumerates every node:child_process API name so a future spawnSync/
// execSync/exec/fork/execFile call — or an execFileSync call that runs
// bash/install.sh outside the one sanctioned syntax-check shape — is
// caught, not just the single narrow shape the original AC4-boundary
// regex covered (see that regex a few hundred lines below).
//
// Scope: this predicate flags occurrences that could EXECUTE bash or
// install.sh specifically — the concrete risk US-005b's problem statement
// names ("any of which would run the installer"). It does not forbid other
// child_process targets such as `git` (used strictly read-only above, for
// AC2's git-tracked-file check) — AC8's import-binding check is the
// separate, unconditional guard: only execFileSync may ever be imported
// here, regardless of target.
// ---------------------------------------------------------------------------
const CHILD_PROCESS_EXEC_APIS = ['exec', 'execSync', 'execFile', 'execFileSync', 'spawn', 'spawnSync', 'fork'];

function findForbiddenExecCalls(source, apiNames) {
  const forbidden = [];
  for (const name of apiNames) {
    const callRe = new RegExp(`\\b${name}\\s*\\(`, 'g');
    let match;
    while ((match = callRe.exec(source))) {
      const snippet = source.slice(match.index, match.index + 200);
      const isSanctioned = name === 'execFileSync' && /^execFileSync\(\s*['"]bash['"]\s*,\s*\[\s*['"]-n['"]/.test(snippet);
      if (isSanctioned) continue;
      const argsSnippet = snippet.split(')')[0] + ')';
      // Catches both a bare 'bash' argument (execFileSync/spawnSync-style
      // argv) and 'bash' as a word inside a larger single-string command
      // (execSync/exec-style, e.g. 'bash install.sh').
      const targetsBash = /['"][^'"]*\bbash\b[^'"]*['"]/.test(argsSnippet);
      const targetsInstallShPath = /\binstallShPath\b/.test(argsSnippet);
      if (targetsBash || targetsInstallShPath) {
        forbidden.push({ api: name, snippet: snippet.split('\n')[0].trim() });
      }
    }
  }
  return forbidden;
}

// AC8: the sole permitted node:child_process import binding is execFileSync
// — a future spawnSync/exec/... import fails at the import site, before any
// call-site regex is needed.
function childProcessImportBindings(source) {
  const importMatch = /import\s*\{([^}]*)\}\s*from\s*['"]node:child_process['"]/.exec(source);
  if (!importMatch) return [];
  return importMatch[1].split(',').map((s) => s.trim()).filter(Boolean);
}
// --- SELF-SCAN BOUNDARY (test bodies below intentionally embed
// forbidden-shaped strings as AC9 negative-test data; the US-005b no-exec
// self-scan is deliberately scoped to source ABOVE this line) ---

const SELF_SOURCE = fs.readFileSync(selfPath, 'utf8');
const SELF_SCAN_BOUNDARY_MARKER = '// --- SELF-SCAN BOUNDARY';
const GUARD_IMPLEMENTATION_SOURCE = SELF_SOURCE.slice(0, SELF_SOURCE.indexOf(SELF_SCAN_BOUNDARY_MARKER));
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

// ---------------------------------------------------------------------------
// US-005a — markdown-directory shipping decision pin.
// ---------------------------------------------------------------------------

test('US-005a AC1 happy: every markdownDirectories() dir is classified shipped-in-full or excluded', () => {
  const { unclassified } = classifyMarkdownDirs(dirPrefixes, MARKDOWN_DIR_CURL_EXCLUSIONS, MARKDOWN_DIR_SHIPPED_IN_FULL);
  assert.deepEqual(unclassified, [], `unclassified markdown directories: ${unclassified.join(', ')}`);
});

test('US-005a AC1/AC5 negative: a new directory added to markdownDirectories() without a decision FAILS naming it', () => {
  const injected = dirPrefixes.concat(['docs/rlp-desk/totally-new-unclassified-dir']);
  const { unclassified } = classifyMarkdownDirs(injected, MARKDOWN_DIR_CURL_EXCLUSIONS, MARKDOWN_DIR_SHIPPED_IN_FULL);
  assert.deepEqual(unclassified, ['docs/rlp-desk/totally-new-unclassified-dir']);
});

test('US-005a AC6: the exclusion constant carries the dated, 2026-08-10 curl-abort rationale in its comment', () => {
  const anchor = GUARD_IMPLEMENTATION_SOURCE.indexOf('MARKDOWN_DIR_CURL_EXCLUSIONS = new Set');
  assert.ok(anchor > -1, 'sanity: the exclusion constant must exist in the guard implementation');
  const commentBlock = GUARD_IMPLEMENTATION_SOURCE.slice(Math.max(0, anchor - 1200), anchor);
  assert.ok(commentBlock.includes('2026-08-10'), 'must carry the decision date');
  assert.ok(commentBlock.toLowerCase().includes('user-facing minimum'), 'must state the curl-channel = user-facing-minimum rule');
  assert.ok(commentBlock.toLowerCase().includes('npm/postinstall ships'), 'must contrast with the npm/postinstall channel');
  assert.ok(commentBlock.toLowerCase().includes('gitignored'), 'must explain internal/ is gitignored');
  assert.ok(commentBlock.includes('404'), 'must explain the 404-abort break');
  assert.ok(commentBlock.toLowerCase().includes('curl -f'), 'must explain curl -f aborts the whole install');
});

test('US-005a AC2 happy: every git-tracked file under docs/rlp-desk/blueprints has a fetch line', () => {
  const { tracked, missing } = shippedInFullCoverage('docs/rlp-desk/blueprints', realEntries, repoRoot);
  assert.deepEqual(missing, [], `blueprints files missing a fetch line: ${missing.join(', ')}`);
  assert.equal(tracked.length, 4, 'sanity: matches the evidence table (git ls-files docs/rlp-desk/blueprints = 4)');
});

test('US-005a AC3 negative (mutation, non-vacuity): a synthetic tracked-but-unfetched blueprints file is reported missing by path', () => {
  const { tracked } = shippedInFullCoverage('docs/rlp-desk/blueprints', realEntries, repoRoot);
  const injectedTracked = tracked.concat(['docs/rlp-desk/blueprints/injected-untracked-by-test.md']);
  const fetchedPaths = new Set(realEntries.filter((e) => !e.dynamic).map((e) => e.path));
  const missing = injectedTracked.filter((p) => !fetchedPaths.has(p));
  assert.deepEqual(missing, ['docs/rlp-desk/blueprints/injected-untracked-by-test.md']);
});

test('US-005a AC4 happy: install.sh has zero fetch lines under the excluded dirs (plans, internal) — exclusion is real, not vacuous', () => {
  assert.ok(MARKDOWN_DIR_CURL_EXCLUSIONS.size >= 2, 'sanity: the exclusion set must be non-empty');
  const violations = exclusionViolations(realEntries, [...MARKDOWN_DIR_CURL_EXCLUSIONS]);
  assert.deepEqual(violations.map((e) => e.path), []);
});

test('US-005a AC4 negative: a fetch line injected under an excluded dir (plans) is reported — exclusion is bidirectional', () => {
  const syntheticContent = `${installShContent}\nfetch "$REPO_URL/docs/rlp-desk/plans/rogue-plan.md" "$DESK_DIR/rogue-plan.md"\n`;
  const { entries } = parseDownloads(syntheticContent);
  const violations = exclusionViolations(entries, [...MARKDOWN_DIR_CURL_EXCLUSIONS]);
  assert.equal(violations.length, 1);
  assert.equal(violations[0].path, 'docs/rlp-desk/plans/rogue-plan.md');
});

// ---------------------------------------------------------------------------
// US-005b — no-exec broadening.
// ---------------------------------------------------------------------------

test('US-005b AC7 happy: the guard-implementation source has zero forbidden bash/install.sh exec occurrences', () => {
  assert.ok(CHILD_PROCESS_EXEC_APIS.length === 7, 'sanity: all 7 node:child_process exec APIs must be enumerated');
  const forbidden = findForbiddenExecCalls(GUARD_IMPLEMENTATION_SOURCE, CHILD_PROCESS_EXEC_APIS);
  assert.deepEqual(forbidden, [], `forbidden exec occurrences: ${JSON.stringify(forbidden)}`);
});

test('US-005b AC10 boundary: the sanctioned execFileSync("bash", ["-n", shPath]) call is present and NOT flagged (non-vacuous)', () => {
  assert.ok(
    /execFileSync\(\s*['"]bash['"]\s*,\s*\[\s*['"]-n['"]/.test(GUARD_IMPLEMENTATION_SOURCE),
    'sanity: the sanctioned call must actually exist in the guard implementation'
  );
  const forbidden = findForbiddenExecCalls(GUARD_IMPLEMENTATION_SOURCE, CHILD_PROCESS_EXEC_APIS);
  assert.equal(forbidden.some((f) => f.api === 'execFileSync'), false);
});

test('US-005b AC10 trap: the forbidden-API name array/regex machinery does not false-positive against itself (same trap-handling as the AC4 network-module check)', () => {
  // CHILD_PROCESS_EXEC_APIS declares these names as plain strings in an
  // array literal, never as `name(...)` call syntax — this must not be
  // mistaken for a real occurrence, mirroring how the AC4-negative test
  // requires import/require syntax context so its own forbidden-module
  // array doesn't self-trigger.
  const forbidden = findForbiddenExecCalls(GUARD_IMPLEMENTATION_SOURCE, CHILD_PROCESS_EXEC_APIS);
  assert.deepEqual(forbidden, []);
});

test('US-005b AC9 negative: spawnSync("bash", [installSh]) is rejected by name', () => {
  const synthetic = "spawnSync('bash', [installSh]);";
  const forbidden = findForbiddenExecCalls(synthetic, CHILD_PROCESS_EXEC_APIS);
  assert.equal(forbidden.length, 1);
  assert.equal(forbidden[0].api, 'spawnSync');
});

test('US-005b AC9 negative: execSync("bash install.sh") is rejected by name', () => {
  const synthetic = "execSync('bash install.sh');";
  const forbidden = findForbiddenExecCalls(synthetic, CHILD_PROCESS_EXEC_APIS);
  assert.equal(forbidden.length, 1);
  assert.equal(forbidden[0].api, 'execSync');
});

test('US-005b AC9 negative: execFileSync(installShPath) (no bash, no -n) is rejected by name', () => {
  const synthetic = 'execFileSync(installShPath);';
  const forbidden = findForbiddenExecCalls(synthetic, CHILD_PROCESS_EXEC_APIS);
  assert.equal(forbidden.length, 1);
  assert.equal(forbidden[0].api, 'execFileSync');
});

test('US-005b AC8 happy: the sole node:child_process import binding is execFileSync', () => {
  const bindings = childProcessImportBindings(SELF_SOURCE);
  assert.deepEqual(bindings, ['execFileSync']);
});
