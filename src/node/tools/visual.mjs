// D3 (TODO L51-53) — `visual detect|run`: a wrapper around the PROJECT'S OWN Playwright.
//
// Pixel comparison stays Playwright's `toHaveScreenshot`; this tool adds what a Verifier
// cannot get from a bare `playwright test`: (1) a normalized, deterministic result, (2) a
// baseline-integrity guard (a Worker must not "pass" by regenerating baselines), and
// (3) "cannot judge" outcomes (tool absent, browser missing, zero tests, timeout) that are
// never confused with a pass. It never installs anything and never uses `npx`.
//
// Exit codes: 0 pass / 1 gate not met / 2 cannot judge / 64 usage.
// The parser is pinned to REAL @playwright/test 1.64.1 output (tests/fixtures/visual/):
//   - screenshot attachments are `<name>-expected.png|-actual.png|-diff.png`
//   - "Executable doesn't exist" lives in results[].error.message under --reporter=json
//   - a zero-tests run exits 1 with errors[{message:"Error: No tests found"}] and zero stats
//
// Invoked as `node ~/.claude/ralph-desk/node/run.mjs visual <detect|run> ...`.

import { spawn, execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';

export const VISUAL_SCHEMA = 'rlp-desk.visual/1';
export const DETECT_SCHEMA = 'rlp-desk.visual-detect/1';
const EXIT_USAGE = 64;
const DEFAULT_TIMEOUT_S = 600;
const DEFAULT_SNAPSHOT_GLOB = '**/*-snapshots/**';
const CONFIG_NAMES = ['ts', 'js', 'mjs', 'cjs', 'mts', 'cts'].map((ext) => `playwright.config.${ext}`);
const PKG_REL = path.join('node_modules', '@playwright', 'test', 'package.json');
const BIN_REL = path.join('node_modules', '.bin', 'playwright');
const BROWSER_MISSING = /Executable doesn't exist/u;
const ANSI = /\u001b\[[0-9;]*m/gu;
const SNAPSHOT_LONG_FLAG = /^--(update-snapshots|update-source-method|ignore-snapshots)(?:=.*)?$/u;
// Playwright 1.64.1 parses options with commander, which also accepts compact short clusters:
// `-uall` (verified: rewrote baselines), `-xu`, `-u=all`. Walk a cluster like commander does: boolean `-x`
// continues, the first `u` is the update flag, any value-taking letter (-g -G -j -c) ends the cluster.
function classifySnapshotFlag(token) {
  const long = SNAPSHOT_LONG_FLAG.exec(token);
  if (long !== null) return long[1] === 'ignore-snapshots' ? 'ignore_snapshots_flag' : 'update_snapshots_flag';
  if (/^-[^-]/u.test(token)) {
    for (const ch of token.slice(1)) {
      if (ch === 'u') return 'update_snapshots_flag';
      if (ch !== 'x') break;
    }
  }
  return null;
}
const ALLOWED_UPDATE_MODES = new Set(['all', 'changed']);
const IMAGE_ATTACHMENT = /^(.*)-(expected|actual|diff)\.png$/u;
const BROWSER_HINT = 'Install the browser yourself, e.g. `npx playwright install chromium` (rlp-desk never installs anything).';

const USAGE = [
  'Usage: node src/node/run.mjs visual <detect|run> [options]',
  '',
  '  detect [--project-dir DIR] [--json]',
  '      Is the project\'s own Playwright installed? (@playwright/test + node_modules/.bin/playwright)',
  '      exit 0 present, 2 tool_absent. Never installs anything.',
  '  run [--project-dir DIR] [--config FILE] [--grep PAT] [--baseline-ref REF] [--snapshot-glob GLOB] [--protect GLOB]...',
  '      [--timeout SECONDS] [--json] [-- <extra playwright args>]',
  '      Runs `playwright test --reporter=json` (CI=1) and normalizes the result. Baseline guard: with',
  '      --baseline-ref REF, snapshot files (default glob **/*-snapshots/**) that differ from REF in the',
  '      working tree are reported; modified/deleted baselines are a failure, added ones are listed for review.',
  '      Playwright config files (every default name, --config, the effective config; plus --protect GLOBs) are guarded the',
  '      same way (raw bytes vs the ref; git-ignored files, symlink hops/ancestors and git replace included): a change is',
  '      config_modified (exit 1). An effective ignoreSnapshots=true or updateSnapshots of all/changed, skipped tests and',
  '      test.fail() annotations are violations too. Not a security boundary against deliberate same-user tampering; the exit',
  '      code is evidence, never a verdict. When tampering matters, re-run in a fresh CLONE (never `git worktree add`) at the',
  '      start sha after npm ci, or in CI.',
  '      --update-snapshots / -u (any spelling, e.g. -uall) and --ignore-snapshots are rejected (exit 64).',
  '      exit 0 pass, 1 fail or violation, 2 cannot judge (tool absent, browser missing, no tests, timeout, unparseable,',
  '      unverifiable baseline or config, skip-worktree/assume-unchanged flags or a git filter on a guarded path, incomplete or',
  '      inconsistent report, internal error), 64 usage.',
].join('\n');

class UsageError extends Error {}

// --------------------------------------------------------------------- helpers

const stripAnsi = (text) => String(text ?? '').replace(ANSI, '');
const firstLine = (text) => stripAnsi(text).split('\n').map((l) => l.trim()).find((l) => l !== '') ?? '';
const byString = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

function emit(deps, text) {
  deps.stdout.write(text.endsWith('\n') ? text : `${text}\n`);
}

function sortedClone(value) {
  if (Array.isArray(value)) return value.map(sortedClone);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sortedClone(value[k])]));
  }
  return value;
}

const toJson = (doc) => `${JSON.stringify(sortedClone(doc), null, 2)}\n`;

async function exists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

// `**/` = any directory prefix (including none), `**` = anything, `*` = within a segment.
export function globToRegExp(glob) {
  let source = '';
  for (let i = 0; i < glob.length; i += 1) {
    const ch = glob[i];
    if (ch === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') { source += '(?:.*/)?'; i += 2; } else { source += '.*'; i += 1; }
    } else if (ch === '*') source += '[^/]*';
    else if (ch === '?') source += '[^/]';
    else source += ch.replace(/[.+^${}()|[\]\\]/gu, '\\$&');
  }
  return new RegExp(`^${source}$`, 'u');
}

