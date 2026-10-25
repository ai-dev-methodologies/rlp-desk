import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { existsSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import { runCommand, parsePlaywrightReport, globToRegExp } from '../../src/node/tools/visual.mjs';

// D3 (TODO L51-53) — `visual detect|run`: a wrapper around the PROJECT'S OWN Playwright.
// Design: .omc/artifacts/backlog-2026-10-25/d-roadmap-design.md D3, adjusted to the REAL
// Playwright 1.64.1 output captured in tests/fixtures/visual/ (see w2-fixtures.md):
//   - screenshot attachments are `<name>-expected.png|-actual.png|-diff.png` (+ `error-context`)
//   - a zero-tests run exits 1 with errors:[{message:"Error: No tests found"}] and zero stats
//   - with --reporter=json "Executable doesn't exist" is inside results[].error.message, NOT on stderr
// External Playwright is replaced by a stub node_modules/.bin/playwright that replays the real
// fixtures. Fixtures derived from the real ones are built in this file by a function whose name
// starts with `derived` so they cannot be mistaken for captured output.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const FIX = path.join(repoRoot, 'tests', 'fixtures', 'visual');
const REAL_REPORT = path.join(FIX, 'playwright-1.64.1-report.json');
const REAL_ZERO = path.join(FIX, 'playwright-1.64.1-zero-tests.json');
const REAL_BROWSER_MISSING = path.join(FIX, 'playwright-1.64.1-browser-missing.json');

const readJson = async (file) => JSON.parse(await fs.readFile(file, 'utf8'));

// A temp project OUTSIDE the rlp-desk git work tree: the baseline guard asks git about the
// project, so a project under repoRoot would silently resolve to rlp-desk's own repository.
async function createProject(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-d3-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

const STUB = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const control = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.stub-control.json'), 'utf8'));
const argv = process.argv.slice(2);
if (control.marker) fs.appendFileSync(control.marker, JSON.stringify({ argv, ci: process.env.CI, cwd: process.cwd() }) + '\\n');
if (control.pidFile) fs.writeFileSync(control.pidFile, String(process.pid));
if (control.grandchildPidFile) {
  const gc = require('node:child_process').spawn('sleep', ['120'], { stdio: 'ignore' }); // same process group: part of the tree
  fs.writeFileSync(control.grandchildPidFile, String(gc.pid));
}
for (const m of control.mutate || []) {
  if (m.delete) { fs.rmSync(m.path, { force: true }); continue; }
  fs.mkdirSync(path.dirname(m.path), { recursive: true });
  fs.writeFileSync(m.path, m.content);
}
const finish = () => {
  // The captured fixtures were scrubbed to /FIXTURE_ROOT: replay them as if the project were that root.
  if (control.stdoutFile) process.stdout.write(fs.readFileSync(control.stdoutFile, 'utf8').split('/FIXTURE_ROOT').join(fs.realpathSync(path.join(__dirname, '..', '..'))));
  if (control.stderr) process.stderr.write(control.stderr);
  process.exitCode = control.exit === undefined ? 0 : control.exit;
};
if (control.sleepMs) setTimeout(finish, control.sleepMs); else finish();
`;

// control: { stdoutFile, stderr, exit, sleepMs, mutate:[{path,content|delete}] }.
async function installStub(project, control = {}) {
  const bin = path.join(project, 'node_modules', '.bin');
  await fs.mkdir(bin, { recursive: true });
  await fs.writeFile(path.join(bin, 'playwright'), STUB, { mode: 0o755 });
  await fs.chmod(path.join(bin, 'playwright'), 0o755);
  const pkgDir = path.join(project, 'node_modules', '@playwright', 'test');
  await fs.mkdir(pkgDir, { recursive: true });
  await fs.writeFile(path.join(pkgDir, 'package.json'), JSON.stringify({ name: '@playwright/test', version: '1.64.1' }), 'utf8');
  const marker = path.join(project, '.stub-marker.jsonl');
  await setControl(project, { marker, ...control });
  return marker;
}

async function setControl(project, control) {
  const existing = existsSync(path.join(project, '.stub-control.json'))
    ? await readJson(path.join(project, '.stub-control.json')) : {};
  await fs.writeFile(path.join(project, '.stub-control.json'), JSON.stringify({ ...existing, ...control }), 'utf8');
}

async function readMarker(marker) {
  if (!existsSync(marker)) return [];
  return (await fs.readFile(marker, 'utf8')).split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

function run(args, project, env = {}) {
  let stdout = '';
  let stderr = '';
  return runCommand(args, {
    cwd: project,
    env: { ...process.env, ...env },
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
    requireCanonicalSlug: (s) => s,
  }).then((code) => ({ code, stdout, stderr }));
}

function runMain(argv, cwd) {
  let stdout = '';
  let stderr = '';
  return main(argv, {
    cwd,
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
  }).then((code) => ({ code, stdout, stderr }));
}

// DERIVED from the real report (NOT captured): drop the one failing spec, so 2 of the 3 real
// tests remain, both `expected`; stats recomputed over those 2 tests.
async function derivedAllPassReport() {
  const real = await readJson(REAL_REPORT);
  const copy = structuredClone(real);
  copy.suites[0].specs = copy.suites[0].specs.filter((spec) => spec.tests[0].status === 'expected');
  copy.stats = { ...copy.stats, expected: 2, unexpected: 0, flaky: 0, skipped: 0 };
  return copy;
}

async function writeStdout(project, name, value) {
  const file = path.join(project, name);
  await fs.writeFile(file, typeof value === 'string' ? value : JSON.stringify(value), 'utf8');
  return file;
}

const git = (cwd, ...args) => execFileSync('git', ['-c', 'user.email=t@example.com', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', ...args], { cwd, encoding: 'utf8' }).trim();

const SNAP = 'tests/visual.spec.js-snapshots';

async function createRepoWithBaselines(project) {
  git(project, 'init', '-q');
  await fs.mkdir(path.join(project, SNAP), { recursive: true });
  await fs.writeFile(path.join(project, SNAP, 'home-darwin.png'), 'PNG-A');
  await fs.writeFile(path.join(project, SNAP, 'cart-darwin.png'), 'PNG-B');
  await fs.mkdir(path.join(project, 'src'), { recursive: true });
  await fs.writeFile(path.join(project, 'src', 'app.js'), 'v1');
  await fs.writeFile(path.join(project, '.gitignore'), 'node_modules/\n.stub*\n');
  git(project, 'add', '-A');
  git(project, 'commit', '-q', '-m', 'baseline');
  return git(project, 'rev-parse', 'HEAD');
}

// ------------------------------------------------------------------ tests

test('1: no node_modules -> detect exit 2 tool_absent and run exit 2 tool_absent, nothing spawned', async (t) => {
  const project = await createProject(t);
  const detect = await run(['detect', '--json'], project);
  assert.equal(detect.code, 2);
  const doc = JSON.parse(detect.stdout);
  assert.equal(doc.schema, 'rlp-desk.visual-detect/1');
  assert.equal(doc.status, 'tool_absent');
  assert.equal(doc.playwright_version, null);
  assert.equal(doc.bin, null);

  const result = await run(['run', '--json'], project);
  assert.equal(result.code, 2);
  const out = JSON.parse(result.stdout);
  assert.equal(out.schema, 'rlp-desk.visual/1');
  assert.equal(out.status, 'tool_absent');
  assert.equal(out.exit_code, 2);

  // Half-installed (package present, .bin shim missing) is also absent: both are required.
  await fs.mkdir(path.join(project, 'node_modules', '@playwright', 'test'), { recursive: true });
  await fs.writeFile(path.join(project, 'node_modules', '@playwright', 'test', 'package.json'), '{"version":"1.64.1"}');
  const half = await run(['detect', '--json'], project);
  assert.equal(half.code, 2);
  assert.equal(JSON.parse(half.stdout).status, 'tool_absent');
});

test('2: stub installed -> detect exit 0 with version, config and bin', async (t) => {
  const project = await createProject(t);
  await installStub(project);
  await fs.writeFile(path.join(project, 'playwright.config.ts'), 'export default {};');
  const res = await run(['detect', '--json'], project);
  assert.equal(res.code, 0, res.stderr);
  assert.deepEqual(JSON.parse(res.stdout), {
    schema: 'rlp-desk.visual-detect/1',
    status: 'present',
    playwright_version: '1.64.1',
    config: 'playwright.config.ts',
    bin: 'node_modules/.bin/playwright',
    missing: [],
  });
  const text = await run(['detect'], project);
  assert.equal(text.code, 0);
  assert.match(text.stdout, /present/);

  // --project-dir is resolved against cwd.
  const other = await createProject(t);
  const viaDir = await run(['detect', '--json', '--project-dir', project], other);
  assert.equal(viaDir.code, 0);
});

test('3: all-pass (derived) -> exit 0, stats mapped, CI=1, args forwarded in order', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile, exit: 0 });
  const res = await run(['run', '--json', '--config', 'pw.config.js', '--grep', 'plain', '--', '--workers=1', '--project=chromium'], project, { CI: '' });
  assert.equal(res.code, 0, res.stderr + res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'pass');
  assert.equal(doc.reason, null);
  assert.equal(doc.playwright_version, '1.64.1');
  assert.deepEqual(doc.stats, { expected: 2, unexpected: 0, flaky: 0, skipped: 0 });
  assert.deepEqual(doc.violations, []);
  assert.deepEqual(doc.screenshot_failures, []);
  assert.equal(doc.exit_code, 0);

  const calls = await readMarker(marker);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].argv, ['test', '--reporter=json', '--config', 'pw.config.js', '--grep', 'plain', '--workers=1', '--project=chromium']);
  assert.equal(calls[0].ci, '1');
  assert.equal(realpathSync(calls[0].cwd), realpathSync(project));
});

test('4: REAL failing-screenshot report -> exit 1 with the three paths, pixel evidence and failed test', async (t) => {
  const project = await createProject(t);
  const marker = await installStub(project, { stdoutFile: REAL_REPORT, exit: 1 });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 1, res.stderr + res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'fail');
  assert.deepEqual(doc.stats, { expected: 2, unexpected: 1, flaky: 0, skipped: 0 });
  assert.equal(doc.screenshot_failures.length, 1);
  const shot = doc.screenshot_failures[0];
  assert.equal(shot.file, 'visual.spec.js');
  assert.equal(shot.title, 'screenshot differs');
  assert.equal(shot.snapshot, 'diff');
  assert.match(shot.expected, /tests\/visual\.spec\.js-snapshots\/diff-darwin\.png$/);
  assert.match(shot.actual, /test-results\/visual-screenshot-differs\/diff-actual\.png$/);
  assert.match(shot.diff, /test-results\/visual-screenshot-differs\/diff-diff\.png$/);
  assert.equal(shot.diff_pixels, 78860);
  assert.equal(shot.diff_ratio, 0.99);
  assert.deepEqual(doc.failed_tests.map((f) => `${f.file}|${f.title}`), ['visual.spec.js|screenshot differs']);
  assert.ok(!/\u001b/.test(doc.failed_tests[0].message), 'ANSI escapes stripped');
  assert.equal((await readMarker(marker)).length, 1);

  // Contract guard on the parser itself (drift detector when Playwright changes its JSON).
  const parsed = parsePlaywrightReport(await readJson(REAL_REPORT));
  assert.equal(parsed.tests.length, 3, 'tests counted over the real 3-test fixture');
  assert.deepEqual(parsed.tests.map((x) => x.status).sort(), ['expected', 'expected', 'unexpected']);
  assert.equal(parsed.screenshotFailures[0].snapshot, 'diff');
});

test('5: update/ignore-snapshots in any spelling -> exit 64, stub never invoked', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile });
  // Spellings Playwright 1.64.1's commander parser accepts for the same effect (verified against the
  // real binary: `-uall` and `-xu` rewrote baselines; `--ignore-snapshots` made a red page pass).
  const update = [
    ['--', '--update-snapshots'],
    ['--', '-u'],
    ['--', '-uall'],
    ['--', '-uchanged'],
    ['--', '-xu'],
    ['--', '-xuall'],
    ['--', '-u=all'],
    ['--', '--update-snapshots=all'],
    ['--', '--update-snapshots', 'all'],
    ['--', '--workers=1', '--update-source-method=overwrite'],
    ['--update-snapshots'],
    ['-uall'],
  ];
  for (const extra of update) {
    const res = await run(['run', '--json', ...extra], project);
    assert.equal(res.code, 64, `${extra.join(' ')}: ${res.stdout}${res.stderr}`);
    const doc = JSON.parse(res.stdout);
    assert.deepEqual(doc.violations, ['update_snapshots_flag'], extra.join(' '));
    assert.equal(doc.exit_code, 64);
  }
  for (const extra of [['--', '--ignore-snapshots'], ['--', '--ignore-snapshots=true'], ['--ignore-snapshots']]) {
    const res = await run(['run', '--json', ...extra], project);
    assert.equal(res.code, 64, extra.join(' '));
    assert.deepEqual(JSON.parse(res.stdout).violations, ['ignore_snapshots_flag'], extra.join(' '));
  }
  assert.equal(existsSync(marker), false, 'the stub must never be invoked');
});

test('5b: legitimate short options are not mistaken for -u (-x, -j1, -gplain, -xj2)', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile });
  for (const extra of [['-x'], ['-j1'], ['-gplain'], ['-xj2'], ['-g', 'unit'], ['--grep-invert=u']]) {
    const res = await run(['run', '--json', '--', ...extra], project);
    assert.equal(res.code, 0, `${extra.join(' ')}: ${res.stdout}${res.stderr}`);
  }
  assert.equal((await readMarker(marker)).length, 6);
});

test('5c: report.config.updateSnapshots all/changed -> exit 1 update_snapshots_enabled, whatever spelling caused it', async (t) => {
  const project = await createProject(t);
  const real = await readJson(REAL_REPORT);
  assert.equal(real.config.updateSnapshots, 'default', 'fixture premise: the effective mode is in report.config');
  for (const mode of ['all', 'changed']) {
    const derived = await derivedAllPassReport();
    derived.config.updateSnapshots = mode; // DERIVED: a real run with -uall / -xu reported exactly this
    const stdoutFile = await writeStdout(project, `mode-${mode}.json`, derived);
    await installStub(project, { stdoutFile });
    const res = await run(['run', '--json'], project);
    assert.equal(res.code, 1, mode);
    const doc = JSON.parse(res.stdout);
    assert.equal(doc.status, 'fail');
    assert.deepEqual(doc.violations, ['update_snapshots_enabled']);
  }
  for (const mode of ['default', 'none', 'missing']) {
    const derived = await derivedAllPassReport();
    derived.config.updateSnapshots = mode;
    await setControl(project, { stdoutFile: await writeStdout(project, `ok-${mode}.json`, derived) });
    assert.equal((await run(['run', '--json'], project)).code, 0, mode);
  }
});

test('5d: effective ignoreSnapshots=true (flag OR config; report.config.filteredProjects) -> exit 1 ignore_snapshots_enabled', async (t) => {
  const project = await createProject(t);
  const real = await readJson(REAL_REPORT);
  assert.deepEqual(real.config.filteredProjects.map((p) => p.ignoreSnapshots), [false], 'fixture premise: the effective value is in the real report');
  const derived = await derivedAllPassReport();
  derived.config.filteredProjects[0].ignoreSnapshots = true; // DERIVED: a real run with --ignore-snapshots or config ignoreSnapshots reported exactly this
  const stdoutFile = await writeStdout(project, 'report.json', derived);
  await installStub(project, { stdoutFile });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 1, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'fail');
  assert.deepEqual(doc.violations, ['ignore_snapshots_enabled']);
  // A report without the field cannot be verified: cannot judge (see 5e), never a pass.
  const missing = await derivedAllPassReport();
  delete missing.config.filteredProjects[0].ignoreSnapshots;
  await setControl(project, { stdoutFile: await writeStdout(project, 'missing.json', missing) });
  const res2 = await run(['run', '--json'], project);
  assert.equal(res2.code, 2);
  assert.equal(JSON.parse(res2.stdout).reason, 'report_incomplete');
});

test('8e: editing the Playwright config after the start sha is a violation (thresholds, snapshotPathTemplate, updateSnapshots live there)', async (t) => {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { testDir: "./tests" };\n');
  await fs.mkdir(path.join(project, 'conf'), { recursive: true });
  await fs.writeFile(path.join(project, 'conf', 'alt.config.js'), 'module.exports = {};\n');
  await fs.writeFile(path.join(project, 'helpers.js'), 'module.exports = {};\n');
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });

  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, []);

  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 1 } } };\n');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  const doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.violations, ['config_modified']);
  assert.deepEqual(doc.baseline.config_changed, ['playwright.config.js']);
  git(project, 'checkout', '--', 'playwright.config.js');

  // A config chosen with --config is guarded too, and so is the effective config named by the report.
  await fs.writeFile(path.join(project, 'conf', 'alt.config.js'), 'module.exports = { updateSnapshots: "all" };\n');
  res = await run(['run', '--json', '--baseline-ref', sha, '--config', 'conf/alt.config.js'], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['conf/alt.config.js']);
  const viaReport = await derivedAllPassReport();
  viaReport.config.configFile = path.join(project, 'conf', 'alt.config.js'); // DERIVED
  await setControl(project, { stdoutFile: await writeStdout(project, 'eff.json', viaReport) });
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['conf/alt.config.js']);
  git(project, 'checkout', '--', 'conf/alt.config.js');

  // An unlisted helper is not guarded by default; --protect extends the set.
  await setControl(project, { stdoutFile });
  await fs.writeFile(path.join(project, 'helpers.js'), 'module.exports = { changed: 1 };\n');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0);
  res = await run(['run', '--json', '--baseline-ref', sha, '--protect', 'helpers.js'], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['helpers.js']);
});

test('8f: an internal error (git breaks after the run) is exit 2 internal_error, never exit 1', async (t) => {
  const project = await createProject(t);
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile, mutate: [{ path: path.join(project, '.git', 'HEAD'), delete: true }] });
  const res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 2, res.stdout + res.stderr);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'error');
  assert.equal(doc.reason, 'internal_error');
  assert.equal(doc.exit_code, 2);
  assert.ok(doc.warnings.length > 0);
});

test('6: REAL browser-missing report (message inside the JSON, not stderr) -> exit 2 browser_missing', async (t) => {
  const project = await createProject(t);
  const realStderr = await fs.readFile(path.join(FIX, 'playwright-1.64.1-browser-missing.stderr.txt'), 'utf8');
  assert.ok(!/Executable doesn't exist/.test(realStderr), 'fixture premise: stderr carries no browser message');
  await installStub(project, { stdoutFile: REAL_BROWSER_MISSING, stderr: realStderr, exit: 1 });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 2, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'error');
  assert.equal(doc.reason, 'browser_missing');
  assert.match(doc.hint, /npx playwright install/);
  assert.equal(doc.exit_code, 2);
});

test('6b: browser-missing on stderr only (non-json reporter shape, DERIVED) -> exit 2 browser_missing', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'empty.txt', '');
  await installStub(project, { stdoutFile, stderr: "Error: browserType.launch: Executable doesn't exist at /x/chrome\n", exit: 1 });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 2);
  assert.equal(JSON.parse(res.stdout).reason, 'browser_missing');
});

test('7: zero tests is never a pass: REAL zero-tests report, plus derived skipped-only and exit-0 variants', async (t) => {
  const project = await createProject(t);
  await installStub(project, { stdoutFile: REAL_ZERO, exit: 1 });
  const real = await run(['run', '--json'], project);
  assert.equal(real.code, 2, real.stdout);
  const doc = JSON.parse(real.stdout);
  assert.equal(doc.status, 'error');
  assert.equal(doc.reason, 'no_tests');

  // DERIVED: only skipped tests, exit 0.
  const skipped = structuredClone(await readJson(REAL_ZERO));
  skipped.errors = [];
  skipped.stats = { ...skipped.stats, skipped: 3 };
  await setControl(project, { stdoutFile: await writeStdout(project, 'skipped.json', skipped), exit: 0 });
  const second = await run(['run', '--json'], project);
  assert.equal(second.code, 2);
  assert.equal(JSON.parse(second.stdout).reason, 'no_tests');

  // DERIVED: zero tests with a different top-level runner error (e.g. broken config).
  const broken = structuredClone(await readJson(REAL_ZERO));
  broken.errors = [{ message: 'Error: config exploded' }];
  await setControl(project, { stdoutFile: await writeStdout(project, 'broken.json', broken), exit: 1 });
  const third = await run(['run', '--json'], project);
  assert.equal(third.code, 2);
  const thirdDoc = JSON.parse(third.stdout);
  assert.equal(thirdDoc.reason, 'runner_error');
  assert.ok(thirdDoc.warnings.some((w) => /config exploded/.test(w)));

  // Unparseable stdout is never a pass either.
  await setControl(project, { stdoutFile: await writeStdout(project, 'junk.txt', 'not json at all'), exit: 0 });
  const fourth = await run(['run', '--json'], project);
  assert.equal(fourth.code, 2);
  assert.equal(JSON.parse(fourth.stdout).reason, 'unparseable');

  // Non-zero exit that the report cannot explain (no failures, no errors) -> cannot judge.
  await setControl(project, { stdoutFile: await writeStdout(project, 'pass.json', await derivedAllPassReport()), exit: 1 });
  const fifth = await run(['run', '--json'], project);
  assert.equal(fifth.code, 2);
  assert.equal(JSON.parse(fifth.stdout).reason, 'runner_exit_1');
});

test('7b: nested describe suites are walked (DERIVED shape from the real report)', async () => {
  const real = await readJson(REAL_REPORT);
  const nested = structuredClone(real);
  const specs = nested.suites[0].specs;
  nested.suites[0] = { ...nested.suites[0], specs: [], suites: [{ title: 'group', file: 'visual.spec.js', specs }] };
  const parsed = parsePlaywrightReport(nested);
  assert.equal(parsed.tests.length, 3);
  assert.equal(parsed.screenshotFailures.length, 1);
  assert.equal(parsed.tests.find((x) => x.status === 'unexpected').title, 'group > screenshot differs');
});

test('8: baseline guard against a temp git repo (post-run, ref vs working tree)', async (t) => {
  const project = await createProject(t);
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile, exit: 0 });

  // a. untouched baselines -> pass, empty lists.
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout + res.stderr);
  let doc = JSON.parse(res.stdout);
  assert.equal(doc.baseline.ref, sha);
  assert.equal(doc.baseline.resolved, sha);
  assert.deepEqual([doc.baseline.added, doc.baseline.modified, doc.baseline.deleted], [[], [], []]);
  assert.deepEqual(doc.violations, []);

  // b. a non-snapshot change is not a baseline change.
  await fs.writeFile(path.join(project, 'src', 'app.js'), 'v2');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0);
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, []);

  // c. only a NEW untracked baseline -> exit 0, listed under added (Verifier must review it).
  await fs.writeFile(path.join(project, SNAP, 'new-darwin.png'), 'PNG-NEW');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0);
  doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.baseline.added, [`${SNAP}/new-darwin.png`]);
  assert.equal(doc.status, 'pass');

  // d. a modified baseline (uncommitted) -> exit 1.
  await fs.writeFile(path.join(project, SNAP, 'home-darwin.png'), 'PNG-A-REGENERATED');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'fail');
  assert.deepEqual(doc.baseline.modified, [`${SNAP}/home-darwin.png`]);
  assert.deepEqual(doc.violations, ['baseline_modified']);

  // e. a deleted baseline -> exit 1; modified+deleted sorted.
  await fs.rm(path.join(project, SNAP, 'cart-darwin.png'));
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.baseline.deleted, [`${SNAP}/cart-darwin.png`]);
  assert.deepEqual(doc.violations, ['baseline_deleted', 'baseline_modified']);

  // f. committed (not just working-tree) changes after the ref are caught too.
  git(project, 'add', '-A');
  git(project, 'commit', '-q', '-m', 'regenerate baselines');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, [`${SNAP}/home-darwin.png`]);
  // ... but against the new HEAD the tree is clean again.
  res = await run(['run', '--json', '--baseline-ref', 'HEAD'], project);
  assert.equal(res.code, 0);
  assert.equal((await readMarker(marker)).length, 7, 'the guard never replaces the Playwright run');
});

test('8b: the guard is evaluated AFTER the run (a run that rewrites a baseline is caught)', async (t) => {
  const project = await createProject(t);
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, {
    stdoutFile,
    exit: 0,
    mutate: [{ path: path.join(project, SNAP, 'home-darwin.png'), content: 'REWRITTEN-BY-RUN' }],
  });
  const res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, [`${SNAP}/home-darwin.png`]);
});

test('8c: project in a repo subdirectory reports paths relative to the project; custom --snapshot-glob', async (t) => {
  const repo = await createProject(t);
  git(repo, 'init', '-q');
  const project = path.join(repo, 'web');
  await fs.mkdir(path.join(project, 'e2e', 'shots'), { recursive: true });
  await fs.writeFile(path.join(project, 'e2e', 'shots', 'a.png'), 'A');
  await fs.writeFile(path.join(repo, '.gitignore'), 'node_modules/\n.stub*\n');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'init');
  const sha = git(repo, 'rev-parse', 'HEAD');
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  await fs.writeFile(path.join(project, 'e2e', 'shots', 'a.png'), 'A2');

  // Default glob does not match e2e/shots -> not a baseline.
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0);
  // Custom glob does.
  res = await run(['run', '--json', '--baseline-ref', sha, '--snapshot-glob', 'e2e/**/*.png'], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, ['e2e/shots/a.png']);

  assert.ok(globToRegExp('**/*-snapshots/**').test('tests/x.spec.js-snapshots/a-darwin.png'));
  assert.ok(globToRegExp('**/*-snapshots/**').test('x.spec.js-snapshots/a.png'));
  assert.ok(!globToRegExp('**/*-snapshots/**').test('src/app.js'));
  assert.ok(globToRegExp('e2e/*.png').test('e2e/a.png'));
  assert.ok(!globToRegExp('e2e/*.png').test('e2e/sub/a.png'));
});

test('8d: no --baseline-ref -> baseline null with a warning; an unverifiable explicit ref -> exit 2 without running', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile });
  let res = await run(['run', '--json'], project);
  assert.equal(res.code, 0);
  let doc = JSON.parse(res.stdout);
  assert.equal(doc.baseline, null);
  assert.ok(doc.warnings.some((w) => /baseline/i.test(w) && /--baseline-ref/.test(w)), JSON.stringify(doc.warnings));
  assert.equal((await readMarker(marker)).length, 1);

  // Explicit ref, but the project is not a git repository: a configured guard that cannot run.
  res = await run(['run', '--json', '--baseline-ref', 'abc1234'], project);
  assert.equal(res.code, 2);
  doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'error');
  assert.equal(doc.reason, 'baseline_unverifiable');
  assert.equal((await readMarker(marker)).length, 1, 'Playwright must not run after an unverifiable guard');

  // Explicit ref that does not resolve inside a real repo; and an option-looking ref.
  await createRepoWithBaselines(project);
  res = await run(['run', '--json', '--baseline-ref', 'does-not-exist'], project);
  assert.equal(res.code, 2);
  assert.equal(JSON.parse(res.stdout).reason, 'baseline_unverifiable');
  res = await run(['run', '--json', '--baseline-ref', '--output=/etc/x'], project);
  assert.equal(res.code, 64);
});

test('5e: an incomplete or inconsistent report is cannot-judge (exit 2), never a pass', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'ok.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  const cases = [
    ['no effective updateSnapshots', (r) => { delete r.config.updateSnapshots; }, 'report_incomplete'],
    ['no filteredProjects', (r) => { delete r.config.filteredProjects; }, 'report_incomplete'],
    ['empty filteredProjects', (r) => { r.config.filteredProjects = []; }, 'report_incomplete'],
    ['ignoreSnapshots field missing', (r) => { delete r.config.filteredProjects[0].ignoreSnapshots; }, 'report_incomplete'],
    ['no config at all', (r) => { delete r.config; }, 'report_incomplete'],
    // DERIVED: all suites removed while stats still claim 2 expected tests.
    ['suites removed, stats.expected > 0', (r) => { r.suites = []; }, 'report_inconsistent'],
    ['stats.expected inflated', (r) => { r.stats.expected = 5; }, 'report_inconsistent'],
    ['stats.unexpected understated', (r) => { r.suites[0].specs[0].tests[0].status = 'unexpected'; }, 'report_inconsistent'],
  ];
  for (const [label, mutate, reason] of cases) {
    const derived = await derivedAllPassReport();
    mutate(derived);
    await setControl(project, { stdoutFile: await writeStdout(project, 'case.json', derived) });
    const res = await run(['run', '--json'], project);
    assert.equal(res.code, 2, `${label}: ${res.stdout}`);
    const doc = JSON.parse(res.stdout);
    assert.equal(doc.status, 'error', label);
    assert.equal(doc.reason, reason, label);
  }
  // Control: the unmodified derived report passes.
  await setControl(project, { stdoutFile });
  assert.equal((await run(['run', '--json'], project)).code, 0);
});

test('5f: skipped tests are a violation (a skipped screenshot test verified nothing)', async (t) => {
  const project = await createProject(t);
  const derived = await derivedAllPassReport();
  // DERIVED: one of the two remaining tests is skipped (test.skip in a spec).
  derived.suites[0].specs[1].tests[0].status = 'skipped';
  derived.stats = { ...derived.stats, expected: 1, skipped: 1 };
  const stdoutFile = await writeStdout(project, 'skipped.json', derived);
  await installStub(project, { stdoutFile });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 1, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'fail');
  assert.deepEqual(doc.violations, ['tests_skipped']);
  assert.deepEqual(doc.stats, { expected: 1, unexpected: 0, flaky: 0, skipped: 1 });
});

test('8g: a git-IGNORED higher-precedence config or baseline is still seen (checked without ignore rules)', async (t) => {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { testDir: "./tests" };\n');
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  const exclude = path.join(project, '.git', 'info', 'exclude');

  // Playwright picks playwright.config.ts before .js; hide the new one from git.
  await fs.writeFile(path.join(project, 'playwright.config.ts'), 'export default { expect: { toHaveScreenshot: { maxDiffPixelRatio: 1 } } };\n');
  await fs.appendFile(exclude, 'playwright.config.ts\n');
  assert.equal(git(project, 'status', '--porcelain', '--', 'playwright.config.ts'), '', 'premise: git status cannot see the file');
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  let doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.violations, ['config_modified']);
  assert.deepEqual(doc.baseline.config_changed, ['playwright.config.ts']);
  await fs.rm(path.join(project, 'playwright.config.ts'));

  // The effective config named by the report is ignored AND untracked at the ref.
  await fs.writeFile(path.join(project, 'hidden.config.js'), 'module.exports = {};\n');
  await fs.appendFile(exclude, 'hidden.config.js\n');
  const viaReport = await derivedAllPassReport();
  viaReport.config.configFile = path.join(project, 'hidden.config.js'); // DERIVED
  await setControl(project, { stdoutFile: await writeStdout(project, 'eff.json', viaReport) });
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['hidden.config.js']);
  await setControl(project, { stdoutFile });
  await fs.rm(path.join(project, 'hidden.config.js'));

  // An ignored NEW baseline image appears under baseline.added; an ignored file matching --protect is a config change.
  await fs.writeFile(path.join(project, SNAP, 'ghost-darwin.png'), 'GHOST');
  await fs.appendFile(exclude, 'ghost-darwin.png\n');
  await fs.mkdir(path.join(project, 'private-specs'), { recursive: true });
  await fs.writeFile(path.join(project, 'private-specs', 'a.spec.js'), 'x');
  await fs.appendFile(exclude, 'private-specs/\n');
  res = await run(['run', '--json', '--baseline-ref', sha, '--protect', 'private-specs/**'], project);
  assert.equal(res.code, 1, res.stdout);
  doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.baseline.added, [`${SNAP}/ghost-darwin.png`]);
  assert.deepEqual(doc.baseline.config_changed, ['private-specs/a.spec.js']);

  // Control: with nothing hidden or changed the run passes (no false positive from ignored node_modules).
  await fs.rm(path.join(project, SNAP, 'ghost-darwin.png'));
  await fs.rm(path.join(project, 'private-specs'), { recursive: true });
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
});

test('8h: config symlinks: retargeting a tracked link is caught; configs outside the repo are cannot-judge; in-repo configs above the project dir are guarded', async (t) => {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, 'strict.config.js'), 'module.exports = {};\n');
  await fs.writeFile(path.join(project, 'permissive.config.js'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 1 } } };\n');
  await fs.symlink('strict.config.js', path.join(project, 'playwright.config.js'));
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });

  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, `unchanged symlink is not a change: ${res.stdout}`);

  // Retarget to an already-committed permissive config: neither file content changed.
  await fs.rm(path.join(project, 'playwright.config.js'));
  await fs.symlink('permissive.config.js', path.join(project, 'playwright.config.js'));
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['playwright.config.js']);
  git(project, 'checkout', '--', 'playwright.config.js');

  // A config outside the repository cannot be diffed against the ref.
  const outside = await createProject(t);
  await fs.writeFile(path.join(outside, 'outside.config.js'), 'module.exports = {};\n');
  res = await run(['run', '--json', '--baseline-ref', sha, '--config', path.join(outside, 'outside.config.js')], project);
  assert.equal(res.code, 2, res.stdout);
  let doc = JSON.parse(res.stdout);
  assert.equal(doc.reason, 'config_unverifiable');
  assert.ok(doc.warnings.some((w) => w.includes('outside.config.js')));
  const viaReport = await derivedAllPassReport();
  viaReport.config.configFile = path.join(outside, 'outside.config.js'); // DERIVED
  await setControl(project, { stdoutFile: await writeStdout(project, 'eff.json', viaReport) });
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 2);
  assert.equal(JSON.parse(res.stdout).reason, 'config_unverifiable');
  // A symlink whose target is outside the repo is cannot-judge too.
  await setControl(project, { stdoutFile });
  await fs.rm(path.join(project, 'playwright.config.js'));
  await fs.symlink(path.join(outside, 'outside.config.js'), path.join(project, 'playwright.config.js'));
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 2, res.stdout);
  assert.equal(JSON.parse(res.stdout).reason, 'config_unverifiable');
  git(project, 'checkout', '--', 'playwright.config.js');

  // Project in a repo subdirectory; the config lives at the repo root (above the project dir).
  const repo = await createProject(t);
  git(repo, 'init', '-q');
  const sub = path.join(repo, 'web');
  await fs.mkdir(sub, { recursive: true });
  await fs.writeFile(path.join(repo, 'root.config.js'), 'module.exports = {};\n');
  await fs.writeFile(path.join(repo, '.gitignore'), 'node_modules/\n.stub*\n');
  await fs.writeFile(path.join(sub, 'keep.txt'), 'x');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'init');
  const sha2 = git(repo, 'rev-parse', 'HEAD');
  await installStub(sub, { stdoutFile: await writeStdout(sub, 'report.json', await derivedAllPassReport()) });
  res = await run(['run', '--json', '--baseline-ref', sha2, '--config', '../root.config.js'], sub);
  assert.equal(res.code, 0, res.stdout);
  await fs.writeFile(path.join(repo, 'root.config.js'), 'module.exports = { loosened: true };\n');
  res = await run(['run', '--json', '--baseline-ref', sha2, '--config', '../root.config.js'], sub);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['../root.config.js']);
});

test('5g: expected-failure annotations (test.fail) are a violation; a missing expectedStatus is incomplete', async (t) => {
  const project = await createProject(t);
  const real = await readJson(REAL_REPORT);
  assert.deepEqual(real.suites[0].specs.map((s) => s.tests[0].expectedStatus), ['passed', 'passed', 'passed'], 'fixture premise: expectedStatus is in the report');
  const derived = await derivedAllPassReport();
  // DERIVED: a test.fail() test that fails as annotated is reported status "expected" with expectedStatus "failed".
  derived.suites[0].specs[0].tests[0].expectedStatus = 'failed';
  derived.suites[0].specs[0].tests[0].results[0].status = 'failed';
  const stdoutFile = await writeStdout(project, 'xfail.json', derived);
  await installStub(project, { stdoutFile });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 1, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'fail');
  assert.deepEqual(doc.violations, ['expected_failure']);
  assert.equal(doc.stats.expected, 2, 'the wrapper must not present it as a plain pass');

  const missing = await derivedAllPassReport();
  delete missing.suites[0].specs[0].tests[0].expectedStatus;
  await setControl(project, { stdoutFile: await writeStdout(project, 'noexp.json', missing) });
  const res2 = await run(['run', '--json'], project);
  assert.equal(res2.code, 2);
  assert.equal(JSON.parse(res2.stdout).reason, 'report_incomplete');
});

test('5h: a counted test without results is incomplete evidence (exit 2)', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'ok.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  for (const [label, mutate] of [
    ['empty results', (r) => { r.suites[0].specs[0].tests[0].results = []; }],
    ['absent results', (r) => { delete r.suites[0].specs[0].tests[0].results; }],
  ]) {
    const derived = await derivedAllPassReport();
    mutate(derived);
    await setControl(project, { stdoutFile: await writeStdout(project, 'case.json', derived) });
    const res = await run(['run', '--json'], project);
    assert.equal(res.code, 2, `${label}: ${res.stdout}`);
    assert.equal(JSON.parse(res.stdout).reason, 'report_incomplete', label);
  }
});

// Shared setup for the git-metadata attack tests: a committed strict config and baseline image.
async function attackRepo(t) {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 0 } } };\n');
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const marker = await installStub(project, { stdoutFile });
  return { project, sha, marker };
}

test('8i: `git replace` of the start sha does not hide a modified config or baseline', async (t) => {
  const { project, sha } = await attackRepo(t);
  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 1 } } };\n');
  await fs.writeFile(path.join(project, SNAP, 'home-darwin.png'), 'REGENERATED');
  git(project, 'add', '-A');
  git(project, 'commit', '-q', '-m', 'worker');
  const forged = git(project, 'commit-tree', git(project, 'rev-parse', 'HEAD^{tree}'), '-m', 'forged');
  git(project, 'replace', sha, forged);
  assert.equal(git(project, 'diff', '--name-only', sha), '', 'premise: with the replacement active, plain git diff sees nothing');
  const res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.violations, ['baseline_modified', 'config_modified']);
});

test('8j: skip-worktree / assume-unchanged on a guarded path is cannot-judge (exit 2)', async (t) => {
  for (const flag of ['--skip-worktree', '--assume-unchanged']) {
    const { project, sha } = await attackRepo(t);
    const target = flag === '--skip-worktree' ? `${SNAP}/home-darwin.png` : 'playwright.config.js';
    git(project, 'update-index', flag, target);
    await fs.writeFile(path.join(project, target), 'TAMPERED');
    assert.equal(git(project, 'status', '--porcelain', '--', target), '', `premise: git status cannot see the change (${flag})`);
    const res = await run(['run', '--json', '--baseline-ref', sha], project);
    assert.equal(res.code, 2, `${flag}: ${res.stdout}`);
    const doc = JSON.parse(res.stdout);
    assert.equal(doc.reason, 'index_flags_unverifiable', flag);
    assert.ok(doc.warnings.some((w) => w.includes(target)), flag);
  }
});

test('8k: a clean filter on a guarded path (via .git/info/attributes) is cannot-judge (exit 2)', async (t) => {
  const { project, sha } = await attackRepo(t);
  const original = await createProject(t);
  await fs.writeFile(path.join(original, 'orig.txt'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 0 } } };\n');
  git(project, 'config', 'filter.fake.clean', `cat ${path.join(original, 'orig.txt')}`);
  await fs.appendFile(path.join(project, '.git', 'info', 'attributes'), 'playwright.config.js filter=fake\n');
  await fs.writeFile(path.join(project, 'playwright.config.js'), 'module.exports = { expect: { toHaveScreenshot: { maxDiffPixelRatio: 1 } } };\n');
  assert.equal(git(project, 'status', '--porcelain', '--', 'playwright.config.js'), '', 'premise: the clean filter hides the edit from git');
  const res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 2, res.stdout);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.reason, 'filter_unverifiable');
  assert.ok(doc.warnings.some((w) => w.includes('playwright.config.js')));
});

test('8l: tens of thousands of git-ignored files (.venv, .next) are neither walked nor capped', async (t) => {
  const { project, sha } = await attackRepo(t);
  await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), '.venv/\n');
  for (let d = 0; d < 25; d += 1) {
    const dir = path.join(project, '.venv', `d${d}`);
    await fs.mkdir(dir, { recursive: true });
    await Promise.all(Array.from({ length: 1000 }, (_, i) => fs.writeFile(path.join(dir, `f${i}.txt`), 'x')));
  }
  const res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.added, []);
});

test('8m: every symlink hop and every symlinked ancestor of a guarded config is compared', async (t) => {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, 'strict.config.js'), 'module.exports = {};\n');
  await fs.writeFile(path.join(project, 'permissive.config.js'), 'module.exports = { loose: true };\n');
  await fs.symlink('strict.config.js', path.join(project, 'active.config.js'));
  await fs.symlink('active.config.js', path.join(project, 'playwright.config.js'));
  await fs.mkdir(path.join(project, 'configs'), { recursive: true });
  await fs.mkdir(path.join(project, 'legacy'), { recursive: true });
  await fs.mkdir(path.join(project, 'real'), { recursive: true });
  await fs.writeFile(path.join(project, 'configs', 'pw.config.js'), 'module.exports = {};\n');
  await fs.writeFile(path.join(project, 'legacy', 'pw.config.js'), 'module.exports = { loose: true };\n');
  await fs.writeFile(path.join(project, 'real', 'pw.config.js'), 'module.exports = {};\n');
  await fs.symlink('real', path.join(project, 'lib'));
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });

  // Controls: untouched chain, and a legitimately committed symlinked directory.
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
  res = await run(['run', '--json', '--baseline-ref', sha, '--config', 'lib/pw.config.js'], project);
  assert.equal(res.code, 0, `a committed, unchanged symlinked dir is not a change: ${res.stdout}`);

  // Intermediate hop retargeted (playwright.config.js -> active.config.js -> strict.config.js).
  await fs.rm(path.join(project, 'active.config.js'));
  await fs.symlink('permissive.config.js', path.join(project, 'active.config.js'));
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['active.config.js']);
  git(project, 'checkout', '--', 'active.config.js');

  // A parent directory of --config swapped for a symlink to a committed permissive directory.
  await fs.rm(path.join(project, 'configs'), { recursive: true });
  await fs.symlink('legacy', path.join(project, 'configs'));
  res = await run(['run', '--json', '--baseline-ref', sha, '--config', 'configs/pw.config.js'], project);
  assert.equal(res.code, 1, res.stdout);
  assert.ok(JSON.parse(res.stdout).baseline.config_changed.includes('configs'));
});

test('8n: guarded files are compared as raw bytes (end-of-line normalization cannot hide an edit)', async (t) => {
  const project = await createProject(t);
  await fs.writeFile(path.join(project, '.gitattributes'), '*.png text eol=lf\n');
  await fs.mkdir(path.join(project, SNAP), { recursive: true });
  await fs.writeFile(path.join(project, SNAP, 'home-darwin.png'), 'a\nb\n');
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
  await fs.writeFile(path.join(project, SNAP, 'home-darwin.png'), 'a\r\nb\r\n');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, [`${SNAP}/home-darwin.png`]);
});

test('5i: result records are validated: invalid statuses are incomplete, inconsistent outcomes are cannot-judge, retries are understood', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'ok.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  const cases = [
    // DERIVED from the real report (the codex B-C2-04 mock cases and neighbours).
    ['results [{}]', (r) => { r.suites[0].specs[0].tests[0].results = [{}]; }, 2, 'report_incomplete'],
    ['unknown result status', (r) => { r.suites[0].specs[0].tests[0].results[0].status = 'banana'; }, 2, 'report_incomplete'],
    ['failed record, test says expected/passed', (r) => { r.suites[0].specs[0].tests[0].results = [{ status: 'failed', retry: 0, errors: [] }]; }, 2, 'report_inconsistent'],
    ['unexpected test whose final result passed', (r) => {
      const test = r.suites[0].specs[0].tests[0];
      test.status = 'unexpected';
      r.stats = { ...r.stats, expected: 1, unexpected: 1 };
    }, 2, 'report_inconsistent'],
    ['flaky test without any failed attempt', (r) => {
      r.suites[0].specs[0].tests[0].status = 'flaky';
      r.stats = { ...r.stats, expected: 1, flaky: 1 };
    }, 2, 'report_inconsistent'],
    ['expected-failure test whose final result passed', (r) => { r.suites[0].specs[0].tests[0].expectedStatus = 'failed'; }, 2, 'report_inconsistent'],
  ];
  for (const [label, mutate, code, reason] of cases) {
    const derived = await derivedAllPassReport();
    mutate(derived);
    await setControl(project, { stdoutFile: await writeStdout(project, 'case.json', derived) });
    const res = await run(['run', '--json'], project);
    assert.equal(res.code, code, `${label}: ${res.stdout}`);
    assert.equal(JSON.parse(res.stdout).reason, reason, label);
  }
  // A genuine flaky test (failed attempt, then passed on retry) is consistent: pass with a warning.
  const flaky = await derivedAllPassReport();
  const first = flaky.suites[0].specs[0].tests[0];
  first.status = 'flaky';
  first.results = [{ ...first.results[0], status: 'failed', retry: 0 }, { ...first.results[0], status: 'passed', retry: 1 }];
  flaky.stats = { ...flaky.stats, expected: 1, flaky: 1 };
  await setControl(project, { stdoutFile: await writeStdout(project, 'flaky.json', flaky) });
  const res = await run(['run', '--json'], project);
  assert.equal(res.code, 0, res.stdout);
  assert.ok(JSON.parse(res.stdout).warnings.some((w) => /flaky/.test(w)));
  // A genuine test.fail() (failed final result, expectedStatus failed) is consistent and a violation.
  const xfail = await derivedAllPassReport();
  const t0 = xfail.suites[0].specs[0].tests[0];
  t0.expectedStatus = 'failed';
  t0.results = [{ ...t0.results[0], status: 'failed', retry: 0 }];
  await setControl(project, { stdoutFile: await writeStdout(project, 'xfail.json', xfail) });
  const res2 = await run(['run', '--json'], project);
  assert.equal(res2.code, 1, res2.stdout);
  assert.deepEqual(JSON.parse(res2.stdout).violations, ['expected_failure']);
});

test('8o: symlinked / nested-repo / swapped snapshot directories cannot hide baselines', async (t) => {
  // (a) a new untracked snapshot directory that is a symlink to a directory elsewhere in the repo
  {
    const { project, sha } = await attackRepo(t);
    await fs.mkdir(path.join(project, 'stash'));
    await fs.writeFile(path.join(project, 'stash', 'new-chromium-darwin.png'), 'N');
    await fs.symlink('../stash', path.join(project, 'tests', 'b.spec.js-snapshots'));
    const res = await run(['run', '--json', '--baseline-ref', sha], project);
    assert.equal(res.code, 0, res.stdout);
    assert.ok(JSON.parse(res.stdout).baseline.added.includes('tests/b.spec.js-snapshots/new-chromium-darwin.png'), res.stdout);
  }
  // (b) a tracked snapshot directory replaced by a symlink to a copy with an extra image
  {
    const { project, sha } = await attackRepo(t);
    await fs.mkdir(path.join(project, 'stash'));
    await fs.writeFile(path.join(project, 'stash', 'home-darwin.png'), 'PNG-A');
    await fs.writeFile(path.join(project, 'stash', 'cart-darwin.png'), 'PNG-B');
    await fs.writeFile(path.join(project, 'stash', 'new-chromium-darwin.png'), 'N');
    await fs.rm(path.join(project, SNAP), { recursive: true });
    await fs.symlink('../stash', path.join(project, SNAP));
    const res = await run(['run', '--json', '--baseline-ref', sha], project);
    assert.equal(res.code, 1, res.stdout);
    const doc = JSON.parse(res.stdout);
    assert.ok(doc.baseline.modified.includes(`${SNAP}/home-darwin.png`), 'tracked images are no longer regular files under a real directory');
    assert.ok(doc.baseline.added.includes(`${SNAP}/new-chromium-darwin.png`), res.stdout);
  }
  // (c) a new snapshot directory that is a nested git repository
  {
    const { project, sha } = await attackRepo(t);
    const nested = path.join(project, 'tests', 'c.spec.js-snapshots');
    await fs.mkdir(nested);
    await fs.writeFile(path.join(nested, 'new-chromium-darwin.png'), 'N');
    git(nested, 'init', '-q', '.');
    const res = await run(['run', '--json', '--baseline-ref', sha], project);
    assert.equal(res.code, 0, res.stdout);
    assert.ok(JSON.parse(res.stdout).baseline.added.includes('tests/c.spec.js-snapshots/new-chromium-darwin.png'), res.stdout);
  }
  // (d) a custom glob that does not end in /** still sees through a symlinked directory
  {
    const { project, sha } = await attackRepo(t);
    await fs.mkdir(path.join(project, 'stash'));
    await fs.writeFile(path.join(project, 'stash', 'extra.png'), 'N');
    await fs.symlink('stash', path.join(project, 'shots'));
    const res = await run(['run', '--json', '--baseline-ref', sha, '--snapshot-glob', 'shots/*.png'], project);
    assert.equal(res.code, 0, res.stdout);
    assert.deepEqual(JSON.parse(res.stdout).baseline.added, ['shots/extra.png']);
  }
});

test('8p: --protect globs with a ** that is not slash-bounded see new files too', async (t) => {
  const { project, sha } = await attackRepo(t);
  await fs.mkdir(path.join(project, 'specs', 'sub'), { recursive: true });
  await fs.writeFile(path.join(project, 'specs', 'sub', 'a.spec.js'), 'x');
  git(project, 'add', '-A');
  git(project, 'commit', '-q', '-m', 'specs');
  const sha2 = git(project, 'rev-parse', 'HEAD');
  await fs.writeFile(path.join(project, 'specs', 'sub', 'new.spec.js'), 'y');
  const res = await run(['run', '--json', '--baseline-ref', sha2, '--protect', 'specs/**.spec.js'], project);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['specs/sub/new.spec.js']);
  assert.equal(sha.length, 40);
  // A new file inside a git-IGNORED directory (collapsed by git, so only the pathspec can find it): git's :(glob)
  // would read `specs/**.spec.js` as [^/]* segments and miss specs/hidden/deep/new.spec.js.
  await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), 'specs/hidden/\n');
  await fs.mkdir(path.join(project, 'specs', 'hidden', 'deep'), { recursive: true });
  await fs.writeFile(path.join(project, 'specs', 'hidden', 'deep', 'new.spec.js'), 'z');
  const res2 = await run(['run', '--json', '--baseline-ref', sha2, '--protect', 'specs/**.spec.js'], project);
  assert.deepEqual(JSON.parse(res2.stdout).baseline.config_changed, ['specs/hidden/deep/new.spec.js', 'specs/sub/new.spec.js']);
});

test('8q: a directory symlink hop (configs -> active -> strict) is compared at every hop', async (t) => {
  const project = await createProject(t);
  for (const dir of ['strict', 'loose']) {
    await fs.mkdir(path.join(project, dir));
    await fs.writeFile(path.join(project, dir, 'pw.config.js'), dir === 'strict' ? 'module.exports = {};\n' : 'module.exports = { loose: true };\n');
  }
  await fs.symlink('strict', path.join(project, 'active'));
  await fs.symlink('active', path.join(project, 'configs'));
  const sha = await createRepoWithBaselines(project);
  await installStub(project, { stdoutFile: await writeStdout(project, 'report.json', await derivedAllPassReport()) });
  let res = await run(['run', '--json', '--baseline-ref', sha, '--config', 'configs/pw.config.js'], project);
  assert.equal(res.code, 0, `control: ${res.stdout}`);
  await fs.rm(path.join(project, 'active'));
  await fs.symlink('loose', path.join(project, 'active'));
  res = await run(['run', '--json', '--baseline-ref', sha, '--config', 'configs/pw.config.js'], project);
  assert.equal(res.code, 1, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.config_changed, ['active']);
  assert.deepEqual(JSON.parse(res.stdout).violations, ['config_modified']);
});

// Reviewer scenarios from r5-default-probe.mjs / r5-visual-probe.mjs / r5-tracked-probe.mjs, plus codex B-C5-01.
async function writeMany(dir, count, ext = 'js') {
  await fs.mkdir(dir, { recursive: true });
  for (let start = 0; start < count; start += 1000) {
    await Promise.all(Array.from({ length: Math.min(1000, count - start) }, (_, i) => fs.writeFile(path.join(dir, `f${start + i}.${ext}`), '')));
  }
}

test('8r: ignored linked worktrees unrelated to snapshots are not walked (D0/D1/D2)', async (t) => {
  for (const [label, count] of [['D0 no worktree', -1], ['D1 small ignored worktree', 0], ['D2 ignored worktree with 20001 build files', 20001]]) {
    const { project, sha } = await attackRepo(t);
    await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), '.claude/\n');
    if (count >= 0) {
      git(project, 'worktree', 'add', '-q', path.join(project, '.claude', 'worktrees', 'agent-x'));
      if (count > 0) await writeMany(path.join(project, '.claude', 'worktrees', 'agent-x', 'dist'), count);
    }
    const res = await run(['run', '--json', '--baseline-ref', sha], project);
    assert.equal(res.code, 0, `${label}: ${res.stdout}`);
    assert.deepEqual(JSON.parse(res.stdout).baseline.added, [], label);
  }
});

test('8s: ignored nested repos / worktrees with a --protect glob that does not end in /** add nothing false (A1/A2/A3)', async (t) => {
  for (const [label, protect, setup] of [
    ['A1 ignored nested repo with its own snapshots', 'helpers/*.js', async (project) => {
      await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), 'vendor/\n');
      const lib = path.join(project, 'vendor', 'lib', 'tests', 'z.spec.js-snapshots');
      await fs.mkdir(lib, { recursive: true });
      await fs.writeFile(path.join(lib, 'q.png'), 'v');
      git(path.join(project, 'vendor', 'lib'), 'init', '-q', '.');
    }],
    ['A2 ignored linked worktree', 'helpers/*.js', async (project) => {
      await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), '.claude/\n');
      git(project, 'worktree', 'add', '-q', path.join(project, '.claude', 'worktrees', 'agent-x'));
    }],
    ['A3 ignored linked worktree, protect ends in /**', 'helpers/**', async (project) => {
      await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), '.claude/\n');
      git(project, 'worktree', 'add', '-q', path.join(project, '.claude', 'worktrees', 'agent-x'));
    }],
  ]) {
    const { project, sha } = await attackRepo(t);
    await setup(project);
    const res = await run(['run', '--json', '--baseline-ref', sha, '--protect', protect], project);
    assert.equal(res.code, 0, `${label}: ${res.stdout}`);
    const doc = JSON.parse(res.stdout);
    assert.deepEqual(doc.baseline.added, [], label);
    assert.deepEqual(doc.baseline.config_changed, [], label);
  }
});

test('8t: an unrelated symlinked directory with more than 20000 files does not break a scoped gate (C0/C1, codex B-C5-01)', async (t) => {
  const { project, sha } = await attackRepo(t);
  await fs.appendFile(path.join(project, '.git', 'info', 'exclude'), 'bigsrc/\nbig\nlink\n');
  await writeMany(path.join(project, 'bigsrc'), 20005, 'py');
  await fs.symlink('bigsrc', path.join(project, 'big'));
  await fs.symlink('bigsrc', path.join(project, 'link'));
  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, `C0 default glob: ${res.stdout}`);
  res = await run(['run', '--json', '--baseline-ref', sha, '--protect', 'helpers/*.js'], project);
  assert.equal(res.code, 0, `C1 --protect helpers/*.js: ${res.stdout}`);
  res = await run(['run', '--json', '--baseline-ref', sha, '--snapshot-glob', 'tests/*-snapshots/**', '--protect', 'tests/*.spec.ts'], project);
  assert.equal(res.code, 0, `codex B-C5-01: ${res.stdout}`);
  assert.deepEqual(JSON.parse(res.stdout).baseline.added, []);
  // Control: the same large directory IS walked (and reported unverifiable) when a glob can lead into it.
  res = await run(['run', '--json', '--baseline-ref', sha, '--snapshot-glob', 'big/*.py'], project);
  assert.equal(res.code, 2, res.stdout);
  assert.equal(JSON.parse(res.stdout).reason, 'snapshot_dir_unverifiable');
});

test('8u: a committed, tracked symlinked snapshot directory is compared at its real paths (T1/T2)', async (t) => {
  const project = await createProject(t);
  await fs.mkdir(path.join(project, 'shared', 'b-snaps'), { recursive: true });
  await fs.writeFile(path.join(project, 'shared', 'b-snaps', 'y-chromium-darwin.png'), 'Y');
  await fs.mkdir(path.join(project, 'tests'), { recursive: true });
  await fs.symlink('../shared/b-snaps', path.join(project, 'tests', 'b.spec.js-snapshots'));
  const sha = await createRepoWithBaselines(project);
  await installStub(project, { stdoutFile: await writeStdout(project, 'report.json', await derivedAllPassReport()) });
  const link = 'tests/b.spec.js-snapshots';

  let res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, `T1: ${res.stdout}`);
  assert.deepEqual(JSON.parse(res.stdout).baseline.added, [], 'T1: unchanged files behind a committed link are not "added"');
  assert.deepEqual(JSON.parse(res.stdout).baseline.modified, []);

  await fs.writeFile(path.join(project, 'shared', 'b-snaps', 'y-chromium-darwin.png'), 'REGENERATED');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, `T2: ${res.stdout}`);
  let doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.violations, ['baseline_modified']);
  assert.deepEqual(doc.baseline.modified, [`${link}/y-chromium-darwin.png`]);
  assert.deepEqual(doc.baseline.added, []);

  // A new image dropped into the real target directory is added; a retargeted link is a modified baseline.
  await fs.writeFile(path.join(project, 'shared', 'b-snaps', 'y-chromium-darwin.png'), 'Y');
  await fs.writeFile(path.join(project, 'shared', 'b-snaps', 'new-chromium-darwin.png'), 'N');
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 0, res.stdout);
  assert.deepEqual(JSON.parse(res.stdout).baseline.added, [`${link}/new-chromium-darwin.png`]);
  await fs.rm(path.join(project, 'shared', 'b-snaps', 'new-chromium-darwin.png'));
  await fs.mkdir(path.join(project, 'shared', 'other'), { recursive: true });
  await fs.writeFile(path.join(project, 'shared', 'other', 'y-chromium-darwin.png'), 'Y');
  await fs.rm(path.join(project, link));
  await fs.symlink('../shared/other', path.join(project, link));
  res = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(res.code, 1, res.stdout);
  doc = JSON.parse(res.stdout);
  assert.ok(doc.baseline.modified.includes(link), JSON.stringify(doc.baseline));
});

test('9: timeout -> exit 2 reason timeout, the whole child process tree killed (load independent)', async (t) => {
  const project = await createProject(t);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  const pidFile = path.join(project, 'stub.pid');
  const grandchildPidFile = path.join(project, 'grandchild.pid');
  await installStub(project, { stdoutFile, sleepMs: 120000, pidFile, grandchildPidFile });
  // The wrapper's clock starts at spawn, so the timeout must be far larger than node's startup time on a loaded
  // machine; the stub then sleeps far longer than the timeout, so only the kill can end it.
  const started = Date.now();
  const res = await run(['run', '--json', '--timeout', '8'], project);
  assert.equal(res.code, 2, res.stdout);
  assert.ok(Date.now() - started < 60000, 'returned long before the stub would have finished');
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.status, 'error');
  assert.equal(doc.reason, 'timeout');
  const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== 'ESRCH'; } };
  for (const file of [pidFile, grandchildPidFile]) {
    assert.ok(existsSync(file), `${path.basename(file)} must exist: the stub started before the timeout fired (timeout 8 s)`);
    const pid = Number(await fs.readFile(file, 'utf8'));
    for (let i = 0; i < 50 && alive(pid); i += 1) await new Promise((r) => setTimeout(r, 100));
    assert.equal(alive(pid), false, `${path.basename(file)} process ${pid} is gone`);
  }

  for (const bad of ['0', '-1', 'abc', '']) {
    const usage = await run(['run', '--timeout', bad], project);
    assert.equal(usage.code, 64, `--timeout ${JSON.stringify(bad)}`);
  }
});

test('10: --json is deterministic; text output states the status; dispatch and help list visual', async (t) => {
  const project = await createProject(t);
  const sha = await createRepoWithBaselines(project);
  const stdoutFile = await writeStdout(project, 'report.json', await derivedAllPassReport());
  await installStub(project, { stdoutFile });
  const first = await run(['run', '--json', '--baseline-ref', sha], project);
  const second = await run(['run', '--json', '--baseline-ref', sha], project);
  assert.equal(first.stdout, second.stdout);
  const doc = JSON.parse(first.stdout);
  assert.deepEqual(Object.keys(doc), [...Object.keys(doc)].sort(), 'keys sorted');
  assert.equal(doc.schema, 'rlp-desk.visual/1');
  assert.ok(!/startTime|duration|timestamp/i.test(first.stdout), 'no clocks in the output');

  const text = await run(['run', '--baseline-ref', sha], project);
  assert.equal(text.code, 0);
  assert.match(text.stdout.split('\n')[0], /^visual run: pass/);

  assert.match((await runMain(["--help"], project)).stdout, /^  visual <detect\|run>/m);
  const help = await runMain(['visual', '--help'], project);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /visual <detect\|run>/);
  assert.match(help.stdout, /--baseline-ref/);
  const viaMain = await runMain(['visual', 'detect', '--json'], project);
  assert.equal(viaMain.code, 0);
  assert.equal(JSON.parse(viaMain.stdout).status, 'present');
  const unknown = await runMain(['visual', 'bogus'], project);
  assert.equal(unknown.code, 64);
  const unknownOpt = await runMain(['visual', 'run', '--nope'], project);
  assert.equal(unknownOpt.code, 64);
});