// ------------------------------------------------------------------- detection

async function detect(projectDir) {
  const pkgFile = path.join(projectDir, PKG_REL);
  const binFile = path.join(projectDir, BIN_REL);
  const missing = [];
  let version = null;
  if (await exists(pkgFile)) {
    try {
      const parsed = JSON.parse(await fs.readFile(pkgFile, 'utf8'));
      version = typeof parsed.version === 'string' ? parsed.version : null;
    } catch {
      version = null;
    }
    if (version === null) missing.push(`${PKG_REL.split(path.sep).join('/')} (unreadable or no version)`);
  } else {
    missing.push(PKG_REL.split(path.sep).join('/'));
  }
  const hasBin = await exists(binFile);
  if (!hasBin) missing.push(BIN_REL.split(path.sep).join('/'));
  let config = null;
  for (const name of CONFIG_NAMES) {
    if (await exists(path.join(projectDir, name))) { config = name; break; }
  }
  const present = missing.length === 0;
  return {
    schema: DETECT_SCHEMA,
    status: present ? 'present' : 'tool_absent',
    playwright_version: present ? version : null,
    config,
    bin: present ? BIN_REL.split(path.sep).join('/') : null,
    missing,
  };
}

// ---------------------------------------------------------------------- report

// The top-level suite is the spec FILE (its title is the file name); nested suites are describe blocks.
function walkSuite(suite, trail, out, isFileSuite = false) {
  const here = isFileSuite ? trail : [...trail, suite.title];
  for (const spec of suite.specs ?? []) {
    for (const entry of spec.tests ?? []) {
      out.push({
        file: spec.file ?? suite.file ?? '',
        title: [...here, spec.title].join(' > '),
        status: entry.status,
        expectedStatus: entry.expectedStatus,
        results: Array.isArray(entry.results) ? entry.results : null,
      });
    }
  }
  for (const child of suite.suites ?? []) walkSuite(child, here, out, false);
}

function resultMessages(result) {
  const messages = [];
  if (result?.error?.message) messages.push(result.error.message);
  for (const e of result?.errors ?? []) if (e?.message) messages.push(e.message);
  return messages;
}

// Pure: normalizes one Playwright JSON report. Throws on a shape it does not recognize
// (the caller maps that to `unparseable`; unknown shapes are never guessed).
export function parsePlaywrightReport(report) {
  if (report === null || typeof report !== 'object' || !Array.isArray(report.suites)
    || report.stats === null || typeof report.stats !== 'object') {
    throw new Error('not a Playwright JSON report (need top-level `suites` array and `stats` object)');
  }
  const tests = [];
  for (const suite of report.suites) walkSuite(suite, [], tests, true);
  tests.sort((a, b) => byString(a.file, b.file) || byString(a.title, b.title));

  const num = (v) => (Number.isFinite(v) ? v : 0);
  const stats = {
    expected: num(report.stats.expected),
    unexpected: num(report.stats.unexpected),
    flaky: num(report.stats.flaky),
    skipped: num(report.stats.skipped),
  };

  const failedTests = [];
  const screenshotFailures = [];
  let browserMissing = false;
  for (const entry of tests) {
    const failing = entry.status === 'unexpected';
    const results = entry.results ?? [];
    const withError = [...results].reverse().find((r) => resultMessages(r).length > 0) ?? null;
    const messages = results.flatMap(resultMessages);
    if (messages.some((m) => BROWSER_MISSING.test(m))) browserMissing = true;
    if (!failing) continue;
    const message = withError ? firstLine(resultMessages(withError)[0]) : '';
    failedTests.push({ file: entry.file, title: entry.title, message });
    const last = withError ?? results[results.length - 1] ?? null;
    const groups = new Map();
    for (const att of last?.attachments ?? []) {
      const match = IMAGE_ATTACHMENT.exec(att?.name ?? '');
      if (!match) continue;
      const group = groups.get(match[1]) ?? { snapshot: match[1], expected: null, actual: null, diff: null };
      group[match[2]] = att.path ?? null;
      groups.set(match[1], group);
    }
    const rawMessage = withError ? stripAnsi(resultMessages(withError)[0]) : '';
    const pixels = /(\d+) pixels \(ratio ([0-9.]+) of all image pixels\) are different/u.exec(rawMessage);
    for (const group of [...groups.values()].sort((a, b) => byString(a.snapshot, b.snapshot))) {
      screenshotFailures.push({
        file: entry.file,
        title: entry.title,
        snapshot: group.snapshot,
        expected: group.expected,
        actual: group.actual,
        diff: group.diff,
        diff_pixels: pixels ? Number(pixels[1]) : null,
        diff_ratio: pixels ? Number(pixels[2]) : null,
      });
    }
  }
  const topErrors = (Array.isArray(report.errors) ? report.errors : [])
    .map((e) => firstLine(e?.message ?? ''))
    .filter((m) => m !== '');
  if ((report.errors ?? []).some((e) => BROWSER_MISSING.test(e?.message ?? ''))) browserMissing = true;
  const statusCounts = { expected: 0, unexpected: 0, flaky: 0, skipped: 0 };
  for (const entry of tests) if (entry.status in statusCounts) statusCounts[entry.status] += 1;
  // Evidence completeness per counted (non-skipped) test: it must carry results and an expectedStatus, and
  // expectedStatus must be "passed" (test.fail() / expected failures make a red test count as "expected").
  const counted = tests.filter((entry) => entry.status !== 'skipped');
  // Every result record needs a valid status, and the FINAL attempt must agree with the test's outcome.
  const RESULT_STATUSES = new Set(['passed', 'failed', 'timedOut', 'skipped', 'interrupted']);
  let invalidResultRecords = 0;
  const inconsistentTests = [];
  for (const entry of counted) {
    if (entry.results === null || entry.results.length === 0) continue;
    if (!entry.results.every((r) => RESULT_STATUSES.has(r?.status))) { invalidResultRecords += 1; continue; }
    const ordered = entry.results.every((r) => Number.isFinite(r.retry))
      ? [...entry.results].sort((a, b) => a.retry - b.retry)
      : entry.results;
    const final = ordered[ordered.length - 1].status;
    const wanted = entry.expectedStatus;
    const earlierDeviates = ordered.slice(0, -1).some((r) => r.status !== wanted);
    const consistent = entry.status === 'expected' ? final === wanted
      : entry.status === 'unexpected' ? final !== wanted
        : entry.status === 'flaky' ? final === wanted && earlierDeviates
          : false;
    if (!consistent) inconsistentTests.push(`${entry.file} > ${entry.title}`);
  }
  const testsWithoutResults = counted.filter((entry) => entry.results === null || entry.results.length === 0).length;
  const testsWithoutExpectedStatus = counted.filter((entry) => typeof entry.expectedStatus !== 'string').length;
  const expectedFailures = counted
    .filter((entry) => typeof entry.expectedStatus === 'string' && entry.expectedStatus !== 'passed')
    .map((entry) => `${entry.file} > ${entry.title}`);
  return { stats, statusCounts, invalidResultRecords, inconsistentTests, testsWithoutResults, testsWithoutExpectedStatus, expectedFailures, tests, failedTests, screenshotFailures, topErrors, browserMissing };
}

// ------------------------------------------------------------------------ git

function gitOut(cwd, args, input) {
  return new Promise((resolve, reject) => {
    // Never apply `git replace` objects (a Worker can forge the start sha's tree) and never run an fsmonitor hook.
    const child = execFile('git', ['--no-replace-objects', '-c', 'core.quotepath=false', '-c', 'core.fsmonitor=false', ...args], {
      cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
    }, (error, stdout, stderr) => {
      if (error) reject(new Error(`git ${args[0]} failed: ${(stderr || error.message).trim()}`));
      else resolve(stdout);
    });
    if (input !== undefined) child.stdin.end(input);
  });
}

class BaselineError extends Error {}

// Resolves REF before the run so an unverifiable guard fails early (nothing is spawned).
async function resolveBaselineRef(projectDir, ref) {
  try {
    const inside = (await gitOut(projectDir, ['rev-parse', '--is-inside-work-tree'])).trim();
    if (inside !== 'true') throw new Error('not inside a git work tree');
    const resolved = (await gitOut(projectDir, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`])).trim();
    if (resolved === '') throw new Error(`ref does not resolve to a commit: ${ref}`);
    return resolved;
  } catch (error) {
    throw new BaselineError(`cannot verify baselines against ${JSON.stringify(ref)}: ${error.message}`);
  }
}

// Trust boundary: this guard detects common gate-gaming shortcuts and exits 2 on anything it cannot verify. It is
// NOT a security boundary against deliberate same-user tampering (git internals, node_modules, tool binaries, raced
// files). Its exit code is evidence, never a verdict. When tampering matters, re-run in a fresh CLONE (git clone,
// never git worktree add: a linked worktree shares refs/replace and .git/info/attributes) at the start sha, after npm ci.
//
// Nothing here trusts the index, `git diff`, `git status` or git's content filters. REF's tree (`git ls-tree`,
// with replace objects disabled) is compared with the bytes on disk (`hash-object --no-filters`), over paths
// enumerated from REF's tree, the index, and the untracked and ignored lists.

const posix = (p) => p.split(path.sep).join('/');
const inNodeModules = (rel) => rel.split('/').includes('node_modules');
const PATHSPEC_CHUNK = 400;
const DIRLIKE_WALK_LIMIT = 20000;

function parseTree(output) {
  const entries = new Map();
  for (const record of output.split('\0')) {
    const m = /^(\d+) (\w+) ([0-9a-f]+)\t([\s\S]*)$/u.exec(record);
    if (m !== null) entries.set(m[4], { mode: m[1], type: m[2], sha: m[3] });
  }
  return entries;
}

// REF entry vs what is on disk. `kind`: 'missing' | 'file' | 'symlink' | 'dir' | 'other'; `sha` is the raw-content
// blob id (symlink: of its link text). Returns 'same' | 'added' | 'deleted' | 'changed'.
function verdict(ref, kind, sha) {
  if (ref === undefined || ref === null) return kind === 'missing' ? 'same' : (kind === 'dir' ? 'same' : 'added');
  if (kind === 'missing') return 'deleted';
  if (kind === 'file') return ref.type === 'blob' && ref.mode !== '120000' && ref.sha === sha ? 'same' : 'changed';
  if (kind === 'symlink') return ref.mode === '120000' && ref.sha === sha ? 'same' : 'changed';
  if (kind === 'dir') return ref.type === 'tree' ? 'same' : 'changed';
  return 'changed';
}

async function lstatOrNull(file) {
  try { return await fs.lstat(file); } catch (error) { if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null; throw error; }
}

async function classifyOnDisk(cwd, rel) {
  // lstat follows intermediate symlinks: a directory swapped for a symlink must be seen as such.
  const parts = rel.split('/');
  let current = cwd;
  for (let i = 0; i < parts.length - 1; i += 1) {
    current = path.join(current, parts[i]);
    const ancestor = await lstatOrNull(current);
    if (ancestor === null) break;
    if (ancestor.isSymbolicLink()) return { kind: 'symlinked-ancestor' };
  }
  const stat = await lstatOrNull(path.join(cwd, rel));
  if (stat === null) return { kind: 'missing' };
  if (stat.isSymbolicLink()) {
    return { kind: 'symlink', sha: (await gitOut(cwd, ['hash-object', '--stdin'], await fs.readlink(path.join(cwd, rel)))).trim() };
  }
  if (stat.isFile()) return { kind: 'file' };
  return { kind: stat.isDirectory() ? 'dir' : 'other' };
}

// Raw-content blob ids for many regular files in one git call. A name containing a newline cannot go through
// --stdin-paths and is reported as null (treated as changed).
async function hashFiles(cwd, rels) {
  const shas = new Map();
  const usable = rels.filter((r) => !r.includes('\n'));
  for (const r of rels) if (r.includes('\n')) shas.set(r, null);
  if (usable.length > 0) {
    // Absolute paths: with --stdin-paths git resolves relative ones from the repository root, not from the cwd.
    const out = (await gitOut(cwd, ['hash-object', '--no-filters', '--stdin-paths'], `${usable.map((r) => path.resolve(cwd, r)).join('\n')}\n`)).split('\n');
    usable.forEach((r, i) => shas.set(r, out[i] || null));
  }
  return shas;
}

async function guardInspect(projectDir, realProject, resolved, { snapshotGlob, protectGlobs, exactCandidates }) {
  const top = await fs.realpath((await gitOut(projectDir, ['rev-parse', '--show-toplevel'])).trim());
  const prefix = (await gitOut(projectDir, ['rev-parse', '--show-prefix'])).trim();
  const refCache = new Map();
  const refEntry = async (repoRel) => {
    if (!refCache.has(repoRel)) {
      const entries = parseTree(await gitOut(top, ['ls-tree', '-z', '--full-tree', resolved, '--', repoRel]));
      refCache.set(repoRel, entries.get(repoRel) ?? null);
    }
    return refCache.get(repoRel);
  };
  const insideProject = (rel) => !(rel === '..' || rel.startsWith('../') || path.isAbsolute(rel));
  const snapMatcher = globToRegExp(snapshotGlob);
  const protMatchers = protectGlobs.map(globToRegExp);
  const matchesAny = (p) => snapMatcher.test(p) || protMatchers.some((m) => m.test(p));
  const added = new Set();
  const modified = new Set();
  const deleted = new Set();
  const configChanged = new Set();
  const unverifiable = { outside: new Set(), index: new Set(), filters: new Set(), snapshotDirs: new Set() };
  const guardedRepoRel = new Set();

  // 1. Glob-matched paths: REF's tree, the index, untracked and ignored files. Git is only asked about the
  // globs (pathspecs), so a large ignored tree such as .venv or .next costs nothing.
  const treeOut = await gitOut(projectDir, ['ls-tree', '-r', '-z', '--full-tree', resolved, ...(prefix === '' ? [] : ['--', prefix])]);
  const refMap = new Map(); // glob-matched paths at REF
  const refAll = new Map(); // every path at REF below the project directory
  for (const [p, entry] of parseTree(treeOut)) {
    const rel = prefix !== '' && p.startsWith(prefix) ? p.slice(prefix.length) : p;
    refAll.set(rel, entry);
    if (!inNodeModules(rel) && matchesAny(rel)) refMap.set(rel, entry);
  }
  const globs = [snapshotGlob, ...protectGlobs];
  // git's :(glob) only agrees with ours when every ** is a whole path segment; otherwise use a plain pathspec (fnmatch,
  // * crosses /), a superset that is filtered again in JS. A glob ending in /** also asks for the directory itself, so a
  // symlink or nested repository standing in for the snapshot directory is listed.
  const starsBounded = (g) => [...g.matchAll(/\*\*/gu)].every((m) => (m.index === 0 || g[m.index - 1] === '/') && (m.index + 2 === g.length || g[m.index + 2] === '/'));
  const specGlobs = globs.flatMap((g) => (g.endsWith('/**') ? [g, g.slice(0, -3)] : [g]));
  const spec = globs.some((g) => /[[\\]/u.test(g)) ? [] : ['--', ...specGlobs.map((g) => (starsBounded(g) ? `:(glob)${g}` : g))];
  const broad = ['--directory'];
  const listings = await Promise.all([
    gitOut(projectDir, ['ls-files', '-z', '--cached', '--others', '--exclude-standard', ...spec]),
    gitOut(projectDir, ['ls-files', '-z', '--others', '--ignored', '--exclude-standard', ...spec]),
    ...(globs.every((g) => g.endsWith('/**')) ? [] : [
      gitOut(projectDir, ['ls-files', '-z', '--others', '--exclude-standard', ...broad]),
      gitOut(projectDir, ['ls-files', '-z', '--others', '--ignored', '--exclude-standard', ...broad]),
    ]),
  ]);
  const candidates = new Set(refMap.keys());
  const entries = new Set();
  for (const listing of listings) {
    for (const p of listing.split('\0')) {
      if (p === '' || inNodeModules(p)) continue;
      entries.add(p);
      if (matchesAny(p)) candidates.add(p);
    }
  }
  // Directory-like entries git does not descend into (symlinks to directories, nested repositories): list what is
  // inside and match it against the globs. An entry is walked ONLY when its own path can lead to a guarded path: it
  // matches a glob, or one of the glob's directory prefixes (`**/*-snapshots` for `**/*-snapshots/**`, `helpers` for
  // `helpers/*.js`). Entries git lists only through its leading-directory match (an unrelated linked worktree or nested
  // repository, a symlink to a build tree) are never entered. One walk budget covers all entries; too many files -> cannot judge.
  const prefixMatchers = [];
  let everyDirectoryRelevant = false;
  for (const g of globs) {
    const dirSegs = g.split('/').slice(0, -1);
    if (dirSegs.length === 1 && dirSegs[0] === '**') everyDirectoryRelevant = true; // e.g. **/*.png: any directory may hold a match
    for (let k = 1; k <= dirSegs.length; k += 1) {
      const prefixGlob = dirSegs.slice(0, k).join('/');
      if (prefixGlob !== '**') prefixMatchers.push(globToRegExp(prefixGlob));
    }
  }
  const couldLead = (bare) => everyDirectoryRelevant || matchesAny(bare) || prefixMatchers.some((m) => m.test(bare));
  const hiddenFiles = new Set();
  const linked = new Map(); // files behind a TRACKED, unchanged symlink -> { abs } compared with REF at their real paths
  let walkBudget = DIRLIKE_WALK_LIMIT;
  let walkExhausted = false;
  for (const entry of [...entries].sort(byString)) {
    if (walkExhausted) break;
    const bare = entry.replace(/\/$/u, '');
    if (!couldLead(bare)) continue;
    const stat = await lstatOrNull(path.join(realProject, bare));
    let root = null;
    if (stat?.isSymbolicLink()) {
      try {
        const real = await fs.realpath(path.join(realProject, bare));
        if ((await fs.stat(real)).isDirectory()) root = real;
      } catch { /* dangling or unreadable: not a directory */ }
    } else if (stat?.isDirectory() && entry.endsWith('/') && await exists(path.join(realProject, bare, '.git'))) {
      root = path.join(realProject, bare);
    }
    if (root === null) continue;
    // A tracked symlink whose link text is unchanged: its files are REF-tracked at their real paths.
    const refLink = refAll.get(bare);
    let trackedUnchanged = false;
    if (stat.isSymbolicLink() && refLink?.mode === '120000') {
      trackedUnchanged = refLink.sha === (await gitOut(realProject, ['hash-object', '--stdin'], await fs.readlink(path.join(realProject, bare)))).trim();
      if (!trackedUnchanged) modified.add(bare); // retargeted baseline directory
    }
    const walk = async (dir, rel) => {
      for (const child of await fs.readdir(dir, { withFileTypes: true })) {
        if (walkExhausted) return;
        if (child.name === '.git' || child.name === 'node_modules') continue;
        const childRel = `${rel}/${child.name}`;
        if (child.isDirectory()) { await walk(path.join(dir, child.name), childRel); continue; }
        walkBudget -= 1;
        if (walkBudget < 0) { walkExhausted = true; unverifiable.snapshotDirs.add(entry); return; }
        if (!matchesAny(childRel)) continue;
        if (trackedUnchanged) linked.set(childRel, path.join(dir, child.name));
        else hiddenFiles.add(childRel);
      }
    };
    await walk(root, bare);
  }
  for (const p of hiddenFiles) if (!refMap.has(p)) candidates.add(p);
  if (linked.size > 0) {
    const abs = [...linked.values()];
    const linkedShas = await hashFiles(realProject, abs);
    for (const [childRel, absPath] of linked) {
      const realRel = posix(path.relative(realProject, absPath));
      const ref = insideProject(realRel) ? refAll.get(realRel) : await refEntry(posix(path.relative(top, absPath)));
      const state = verdict(ref ?? undefined, 'file', linkedShas.get(absPath));
      if (state === 'same') continue;
      if (snapMatcher.test(childRel)) (state === 'added' ? added : modified).add(childRel);
      if (protMatchers.some((m) => m.test(childRel))) configChanged.add(childRel);
    }
  }
  const files = [...candidates].sort(byString);
  const onDisk = new Map();
  for (const p of files) onDisk.set(p, await classifyOnDisk(realProject, p));
  const regular = files.filter((p) => onDisk.get(p).kind === 'file');
  const shas = await hashFiles(realProject, regular);
  for (const p of files) {
    const d = onDisk.get(p);
    const state = verdict(refMap.get(p), d.kind, d.kind === 'file' ? shas.get(p) : d.sha);
    if (state === 'same') continue;
    if (snapMatcher.test(p)) (state === 'added' ? added : state === 'deleted' ? deleted : modified).add(p);
    if (protMatchers.some((m) => m.test(p))) configChanged.add(p);
  }

  // 2. Exact protected paths (config candidates): ancestors, the path itself and every symlink hop, against REF.
  const display = (abs) => posix(path.relative(realProject, abs));
  const insideTop = (rel) => !(rel === '..' || rel.startsWith('../') || path.isAbsolute(rel));
  const hashText = async (text) => (await gitOut(top, ['hash-object', '--stdin'], text)).trim();
  // Resolve a path component by component, like the kernel does: at EVERY symlink (file or directory, any hop) compare
  // its link text with REF's entry, then continue from its target. Directories are compared by type with REF.
  const examine = async (startAbs) => {
    let location = startAbs;
    let rel = posix(path.relative(top, location));
    if (!insideTop(rel)) {
      // Tolerate a non-canonical spelling of a path inside the repo (/var vs /private/var).
      try { location = path.join(await fs.realpath(path.dirname(startAbs)), path.basename(startAbs)); } catch { /* keep */ }
      rel = posix(path.relative(top, location));
      if (!insideTop(rel)) { unverifiable.outside.add(startAbs); return; }
    }
    let parts = rel === '' ? [] : rel.split('/');
    let hops = 0;
    resolving: while (true) {
      let current = top;
      for (let i = 0; i < parts.length; i += 1) {
        const next = path.join(current, parts[i]);
        const nextRel = posix(path.relative(top, next));
        const last = i === parts.length - 1;
        const stat = await lstatOrNull(next);
        const ref = await refEntry(nextRel);
        if (stat === null) {
          if (ref !== null) configChanged.add(display(next)); // existed at the ref, gone now
          return;
        }
        if (stat.isSymbolicLink()) {
          const text = await fs.readlink(next);
          if (!(ref !== null && ref.mode === '120000' && ref.sha === await hashText(text))) configChanged.add(display(next));
          guardedRepoRel.add(nextRel);
          hops += 1;
          if (hops > 40) { unverifiable.outside.add(`${startAbs} (symlink chain too deep)`); return; }
          const targetRel = posix(path.relative(top, path.resolve(current, text)));
          if (!insideTop(targetRel)) { unverifiable.outside.add(path.resolve(current, text)); return; }
          parts = [...(targetRel === '' ? [] : targetRel.split('/')), ...parts.slice(i + 1)];
          continue resolving;
        }
        if (!last) {
          if (!stat.isDirectory()) return; // a file where a directory is needed: the path does not exist
          if (ref !== null && ref.type !== 'tree') configChanged.add(display(next));
          current = next;
          continue;
        }
        let kind = 'other';
        let sha;
        if (stat.isFile()) {
          kind = 'file';
          sha = (await gitOut(top, ['hash-object', '--no-filters', '--', next])).trim();
        } else if (stat.isDirectory()) kind = 'dir';
        if (verdict(ref ?? undefined, kind, sha) !== 'same') configChanged.add(display(next));
        guardedRepoRel.add(nextRel);
        return;
      }
      return;
    }
  };
  for (const candidate of exactCandidates) await examine(candidate);

  // 3. Index flags and content filters would make git lie about guarded paths: cannot judge.
  const guarded = [...new Set([...guardedRepoRel, ...files.map((p) => `${prefix}${p}`)])].sort(byString);
  for (let i = 0; i < guarded.length; i += PATHSPEC_CHUNK) {
    const chunk = guarded.slice(i, i + PATHSPEC_CHUNK);
    const listing = await gitOut(top, ['ls-files', '-v', '-z', '--', ...chunk.map((p) => `:(literal)${p}`)]);
    for (const record of listing.split('\0')) {
      if (record === '') continue;
      const tag = record[0];
      if (tag === 'S' || (tag >= 'a' && tag <= 'z')) unverifiable.index.add(record.slice(2));
    }
  }
  if (guarded.length > 0) {
    try {
      const attrs = (await gitOut(top, ['check-attr', '-z', '--stdin', 'filter'], `${guarded.join('\0')}\0`)).split('\0');
      for (let i = 0; i + 2 < attrs.length; i += 3) {
        if (attrs[i + 2] !== 'unspecified' && attrs[i + 2] !== 'unset') unverifiable.filters.add(attrs[i]);
      }
    } catch (error) {
      unverifiable.filters.add(`(git check-attr failed: ${error.message})`);
    }
  }

  const list = (set) => [...set].sort(byString);
  return {
    baseline: { added: list(added), modified: list(modified), deleted: list(deleted), config_changed: list(configChanged) },
    unverifiable: { outside: list(unverifiable.outside), index: list(unverifiable.index), filters: list(unverifiable.filters), snapshotDirs: list(unverifiable.snapshotDirs) },
  };
}

// -------------------------------------------------------------------- process

function runPlaywright(bin, args, { cwd, env, timeoutMs }) {
  return new Promise((resolve) => {
    const out = [];
    const err = [];
    let timedOut = false;
    let child;
    try {
      child = spawn(bin, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (error) {
      resolve({ spawnError: error.message, code: null, stdout: '', stderr: '', timedOut: false });
      return;
    }
    const timer = setTimeout(() => {
      timedOut = true;
      try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); }
    }, timeoutMs);
    child.stdout.on('data', (d) => out.push(d));
    child.stderr.on('data', (d) => err.push(d));
    child.on('error', (error) => {
      clearTimeout(timer);
      resolve({ spawnError: error.message, code: null, stdout: '', stderr: '', timedOut: false });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({
        spawnError: null,
        code,
        stdout: Buffer.concat(out).toString('utf8'),
        stderr: Buffer.concat(err).toString('utf8'),
        timedOut,
      });
    });
  });
}

// ------------------------------------------------------------------- commands

function parseArgs(args, spec) {
  const flags = {};
  const extra = [];
  const positional = [];
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--') { extra.push(...args.slice(i + 1)); break; }
    if (token === '--help' || token === '-h') flags.help = true;
    else if (spec.bool.includes(token)) flags[token.slice(2)] = true;
    else if (spec.value.includes(token)) {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      flags[token.slice(2)] = value;
      i += 1;
    } else if (spec.multi?.includes(token)) {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      flags[token.slice(2)] = [...(flags[token.slice(2)] ?? []), value];
      i += 1;
    } else if (classifySnapshotFlag(token) !== null) {
      throw new UsageError(`${token} is not allowed: a campaign must never regenerate or ignore its own baselines`, { cause: classifySnapshotFlag(token) });
    } else if (token.startsWith('-')) throw new UsageError(`unknown visual option: ${token}`);
    else positional.push(token);
  }
  return { flags, extra, positional };
}

function resolveProjectDir(deps, flags) {
  return path.resolve(deps.cwd, flags['project-dir'] ?? '.');
}

async function runDetect(args, deps) {
  const { flags, positional } = parseArgs(args, { bool: ['--json'], value: ['--project-dir'] });
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length > 0) throw new UsageError(`unexpected argument: ${positional[0]}`);
  const doc = await detect(resolveProjectDir(deps, flags));
  if (flags.json) emit(deps, toJson(doc));
  else {
    emit(deps, [
      `visual detect: ${doc.status}`,
      `playwright_version: ${doc.playwright_version ?? '-'}`,
      `config: ${doc.config ?? '-'}`,
      `bin: ${doc.bin ?? '-'}`,
      ...doc.missing.map((m) => `missing: ${m}`),
    ].join('\n'));
  }
  return doc.status === 'present' ? 0 : 2;
}

function baseDoc() {
  return {
    schema: VISUAL_SCHEMA,
    status: 'error',
    reason: null,
    hint: null,
    playwright_version: null,
    stats: null,
    failed_tests: [],
    screenshot_failures: [],
    baseline: null,
    violations: [],
    warnings: [],
    exit_code: 2,
  };
}

function renderText(doc) {
  const lines = [`visual run: ${doc.status}${doc.reason ? ` (${doc.reason})` : ''}`];
  if (doc.playwright_version) lines.push(`playwright ${doc.playwright_version}`);
  if (doc.stats) {
    lines.push(`tests: expected ${doc.stats.expected}, unexpected ${doc.stats.unexpected}, flaky ${doc.stats.flaky}, skipped ${doc.stats.skipped}`);
  }
  if (doc.baseline) {
    lines.push(`baseline ${doc.baseline.ref}: added ${doc.baseline.added.length}, modified ${doc.baseline.modified.length}, deleted ${doc.baseline.deleted.length}`);
    for (const kind of ['added', 'modified', 'deleted', 'config_changed']) for (const f of doc.baseline[kind]) lines.push(`  ${kind}: ${f}`);
  }
  for (const f of doc.failed_tests) lines.push(`failed: ${f.file} > ${f.title}${f.message ? ` — ${f.message}` : ''}`);
  for (const s of doc.screenshot_failures) {
    lines.push(`screenshot: ${s.snapshot} expected=${s.expected} actual=${s.actual} diff=${s.diff}`);
  }
  for (const v of doc.violations) lines.push(`violation: ${v}`);
  for (const w of doc.warnings) lines.push(`warning: ${w}`);
  if (doc.hint) lines.push(`hint: ${doc.hint}`);
  return lines.join('\n');
}

function finish(deps, flags, doc, code) {
  doc.exit_code = code;
  emit(deps, flags.json ? toJson(doc) : renderText(doc));
  return code;
}

function rejectionDoc(deps, json, kind, message) {
  const doc = baseDoc();
  doc.reason = kind;
  doc.violations = [kind];
  doc.warnings = [message];
  doc.exit_code = EXIT_USAGE;
  emit(deps, json ? toJson(doc) : renderText(doc));
  return EXIT_USAGE;
}

async function runRun(args, deps) {
  let parsed;
  try {
    parsed = parseArgs(args, {
      bool: ['--json'],
      value: ['--project-dir', '--config', '--grep', '--baseline-ref', '--snapshot-glob', '--timeout'],
      multi: ['--protect'],
    });
  } catch (error) {
    if (error instanceof UsageError && (error.cause === 'update_snapshots_flag' || error.cause === 'ignore_snapshots_flag')) {
      deps.stderr.write(`${error.message}\n`);
      return rejectionDoc(deps, args.includes('--json'), error.cause, error.message);
    }
    throw error;
  }
  const { flags, extra, positional } = parsed;
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length > 0) throw new UsageError(`unexpected argument: ${positional[0]}`);
  for (const token of extra) {
    const kind = classifySnapshotFlag(token);
    if (kind !== null) {
      const message = `${token} is not allowed: a campaign must never regenerate or ignore its own baselines`;
      deps.stderr.write(`${message}\n`);
      return rejectionDoc(deps, flags.json === true, kind, message);
    }
  }
  let timeoutS = DEFAULT_TIMEOUT_S;
  if (flags.timeout !== undefined) {
    timeoutS = Number(flags.timeout);
    if (!Number.isFinite(timeoutS) || timeoutS <= 0) {
      throw new UsageError(`--timeout requires a positive number of seconds, got ${JSON.stringify(flags.timeout)}`);
    }
  }
  const ref = flags['baseline-ref'];
  if (ref !== undefined && ref.startsWith('-')) throw new UsageError(`--baseline-ref must be a git ref, got ${JSON.stringify(ref)}`);
  const snapshotGlob = flags['snapshot-glob'] ?? DEFAULT_SNAPSHOT_GLOB;

  const projectDir = resolveProjectDir(deps, flags);
  const doc = baseDoc();
  const found = await detect(projectDir);
  if (found.status !== 'present') {
    doc.status = 'tool_absent';
    doc.reason = 'tool_absent';
    doc.warnings = found.missing.map((m) => `missing: ${m}`);
    return finish(deps, flags, doc, 2);
  }
  doc.playwright_version = found.playwright_version;

  // Fail early (nothing spawned) when an explicit baseline ref cannot be verified.
  let resolvedRef = null;
  if (ref !== undefined) {
    try {
      resolvedRef = await resolveBaselineRef(projectDir, ref);
    } catch (error) {
      if (!(error instanceof BaselineError)) throw error;
      doc.reason = 'baseline_unverifiable';
      doc.warnings.push(error.message);
      return finish(deps, flags, doc, 2);
    }
  }

  const pwArgs = ['test', '--reporter=json'];
  if (flags.config !== undefined) pwArgs.push('--config', flags.config);
  if (flags.grep !== undefined) pwArgs.push('--grep', flags.grep);
  pwArgs.push(...extra);
  const result = await runPlaywright(path.join(projectDir, BIN_REL), pwArgs, {
    cwd: projectDir,
    env: { ...(deps.env ?? process.env), CI: '1' },
    timeoutMs: timeoutS * 1000,
  });

  let report = null;
  let parsedReport = null;
  if (result.spawnError === null && !result.timedOut) {
    try {
      report = JSON.parse(result.stdout);
      parsedReport = parsePlaywrightReport(report);
    } catch {
      parsedReport = null;
    }
  }

  // Config files the gate depends on: every default name (Playwright takes the first that exists), --config, and the
  // effective config named by the report. Candidates stay lexical: symlink hops and ancestors are compared too.
  const realProject = await fs.realpath(projectDir);
  const unrealProject = path.resolve(projectDir);
  const lexical = (candidate) => {
    const abs = path.resolve(realProject, candidate);
    return path.isAbsolute(candidate) && (abs === unrealProject || abs.startsWith(unrealProject + path.sep))
      ? path.join(realProject, path.relative(unrealProject, abs))
      : abs;
  };
  const configCandidates = CONFIG_NAMES.map(lexical);
  if (flags.config !== undefined) configCandidates.push(lexical(flags.config));
  const effective = report?.config?.configFile;
  if (typeof effective === 'string' && effective !== '') configCandidates.push(lexical(effective));

  let unverifiable = { outside: [], index: [], filters: [], snapshotDirs: [] };
  if (ref !== undefined && result.spawnError === null && !result.timedOut) {
    const guard = await guardInspect(projectDir, realProject, resolvedRef, {
      snapshotGlob,
      protectGlobs: flags.protect ?? [],
      exactCandidates: configCandidates,
    });
    doc.baseline = { ref, resolved: resolvedRef, ...guard.baseline };
    unverifiable = guard.unverifiable;
  } else if (ref === undefined) {
    doc.warnings.push('no --baseline-ref given: baseline integrity and config integrity were NOT checked (pass the campaign start sha recorded in the test-spec)');
  }

  if (result.spawnError !== null) {
    doc.reason = 'spawn_failed';
    doc.warnings.push(result.spawnError);
    return finish(deps, flags, doc, 2);
  }
  if (result.timedOut) {
    doc.reason = 'timeout';
    doc.warnings.push(`Playwright did not finish within ${timeoutS}s and was killed`);
    return finish(deps, flags, doc, 2);
  }
  if (unverifiable.outside.length > 0) {
    doc.reason = 'config_unverifiable';
    doc.warnings.push(...unverifiable.outside.map((p) => `cannot verify against ${ref}: ${p} is outside the git repository`));
    return finish(deps, flags, doc, 2);
  }
  if (unverifiable.snapshotDirs.length > 0) {
    doc.reason = 'snapshot_dir_unverifiable';
    doc.warnings.push(...unverifiable.snapshotDirs.map((p) => `${p} is a symlinked or nested-repository directory with too many files to list: the baselines inside cannot be verified`));
    return finish(deps, flags, doc, 2);
  }
  if (unverifiable.index.length > 0) {
    doc.reason = 'index_flags_unverifiable';
    doc.warnings.push(...unverifiable.index.map((p) => `${p} is marked skip-worktree or assume-unchanged in the git index: git would not report changes to it`));
    return finish(deps, flags, doc, 2);
  }
  if (unverifiable.filters.length > 0) {
    doc.reason = 'filter_unverifiable';
    doc.warnings.push(...unverifiable.filters.map((p) => `${p} has a git content filter (clean/smudge, e.g. LFS): its bytes cannot be compared with ${ref}`));
    return finish(deps, flags, doc, 2);
  }

  if (parsedReport === null) {
    if (BROWSER_MISSING.test(result.stderr) || BROWSER_MISSING.test(result.stdout)) {
      doc.reason = 'browser_missing';
      doc.hint = BROWSER_HINT;
    } else {
      doc.reason = 'unparseable';
      doc.warnings.push(`stdout is not a Playwright JSON report (exit ${result.code}): ${firstLine(result.stderr) || firstLine(result.stdout) || 'no output'}`);
    }
    return finish(deps, flags, doc, 2);
  }

  doc.stats = parsedReport.stats;
  doc.failed_tests = parsedReport.failedTests;
  doc.screenshot_failures = parsedReport.screenshotFailures;
  if (parsedReport.browserMissing || BROWSER_MISSING.test(result.stderr)) {
    doc.reason = 'browser_missing';
    doc.hint = BROWSER_HINT;
    return finish(deps, flags, doc, 2);
  }
  const { expected, unexpected, flaky } = parsedReport.stats;
  if (expected + unexpected + flaky === 0) {
    const noTests = parsedReport.topErrors.length === 0 || parsedReport.topErrors.some((m) => /No tests found/u.test(m));
    doc.reason = noTests ? 'no_tests' : 'runner_error';
    doc.warnings.push(...parsedReport.topErrors);
    return finish(deps, flags, doc, 2);
  }
  // Evidence must be complete and consistent, else it is not evidence (exit 2, never a pass).
  const counts = parsedReport.statusCounts;
  const parsedStats = parsedReport.stats;
  if (counts.expected !== parsedStats.expected || counts.unexpected !== parsedStats.unexpected
    || counts.flaky !== parsedStats.flaky || counts.skipped !== parsedStats.skipped) {
    doc.reason = 'report_inconsistent';
    doc.warnings.push(`stats (expected ${parsedStats.expected}, unexpected ${parsedStats.unexpected}, flaky ${parsedStats.flaky}, skipped ${parsedStats.skipped}) do not match the ${parsedReport.tests.length} test(s) in the report suites (${counts.expected}/${counts.unexpected}/${counts.flaky}/${counts.skipped})`);
    return finish(deps, flags, doc, 2);
  }
  if (parsedReport.testsWithoutResults > 0 || parsedReport.testsWithoutExpectedStatus > 0 || parsedReport.invalidResultRecords > 0) {
    doc.reason = 'report_incomplete';
    doc.warnings.push(`${parsedReport.testsWithoutResults} counted test(s) have no results, ${parsedReport.testsWithoutExpectedStatus} have no expectedStatus and ${parsedReport.invalidResultRecords} have a result record without a valid status: the report is not evidence`);
    return finish(deps, flags, doc, 2);
  }
  if (parsedReport.inconsistentTests.length > 0) {
    doc.reason = 'report_inconsistent';
    doc.warnings.push(`the final attempt does not match the test outcome for: ${parsedReport.inconsistentTests.join('; ')}`);
    return finish(deps, flags, doc, 2);
  }
  const effectiveConfig = report?.config;
  const projects = Array.isArray(effectiveConfig?.filteredProjects) ? effectiveConfig.filteredProjects : [];
  if (typeof effectiveConfig?.updateSnapshots !== 'string' || projects.length === 0
    || !projects.every((p) => typeof p?.ignoreSnapshots === 'boolean')) {
    doc.reason = 'report_incomplete';
    doc.warnings.push('the report lacks config.updateSnapshots or config.filteredProjects[].ignoreSnapshots: the effective snapshot controls cannot be verified');
    return finish(deps, flags, doc, 2);
  }

  if (flaky > 0) doc.warnings.push(`${flaky} flaky test(s): passed only on retry`);
  if (unexpected === 0 && parsedReport.topErrors.length > 0) {
    doc.reason = 'runner_error';
    doc.warnings.push(...parsedReport.topErrors);
    return finish(deps, flags, doc, 2);
  }
  if (unexpected === 0 && result.code !== 0) {
    doc.reason = `runner_exit_${result.code}`;
    doc.warnings.push(`Playwright exited ${result.code} but the report shows no failures`);
    return finish(deps, flags, doc, 2);
  }

  if (doc.baseline) {
    if (doc.baseline.modified.length > 0) doc.violations.push('baseline_modified');
    if (doc.baseline.deleted.length > 0) doc.violations.push('baseline_deleted');
    if (doc.baseline.config_changed.length > 0) doc.violations.push('config_modified');
  }
  // The effective controls are in the report whatever set them (CLI cluster, config file, any project).
  if (ALLOWED_UPDATE_MODES.has(effectiveConfig.updateSnapshots)) doc.violations.push('update_snapshots_enabled');
  if (projects.some((p) => p.ignoreSnapshots === true)) {
    doc.violations.push('ignore_snapshots_enabled');
    doc.warnings.push('ignoreSnapshots is true in the effective Playwright config: screenshot assertions were skipped');
  }
  if (parsedReport.expectedFailures.length > 0) {
    doc.violations.push('expected_failure');
    doc.warnings.push(`expected-failure annotation (test.fail) on: ${parsedReport.expectedFailures.join('; ')}`);
  }
  if (parsedStats.skipped > 0) {
    doc.violations.push('tests_skipped');
    doc.warnings.push(`${parsedStats.skipped} test(s) skipped: a skipped screenshot test verified nothing`);
  }
  doc.violations = [...new Set(doc.violations)].sort(byString);
  if (unexpected > 0 || doc.violations.length > 0) {
    doc.status = 'fail';
    return finish(deps, flags, doc, 1);
  }
  doc.status = 'pass';
  return finish(deps, flags, doc, 0);
}

export async function runCommand(args, deps) {
  const [sub, ...rest] = args;
  try {
    if (sub === undefined || sub === '--help' || sub === '-h') {
      emit(deps, USAGE);
      return 0;
    }
    if (sub === 'detect') return await runDetect(rest, deps);
    if (sub === 'run') return await runRun(rest, deps);
    throw new UsageError(`unknown visual subcommand: ${sub}`);
  } catch (error) {
    if (!(error instanceof UsageError)) {
      // An unexpected error must never surface as exit 1 ("fail"): the caller could not judge.
      const doc = baseDoc();
      doc.reason = 'internal_error';
      doc.warnings = [error?.message ?? String(error)];
      doc.exit_code = 2;
      emit(deps, args.includes('--json') ? toJson(doc) : renderText(doc));
      return 2;
    }
    deps.stderr.write(`${error.message}\n${USAGE}\n`);
    return EXIT_USAGE;
  }
}
