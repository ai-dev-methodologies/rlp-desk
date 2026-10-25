import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import {
  MUTATION_SCHEMA,
  computeScore,
  parseStrykerReport,
  parseMutmutCicdStats,
  parseMutmutResults,
  totalsFromMutmutRows,
  parseGoMutestingReport,
  filesOutsideTarget,
  validatePassthrough,
  runCommand,
} from '../../src/node/tools/mutation.mjs';
import { writeFileSafely, writeGuardedOut } from '../../src/node/util/out-path-guard.mjs';

// D4 (TODO L58-59) - mutation tool wrappers. Design:
// .omc/artifacts/backlog-2026-10-25/d-roadmap-design.md D4. Parsers are built
// against REAL captures in tests/fixtures/mutation/ (see w2-fixtures.md). Where a
// status is not in any real capture, the test says "DERIVED" and edits a copy of
// a real capture instead of inventing a new format.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const FIX = path.join(repoRoot, 'tests', 'fixtures', 'mutation');
const GO = 'go-mutesting-0.0.0-20261002081621-9ce5f731e321';
const fixturePath = (name) => path.join(FIX, name);
const readFixture = (name) => fs.readFile(fixturePath(name), 'utf8');

const STRYKER_REPORT = 'stryker-10.1.1-report.json';
const MUTMUT_CICD = 'mutmut-3.8.0-cicd-stats.json';
const MUTMUT_RESULTS_ALL = 'mutmut-3.8.0-results-all.txt';
const MUTMUT_MIXED_CICD = 'mutmut-3.8.0-mixed-cicd-stats.json';
const MUTMUT_MIXED_RESULTS_ALL = 'mutmut-3.8.0-mixed-results-all.txt';
const GO_REPORT = `${GO}-report.json`;

const ZERO = { killed: 0, survived: 0, timeout: 0, no_coverage: 0, ignored: 0, errors: 0, unknown: 0, total: 0 };
const totalsOf = (over) => ({ ...ZERO, ...over });

async function createProject(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'd4-mutation');
  await fs.mkdir(tempRoot, { recursive: true });
  const dir = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

async function writeStub(file, body) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

// Stub bodies replay the real captures (paths come in through the env).
const STRYKER_STUB = [
  'echo "$PWD :: $*" >> "$STUB_CALLS"',
  'if [ -z "$STUB_NOWRITE" ]; then mkdir -p reports/mutation; cp "$STUB_REPORT" reports/mutation/mutation.json; fi',
  '[ -n "$STUB_STDERR" ] && echo "$STUB_STDERR" >&2',
  'exit ${STUB_EXIT:-0}',
].join('\n');

const MUTMUT_STUB = [
  'echo "$*" >> "$STUB_CALLS"',
  'case "$1" in',
  '  run) cat "$STUB_RUN_STDOUT"; exit ${STUB_RUN_EXIT:-0};;',
  '  export-cicd-stats) mkdir -p mutants; cp "$STUB_CICD" mutants/mutmut-cicd-stats.json; echo "Saved CI/CD stats to mutants/mutmut-cicd-stats.json";;',
  '  results) if [ "$2" = "--all" ]; then cat "$STUB_RESULTS_ALL"; else cat "$STUB_RESULTS"; fi;;',
  'esac',
].join('\n');

const GO_STUB = [
  'echo "$PWD :: $*" >> "$STUB_CALLS"',
  'if [ -z "$STUB_NOWRITE" ]; then cp "$STUB_REPORT" report.json; fi',
  'cat "$STUB_STDOUT"',
  'exit ${STUB_EXIT:-0}',
].join('\n');

const SLEEP_STUB = [
  'echo "$$" > "$STUB_PIDFILE"',
  'sleep 30 &',
  'echo "$!" >> "$STUB_PIDFILE"',
  'wait',
].join('\n');

async function strykerProject(t, { report = fixturePath(STRYKER_REPORT), extraEnv = {} } = {}) {
  const dir = await createProject(t);
  await writeStub(path.join(dir, 'node_modules', '.bin', 'stryker'), STRYKER_STUB);
  const calls = path.join(dir, '..', `${path.basename(dir)}.calls`);
  t.after(async () => { await fs.rm(calls, { force: true }); });
  const env = { PATH: '/usr/bin:/bin', HOME: dir, STUB_CALLS: calls, STUB_REPORT: report, ...extraEnv };
  return { dir, env, calls };
}

async function mutmutProject(t, { cicd = MUTMUT_CICD, resultsAll = MUTMUT_RESULTS_ALL, results = 'mutmut-3.8.0-results.txt', runStdout = 'mutmut-3.8.0-run.stdout.txt', extraEnv = {}, local = true } = {}) {
  const dir = await createProject(t);
  const bin = path.join(dir, '.venv', 'bin');
  const pathBin = path.join(dir, 'pathbin');
  await writeStub(path.join(local ? bin : pathBin, 'mutmut'), MUTMUT_STUB);
  const calls = path.join(dir, '..', `${path.basename(dir)}.calls`);
  t.after(async () => { await fs.rm(calls, { force: true }); });
  const env = {
    PATH: `${pathBin}:/usr/bin:/bin`,
    HOME: dir,
    STUB_CALLS: calls,
    STUB_RUN_STDOUT: fixturePath(runStdout),
    STUB_CICD: fixturePath(cicd),
    STUB_RESULTS_ALL: fixturePath(resultsAll),
    STUB_RESULTS: fixturePath(results),
    ...extraEnv,
  };
  return { dir, env, calls };
}

async function goProject(t, { extraEnv = {}, where = 'path' } = {}) {
  const dir = await createProject(t);
  await fs.writeFile(path.join(dir, 'go.mod'), 'module example.com/age\n\ngo 1.22\n');
  const binDir = path.join(dir, where === 'gobin' ? 'gobin' : 'pathbin');
  await writeStub(path.join(binDir, 'go-mutesting'), GO_STUB);
  const calls = path.join(dir, '..', `${path.basename(dir)}.calls`);
  t.after(async () => { await fs.rm(calls, { force: true }); });
  const env = {
    PATH: where === 'gobin' ? '/usr/bin:/bin' : `${binDir}:/usr/bin:/bin`,
    HOME: dir,
    ...(where === 'gobin' ? { GOBIN: binDir } : {}),
    STUB_CALLS: calls,
    STUB_REPORT: fixturePath(GO_REPORT),
    STUB_STDOUT: fixturePath(`${GO}-output.txt`),
    ...extraEnv,
  };
  return { dir, env, calls };
}

async function run(args, { dir, env, extra = {} }) {
  let stdout = '';
  let stderr = '';
  const code = await runCommand(args, {
    cwd: dir,
    env,
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
    killGraceMs: 200,
    ...extra,
  });
  let json = null;
  try { json = JSON.parse(stdout); } catch { /* human output */ }
  return { code, stdout, stderr, json };
}

async function callsOf(calls) {
  return existsSync(calls) ? (await fs.readFile(calls, 'utf8')).split('\n').filter(Boolean) : [];
}

async function writeJson(dir, name, value) {
  const file = path.join(dir, name);
  await fs.writeFile(file, JSON.stringify(value));
  return file;
}

// DERIVED fixtures: a copy of the REAL Stryker 10.1.1 report with the status
// column rewritten. The real capture only contains Killed and Survived; the other
// statuses come from Stryker's documented MutantStatus vocabulary.
async function deriveStryker(statuses, { keep } = {}) {
  const report = JSON.parse(await readFixture(STRYKER_REPORT));
  const file = report.files['src/age.js'];
  const base = file.mutants;
  file.mutants = statuses.map((status, i) => ({ ...base[i % base.length], id: String(i), status }));
  if (keep) file.mutants = file.mutants.slice(0, keep);
  return report;
}

// ------------------------------------------------------------------ score

test('computeScore: (killed+timeout)/(killed+timeout+survived+no_coverage+unknown); ignored/errors excluded', () => {
  const t1 = totalsOf({ killed: 41, survived: 9, timeout: 2, no_coverage: 3, total: 55 });
  assert.equal(computeScore(t1).score, 78.18);
  // no_coverage lowers the score
  assert.ok(computeScore(totalsOf({ killed: 41, survived: 9, timeout: 2, no_coverage: 0, total: 52 })).score > 78.18);
  // ignored and errors are excluded from the denominator
  const t2 = totalsOf({ killed: 41, survived: 9, timeout: 2, no_coverage: 3, ignored: 5, errors: 4, total: 64 });
  assert.equal(computeScore(t2).score, 78.18);
  // unknown is never a kill: it counts against the score
  const t3 = totalsOf({ killed: 41, survived: 9, timeout: 2, no_coverage: 3, unknown: 5, total: 60 });
  assert.equal(computeScore(t3).score, 71.67); // 43 / 60
});

test('computeScore: denominator 0 -> score null (never a pass)', () => {
  const r = computeScore(totalsOf({ ignored: 3, errors: 1, total: 4 }));
  assert.equal(r.score, null);
  assert.equal(r.denominator, 0);
});

test('computeScore: threshold compares the exact ratio, not the rounded display', () => {
  const t = totalsOf({ killed: 3, survived: 2, total: 5 });
  assert.equal(computeScore(t).score, 60);
  assert.equal(computeScore(t).meets(60), true);
  assert.equal(computeScore(t).meets(60.01), false);
  // 59.996% displays as 60 but does not meet 60
  const huge = totalsOf({ killed: 14999, survived: 10001, total: 25000 });
  assert.equal(computeScore(huge).score, 60);
  assert.equal(computeScore(huge).meets(60), false);
});

// ------------------------------------------------------------ Stryker parse

test('stryker: real 10.1.1 report parses; statuses mapped; survivors sorted', async () => {
  const parsed = parseStrykerReport(await readFixture(STRYKER_REPORT));
  // Counted over the 9 mutants of src/age.js in the capture: 5 Killed, 4 Survived.
  assert.deepEqual(parsed.totals, totalsOf({ killed: 5, survived: 4, total: 9 }));
  assert.equal(parsed.toolVersion, '10.1.1');
  assert.deepEqual(parsed.warnings, []);
  assert.equal(parsed.survivors.length, 4);
  for (const s of parsed.survivors) {
    assert.equal(s.file, 'src/age.js');
    assert.ok(Number.isInteger(s.line) && s.line >= 1);
  }
  assert.deepEqual(
    parsed.survivors.map((s) => [s.line, s.mutator, s.id]),
    [[2, 'ConditionalExpression', '3'], [2, 'EqualityOperator', '5'], [3, 'ArithmeticOperator', '8'], [3, 'BlockStatement', '7']],
  );
});

test('stryker (DERIVED from the real report): every documented status maps; unknown never counts as killed', async () => {
  const derived = await deriveStryker([
    'Killed', 'Survived', 'Timeout', 'NoCoverage', 'Ignored', 'CompileError', 'RuntimeError', 'Pending', 'Exploded',
  ]);
  const parsed = parseStrykerReport(JSON.stringify(derived));
  assert.deepEqual(parsed.totals, totalsOf({
    killed: 1, survived: 1, timeout: 1, no_coverage: 1, ignored: 1, errors: 2, unknown: 2, total: 9,
  }));
  assert.ok(parsed.warnings.some((w) => /Exploded/.test(w)), 'warning names the unknown status');
  assert.ok(parsed.warnings.some((w) => /Pending/.test(w)), 'Pending (an interrupted run) is unknown, not killed');
  // NoCoverage is an undetected mutant, so it is listed with the survivors.
  assert.equal(parsed.survivors.length, 2);
});

test('stryker: garbled, truncated or wrong-shape input throws a parse error', async () => {
  const text = await readFixture(STRYKER_REPORT);
  assert.throws(() => parseStrykerReport(text.slice(0, 400)), /unparseable/);
  assert.throws(() => parseStrykerReport('{"schemaVersion":"1.0"}'), /unparseable/);
  assert.throws(() => parseStrykerReport('[]'), /unparseable/);
  assert.throws(() => parseStrykerReport(''), /unparseable/);
});

// ------------------------------------------------------------- mutmut parse

test('mutmut: real cicd-stats export maps to the uniform totals', async () => {
  const parsed = parseMutmutCicdStats(await readFixture(MUTMUT_CICD));
  // Counted over the 3 mutants of the capture: 1 killed, 2 survived.
  assert.deepEqual(parsed.totals, totalsOf({ killed: 1, survived: 2, total: 3 }));
  assert.equal(parsed.interrupted, 0);
});

test('mutmut: real mixed capture (killed/survived/no tests/timeout) maps no_tests->no_coverage', async () => {
  const parsed = parseMutmutCicdStats(await readFixture(MUTMUT_MIXED_CICD));
  // Counted over the 11 mutants of the mixed capture.
  assert.deepEqual(parsed.totals, totalsOf({ killed: 4, survived: 3, timeout: 2, no_coverage: 2, total: 11 }));
});

test('mutmut (DERIVED from the real cicd export): skipped->ignored, suspicious->unknown, segfault->errors', async () => {
  const stats = JSON.parse(await readFixture(MUTMUT_CICD));
  Object.assign(stats, { killed: 4, survived: 1, skipped: 2, suspicious: 1, segfault: 1, total: 9 });
  const parsed = parseMutmutCicdStats(JSON.stringify(stats));
  assert.deepEqual(parsed.totals, totalsOf({ killed: 4, survived: 1, ignored: 2, unknown: 1, errors: 1, total: 9 }));
  assert.ok(parsed.warnings.some((w) => /suspicious/.test(w)));
  // stats that do not add up to total: the gap is unknown, never killed
  stats.total = 12;
  const gap = parseMutmutCicdStats(JSON.stringify(stats));
  assert.equal(gap.totals.unknown, 4);
  assert.ok(gap.warnings.some((w) => /total/.test(w)));
});

test('mutmut: interrupted check is reported; missing keys / garbage throw', async () => {
  const stats = JSON.parse(await readFixture(MUTMUT_CICD));
  stats.check_was_interrupted_by_user = 1;
  assert.equal(parseMutmutCicdStats(JSON.stringify(stats)).interrupted, 1);
  delete stats.killed;
  assert.throws(() => parseMutmutCicdStats(JSON.stringify(stats)), /unparseable/);
  assert.throws(() => parseMutmutCicdStats('Saved CI/CD stats'), /unparseable/);
});

test('mutmut: results rows parse from the real captures and agree with the cicd export', async () => {
  const rows = parseMutmutResults(await readFixture(MUTMUT_RESULTS_ALL));
  assert.deepEqual(rows, [
    { id: 'mypkg.age.x_add__mutmut_1', status: 'killed' },
    { id: 'mypkg.age.x_is_adult__mutmut_1', status: 'survived' },
    { id: 'mypkg.age.x_is_adult__mutmut_2', status: 'survived' },
  ]);
  // Cross-check on the mixed capture: totals derived from the per-mutant rows
  // equal the cicd export (both counted over the same 11 mutants).
  const mixedRows = parseMutmutResults(await readFixture(MUTMUT_MIXED_RESULTS_ALL));
  assert.equal(mixedRows.length, 11);
  const fromRows = totalsFromMutmutRows(mixedRows);
  assert.deepEqual(fromRows.totals, parseMutmutCicdStats(await readFixture(MUTMUT_MIXED_CICD)).totals);
});

test('mutmut: an unrecognised results status is unknown, not killed', () => {
  const { totals, warnings } = totalsFromMutmutRows([
    { id: 'a.x_f__mutmut_1', status: 'killed' },
    { id: 'a.x_f__mutmut_2', status: 'not checked' },
  ]);
  assert.deepEqual(totals, totalsOf({ killed: 1, unknown: 1, total: 2 }));
  assert.ok(warnings.some((w) => /not checked/.test(w)));
});

// --------------------------------------------------------- go-mutesting parse

test('go-mutesting: real report.json maps killed/escaped; survivors carry file+line+mutator', async () => {
  const parsed = parseGoMutestingReport(await readFixture(GO_REPORT));
  // Counted over the 5 mutants of the capture: 2 killed, 3 escaped.
  assert.deepEqual(parsed.totals, totalsOf({ killed: 2, survived: 3, total: 5 }));
  assert.deepEqual(parsed.survivors.map((s) => [s.file, s.line, s.mutator]), [
    ['age.go', 6, 'expression/comparison'],
    ['age.go', 6, 'numbers/decrementer'],
    ['age.go', 6, 'numbers/incrementer'],
  ]);
  // The stdout summary of the same run agrees (PASS = killed, FAIL = escaped).
  const out = await readFixture(`${GO}-output.txt`);
  assert.match(out, /\(2 passed, 3 failed, 0 duplicated, 0 skipped, total is 5\)/);
});

test('go-mutesting (DERIVED from the real report): timeouts, not-covered, skipped, errors, count gap', async () => {
  const report = JSON.parse(await readFixture(GO_REPORT));
  Object.assign(report.stats, { totalMutantsCount: 12, timeOutCount: 2, notCoveredCount: 1, skippedCount: 1, errorCount: 1 });
  const parsed = parseGoMutestingReport(JSON.stringify(report));
  // 2+3+2+1+1+1 = 10 accounted, 12 total -> 2 unaccounted = unknown
  assert.deepEqual(parsed.totals, totalsOf({
    killed: 2, survived: 3, timeout: 2, no_coverage: 1, ignored: 1, errors: 1, unknown: 2, total: 12,
  }));
  assert.ok(parsed.warnings.length >= 1);
});

test('go-mutesting: garbled or wrong-shape report throws', async () => {
  const text = await readFixture(GO_REPORT);
  assert.throws(() => parseGoMutestingReport(text.slice(0, 200)), /unparseable/);
  assert.throws(() => parseGoMutestingReport('{"escaped":[]}'), /unparseable/);
});

// ------------------------------------------------------------------ detect

test('detect: declared-but-absent -> tool_absent; stub bin -> present; empty dir -> exit 2', async (t) => {
  const empty = await createProject(t);
  const envOf = (dir) => ({ PATH: '/usr/bin:/bin', HOME: dir });
  const none = await run(['detect', '--json'], { dir: empty, env: envOf(empty) });
  assert.equal(none.code, 2);
  assert.equal(none.json.schema, 'rlp-desk.mutation-detect/1');
  assert.deepEqual(none.json.candidates.map((c) => c.tool), ['go-mutesting', 'mutmut', 'stryker']);
  assert.ok(none.json.candidates.every((c) => c.status === 'tool_absent'));

  const proj = await createProject(t);
  await fs.writeFile(path.join(proj, 'package.json'), JSON.stringify({ devDependencies: { '@stryker-mutator/core': '^10.1.1' } }));
  const absent = await run(['detect', '--json'], { dir: proj, env: envOf(proj) });
  const stryker = absent.json.candidates.find((c) => c.tool === 'stryker');
  assert.equal(stryker.status, 'tool_absent');
  assert.match(stryker.evidence, /package\.json/);
  assert.equal(absent.code, 2);

  await writeStub(path.join(proj, 'node_modules', '.bin', 'stryker'), 'exit 0');
  const present = await run(['detect', '--json'], { dir: proj, env: envOf(proj) });
  assert.equal(present.code, 0);
  const s2 = present.json.candidates.find((c) => c.tool === 'stryker');
  assert.equal(s2.status, 'present');
  assert.equal(s2.binary, path.join('node_modules', '.bin', 'stryker'));
});

test('detect: mutmut via .venv or pyproject+PATH; go-mutesting needs go.mod AND the binary; deterministic output', async (t) => {
  const py = await createProject(t);
  await fs.writeFile(path.join(py, 'pyproject.toml'), '[project]\nname="x"\n[tool.mutmut]\nsource_paths=["x/"]\n');
  await writeStub(path.join(py, '.venv', 'bin', 'mutmut'), 'exit 0');
  const a = await run(['detect', '--json'], { dir: py, env: { PATH: '/usr/bin:/bin', HOME: py } });
  assert.equal(a.json.candidates.find((c) => c.tool === 'mutmut').status, 'present');
  const b = await run(['detect', '--json'], { dir: py, env: { PATH: '/usr/bin:/bin', HOME: py } });
  assert.equal(a.stdout, b.stdout);

  const go = await createProject(t);
  const bin = path.join(go, 'bin');
  await writeStub(path.join(bin, 'go-mutesting'), 'exit 0');
  const noMod = await run(['detect', '--json'], { dir: go, env: { PATH: `${bin}:/usr/bin:/bin`, HOME: go } });
  assert.equal(noMod.json.candidates.find((c) => c.tool === 'go-mutesting').status, 'tool_absent');
  await fs.writeFile(path.join(go, 'go.mod'), 'module x\n');
  const withMod = await run(['detect', '--json'], { dir: go, env: { PATH: `${bin}:/usr/bin:/bin`, HOME: go } });
  assert.equal(withMod.json.candidates.find((c) => c.tool === 'go-mutesting').status, 'present');
  const viaGobin = await run(['detect', '--json'], { dir: go, env: { PATH: '/usr/bin:/bin', HOME: go, GOBIN: bin } });
  assert.equal(viaGobin.json.candidates.find((c) => c.tool === 'go-mutesting').status, 'present');
});

test('detect --print-snippet: ready-to-paste test-spec lines for present tools only', async (t) => {
  const { dir, env } = await strykerProject(t);
  const r = await run(['detect', '--print-snippet'], { dir, env });
  assert.equal(r.code, 0);
  assert.match(r.stdout, /- Tool: stryker/);
  assert.match(r.stdout, /mutation run --tool stryker --target/);
  assert.match(r.stdout, /--min-score 60/);
  assert.doesNotMatch(r.stdout, /- Tool: mutmut/);
});

// ------------------------------------------------------------------- usage

test('usage: run without --target, unknown --tool, bad numbers, option-like target, unknown subcommand -> 64', async (t) => {
  const { dir, env } = await strykerProject(t);
  const base = ['run', '--tool', 'stryker'];
  assert.equal((await run(base, { dir, env })).code, 64);
  assert.equal((await run(['run', '--target', 'src/**'], { dir, env })).code, 64);
  assert.equal((await run(['run', '--tool', 'pit', '--target', 'src'], { dir, env })).code, 64);
  assert.equal((await run([...base, '--target', 'src', '--min-score', 'abc'], { dir, env })).code, 64);
  assert.equal((await run([...base, '--target', 'src', '--min-score', '101'], { dir, env })).code, 64);
  assert.equal((await run([...base, '--target', 'src', '--timeout', '0'], { dir, env })).code, 64);
  assert.equal((await run([...base, '--target', '--config=evil'], { dir, env })).code, 64);
  assert.equal((await run(['frobnicate'], { dir, env })).code, 64);
  assert.equal((await callsOf(path.join(dir, '..', `${path.basename(dir)}.calls`))).length, 0, 'no tool spawned on usage errors');
});

test('usage: --out inside the plans lane (PRD/test-spec) is refused', async (t) => {
  const { dir, env, calls } = await strykerProject(t);
  const out = path.join('.rlp-desk', 'plans', 'mutation.json');
  const r = await run(['run', '--tool', 'stryker', '--target', 'src/**', '--out', out, '--json'], { dir, env });
  assert.equal(r.code, 64);
  assert.equal(existsSync(path.join(dir, out)), false);
  assert.equal((await callsOf(calls)).length, 0);
});

// ------------------------------------------------------------ run: Stryker

test('stryker run: scores the real report, below target -> exit 1, equal/above -> exit 0', async (t) => {
  const { dir, env, calls } = await strykerProject(t);
  const args = ['run', '--tool', 'stryker', '--target', 'src/**/*.js', '--json'];
  const fail = await run([...args, '--min-score', '60'], { dir, env });
  assert.equal(fail.json.schema, MUTATION_SCHEMA);
  assert.equal(fail.code, 1);
  assert.equal(fail.json.status, 'ok');
  assert.equal(fail.json.reason, null);
  assert.equal(fail.json.tool, 'stryker');
  assert.equal(fail.json.tool_version, '10.1.1');
  assert.equal(fail.json.score, 55.56); // 5 / 9
  assert.equal(fail.json.meets_target, false);
  assert.deepEqual(fail.json.totals, totalsOf({ killed: 5, survived: 4, total: 9 }));
  assert.equal(fail.json.survivors.length, 4);
  assert.equal(fail.json.survivors_total, 4);
  const pass = await run([...args, '--min-score', '55'], { dir, env });
  assert.equal(pass.code, 0);
  assert.equal(pass.json.meets_target, true);
  // exact tool invocation: reporters json, target via --mutate, run from the project dir
  const [first] = await callsOf(calls);
  assert.ok(first.endsWith(':: run --reporters json --mutate src/**/*.js'), first);
  assert.equal(first.split(' :: ')[0], await fs.realpath(dir));
});

test('stryker run: exactly equal to --min-score passes (DERIVED 5-mutant report: 3 killed, 2 survived)', async (t) => {
  const derived = await deriveStryker(['Killed', 'Killed', 'Killed', 'Survived', 'Survived']);
  const probe = await createProject(t);
  const reportFile = await writeJson(probe, 'derived.json', derived);
  const { dir, env } = await strykerProject(t, { report: reportFile });
  const base = ['run', '--tool', 'stryker', '--target', 'src', '--json'];
  const eq = await run([...base, '--min-score', '60'], { dir, env });
  assert.equal(eq.json.score, 60);
  assert.equal(eq.code, 0);
  const above = await run([...base, '--min-score', '60.5'], { dir, env });
  assert.equal(above.code, 1);
});

test('stryker run: tool exits non-zero (below its own thresholds.break) but the report is complete -> still scored', async (t) => {
  // Real behaviour captured in w2-fixtures.md: exit 1, report still written.
  const { dir, env } = await strykerProject(t, { extraEnv: { STUB_EXIT: '1', STUB_STDERR: 'ERROR MutationTestReportHelper Final mutation score 55.56 under breaking threshold 60, setting exit code to 1 (failure).' } });
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '50', '--json'], { dir, env });
  assert.equal(r.json.status, 'ok');
  assert.equal(r.json.score, 55.56);
  assert.equal(r.code, 0);
});

test('stryker run: a stale report from an earlier run is never scored; no report -> exit 2', async (t) => {
  const { dir, env } = await strykerProject(t, { extraEnv: { STUB_NOWRITE: '1' } });
  await fs.mkdir(path.join(dir, 'reports', 'mutation'), { recursive: true });
  await fs.copyFile(fixturePath(STRYKER_REPORT), path.join(dir, 'reports', 'mutation', 'mutation.json'));
  const stale = await run(['run', '--tool', 'stryker', '--target', 'src', '--json'], { dir, env });
  assert.equal(stale.code, 2);
  assert.equal(stale.json.status, 'error');
  assert.equal(stale.json.reason, 'report_missing');
  assert.equal(stale.json.score, null);

  await fs.rm(path.join(dir, 'reports'), { recursive: true });
  const none = await run(['run', '--tool', 'stryker', '--target', 'src', '--json'], { dir, env: { ...env, STUB_EXIT: '1', STUB_STDERR: 'boom: cannot start test runner' } });
  assert.equal(none.code, 2);
  assert.equal(none.json.reason, 'tool_failed');
  assert.match(none.json.detail, /boom/);
});

test('stryker run: garbled or truncated report -> exit 2 unparseable, never a pass', async (t) => {
  const probe = await createProject(t);
  const text = await readFixture(STRYKER_REPORT);
  const truncated = path.join(probe, 'truncated.json');
  await fs.writeFile(truncated, text.slice(0, 500));
  const { dir, env } = await strykerProject(t, { report: truncated });
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'unparseable');
  assert.equal(r.json.meets_target, false);
});

test('stryker run: denominator 0 (only Ignored mutants) -> exit 2 no_mutants, even with --min-score 0', async (t) => {
  const derived = await deriveStryker(['Ignored', 'Ignored', 'CompileError']);
  const probe = await createProject(t);
  const reportFile = await writeJson(probe, 'derived.json', derived);
  const { dir, env } = await strykerProject(t, { report: reportFile });
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.status, 'error');
  assert.equal(r.json.reason, 'no_mutants');
  assert.deepEqual(r.json.totals, totalsOf({ ignored: 2, errors: 1, total: 3 }));
});

test('stryker run: survivors sorted by file/line and capped at 20 (survivors_total keeps the count)', async (t) => {
  const derived = await deriveStryker(Array.from({ length: 26 }, (_, i) => (i < 25 ? 'Survived' : 'Killed')));
  derived.files['src/b.js'] = { language: 'javascript', source: '', mutants: derived.files['src/age.js'].mutants.slice(0, 3).map((m, i) => ({ ...m, id: `b${i}`, status: 'Survived', location: { start: { line: 100 - i, column: 1 }, end: { line: 100 - i, column: 2 } } })) };
  const probe = await createProject(t);
  const reportFile = await writeJson(probe, 'derived.json', derived);
  const { dir, env } = await strykerProject(t, { report: reportFile });
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.json.survivors.length, 20);
  assert.equal(r.json.survivors_total, 28);
  const keys = r.json.survivors.map((s) => [s.file, s.line]);
  const sorted = [...keys].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] - b[1]));
  assert.deepEqual(keys, sorted);
  assert.equal(r.json.survivors[0].file, 'src/age.js');
});

test('stryker run: extra args after -- are forwarded to the tool', async (t) => {
  const { dir, env, calls } = await strykerProject(t);
  await run(['run', '--tool', 'stryker', '--target', 'src', '--json', '--', '--concurrency', '2'], { dir, env });
  const [first] = await callsOf(calls);
  assert.ok(first.endsWith('--mutate src --concurrency 2'), first);
});

test('human output carries the evidence line the Verifier cites', async (t) => {
  const { dir, env } = await strykerProject(t);
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '60'], { dir, env });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /^mutation:stryker score=55\.56 min=60 total=9 ignored=0$/m);
});

// -------------------------------------------------------------- run: mutmut

test('mutmut run: run -> results --all true -> export-cicd-stats; path target becomes a mutant glob', async (t) => {
  const { dir, env, calls } = await mutmutProject(t);
  const r = await run(['run', '--tool', 'mutmut', '--target', 'mypkg/age.py', '--min-score', '30', '--json'], { dir, env });
  assert.equal(r.code, 0);
  assert.equal(r.json.tool, 'mutmut');
  assert.equal(r.json.tool_version, null);
  assert.deepEqual(r.json.totals, totalsOf({ killed: 1, survived: 2, total: 3 }));
  assert.equal(r.json.score, 33.33);
  assert.deepEqual(r.json.survivors.map((s) => s.id), ['mypkg.age.x_is_adult__mutmut_1', 'mypkg.age.x_is_adult__mutmut_2']);
  assert.ok(r.json.survivors.every((s) => s.file === null && s.line === null));
  assert.deepEqual(await callsOf(calls), ['run mypkg.age.*', 'results --all true', 'export-cicd-stats']);
  // below target
  const low = await run(['run', '--tool', 'mutmut', '--target', 'mypkg/age.py', '--min-score', '60', '--json'], { dir, env });
  assert.equal(low.code, 1);
});

test('mutmut run: mixed real capture (no tests + timeout) and a PATH-resolved binary', async (t) => {
  const { dir, env } = await mutmutProject(t, { cicd: MUTMUT_MIXED_CICD, resultsAll: MUTMUT_MIXED_RESULTS_ALL, results: 'mutmut-3.8.0-mixed-results.txt', local: false });
  const r = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '50', '--json'], { dir, env });
  assert.deepEqual(r.json.totals, totalsOf({ killed: 4, survived: 3, timeout: 2, no_coverage: 2, total: 11 }));
  assert.equal(r.json.score, 54.55); // (4+2) / (4+2+3+2)
  assert.equal(r.code, 0);
  assert.equal(r.json.survivors_total, 5); // 3 survived + 2 no tests
});

test('mutmut run: a target narrower than the mutants/ store is scored from the matching rows only', async (t) => {
  // cicd export is project-wide (11 mutants); the target covers 1. Totals must come from the rows.
  const { dir, env } = await mutmutProject(t, { cicd: MUTMUT_MIXED_CICD, resultsAll: MUTMUT_MIXED_RESULTS_ALL, results: 'mutmut-3.8.0-mixed-results.txt' });
  const r = await run(['run', '--tool', 'mutmut', '--target', 'mypkg.age.x_add*', '--min-score', '0', '--json'], { dir, env });
  assert.deepEqual(r.json.totals, totalsOf({ killed: 1, total: 1 }));
  assert.ok(r.json.warnings.some((w) => /narrower|scope/i.test(w)));
});

test('mutmut run: failed run (real src-layout failure capture) -> exit 2 tool_failed, stats never read', async (t) => {
  const { dir, env, calls } = await mutmutProject(t, { runStdout: 'mutmut-3.8.0-run-failed-src-layout.stdout.txt', extraEnv: { STUB_RUN_EXIT: '1' } });
  const r = await run(['run', '--tool', 'mutmut', '--target', 'src/age.py', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'tool_failed');
  assert.match(r.json.detail, /failed to collect stats/);
  assert.deepEqual(await callsOf(calls), ['run src.age.*']);
});

test('mutmut run: check_was_interrupted_by_user > 0 -> exit 2 interrupted', async (t) => {
  const probe = await createProject(t);
  const stats = JSON.parse(await readFixture(MUTMUT_CICD));
  stats.check_was_interrupted_by_user = 1;
  const file = await writeJson(probe, 'interrupted.json', stats);
  const { dir, env } = await mutmutProject(t);
  const r = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '0', '--json'], { dir, env: { ...env, STUB_CICD: file } });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'interrupted');
});

// ---------------------------------------------------------- run: go-mutesting

test('go-mutesting run: scores report.json, passes the target through, leaves no report.json behind', async (t) => {
  const { dir, env, calls } = await goProject(t);
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--min-score', '30', '--json'], { dir, env });
  assert.equal(r.code, 0);
  assert.deepEqual(r.json.totals, totalsOf({ killed: 2, survived: 3, total: 5 }));
  assert.equal(r.json.score, 40);
  assert.deepEqual(r.json.survivors.map((s) => [s.file, s.line, s.mutator]), [
    ['age.go', 6, 'expression/comparison'], ['age.go', 6, 'numbers/decrementer'], ['age.go', 6, 'numbers/incrementer'],
  ]);
  const [first] = await callsOf(calls);
  assert.ok(first.endsWith(':: ./...'), first);
  assert.equal(existsSync(path.join(dir, 'report.json')), false, 'wrapper cleans up the report.json go-mutesting writes into cwd');
  const low = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--min-score', '60', '--json'], { dir, env });
  assert.equal(low.code, 1);
  assert.equal(existsSync(path.join(dir, 'report.json')), false);
});

test('go-mutesting run: binary found through GOBIN', async (t) => {
  const { dir, env } = await goProject(t, { where: 'gobin' });
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.json.status, 'ok');
});

test('go-mutesting run: a pre-existing report.json is the user\'s file: refuse (exit 2), do not run, do not touch it', async (t) => {
  const { dir, env, calls } = await goProject(t);
  await fs.writeFile(path.join(dir, 'report.json'), '{"mine":true}');
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_json_exists');
  assert.equal(await fs.readFile(path.join(dir, 'report.json'), 'utf8'), '{"mine":true}');
  assert.equal((await callsOf(calls)).length, 0);
});

test('go-mutesting run: no report written -> exit 2 report_missing; wrapper stdout alone is never scored', async (t) => {
  const { dir, env } = await goProject(t, { extraEnv: { STUB_NOWRITE: '1' } });
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_missing');
});

// ------------------------------------------------- run: absent / timeout / out

test('tool absent: exit 2, status tool_absent, no process spawned', async (t) => {
  const dir = await createProject(t);
  const calls = path.join(dir, 'calls.log');
  const env = { PATH: '/usr/bin:/bin', HOME: dir, STUB_CALLS: calls };
  for (const tool of ['stryker', 'mutmut', 'go-mutesting']) {
    const r = await run(['run', '--tool', tool, '--target', 'src', '--json'], { dir, env });
    assert.equal(r.code, 2, tool);
    assert.equal(r.json.status, 'tool_absent', tool);
    assert.equal(r.json.score, null);
    assert.equal(r.json.meets_target, false);
  }
  assert.equal(existsSync(calls), false);
});

test('timeout: exit 2 reason timeout, the whole process group is killed', async (t) => {
  const dir = await createProject(t);
  await writeStub(path.join(dir, 'node_modules', '.bin', 'stryker'), SLEEP_STUB);
  const pidfile = path.join(dir, 'pids.txt');
  const env = { PATH: '/usr/bin:/bin', HOME: dir, STUB_PIDFILE: pidfile };
  const started = Date.now();
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--timeout', '1', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.status, 'timeout');
  assert.equal(r.json.reason, 'timeout');
  assert.ok(Date.now() - started < 15000, 'returns promptly after the timeout, not after the 30 s sleep');
  const pids = (await fs.readFile(pidfile, 'utf8')).split('\n').filter(Boolean).map(Number);
  assert.equal(pids.length, 2);
  await new Promise((resolve) => setTimeout(resolve, 200));
  for (const pid of pids) {
    assert.throws(() => process.kill(pid, 0), (e) => e.code === 'ESRCH', `pid ${pid} is gone`);
  }
});

test('--out writes the same JSON as stdout; repeated runs are byte-identical', async (t) => {
  const { dir, env } = await strykerProject(t);
  const out = path.join('artifacts', 'mutation.json');
  const args = ['run', '--tool', 'stryker', '--target', 'src', '--min-score', '60', '--json', '--out', out];
  const first = await run(args, { dir, env });
  const written = await fs.readFile(path.join(dir, out), 'utf8');
  assert.equal(written, first.stdout);
  const second = await run(args, { dir, env });
  assert.equal(second.stdout, first.stdout);
  assert.doesNotMatch(first.stdout, /\d{4}-\d{2}-\d{2}T/, 'no timestamps');
});

// ----------------------------------------------------------------- dispatch

test('dispatch: run.mjs help lists mutation; mutation --help / usage errors go through main()', async () => {
  const run1 = async (argv) => {
    let stdout = '';
    let stderr = '';
    const code = await main(argv, { cwd: repoRoot, stdout: { write: (s) => { stdout += s; } }, stderr: { write: (s) => { stderr += s; } } });
    return { code, stdout, stderr };
  };
  const help = await run1(['--help']);
  assert.match(help.stdout, /^ {2}mutation /m);
  const sub = await run1(['mutation', '--help']);
  assert.equal(sub.code, 0);
  assert.match(sub.stdout, /mutation <detect\|run>/);
  assert.match(sub.stdout, /MUT-GATE-UNMET|exit/i);
  const bad = await run1(['mutation', 'run', '--tool', 'stryker']);
  assert.equal(bad.code, 64);
});

// ------------------------------------------------- round-1 review fixes

test('B-C1-03: malformed mutmut result rows fail closed (exit 2 unparseable), never a narrower-target pass', async (t) => {
  const probe = await createProject(t);
  const real = await readFixture(MUTMUT_RESULTS_ALL);
  // DERIVED from the real capture: survivor rows get a different separator, so they no
  // longer parse. cicd stats still say 2 of 3 survived (score 33.33 < 50).
  const broken = path.join(probe, 'broken-results.txt');
  await fs.writeFile(broken, real.replace(/: survived/g, ' => survived'));
  const { dir, env } = await mutmutProject(t);
  const bad = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '50', '--json'], { dir, env: { ...env, STUB_RESULTS_ALL: broken } });
  assert.equal(bad.code, 2);
  assert.equal(bad.json.reason, 'unparseable');
  assert.equal(bad.json.meets_target, false);

  // DERIVED: every real row intact plus one junk line: the row count still equals the
  // cicd total (3), so only the "all lines must parse" rule can catch it.
  const junk = path.join(probe, 'junk-results.txt');
  await fs.writeFile(junk, `${real}WARNING: something unexpected\n`);
  const extra = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '0', '--json'], { dir, env: { ...env, STUB_RESULTS_ALL: junk } });
  assert.equal(extra.code, 2);
  assert.equal(extra.json.reason, 'unparseable');

  // DERIVED: a valid row is missing, so rows (2) disagree with cicd total (3) although
  // every remaining line parses: also unparseable, not "narrower".
  const short = path.join(probe, 'short-results.txt');
  await fs.writeFile(short, real.split('\n').slice(1).join('\n'));
  const gap = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '0', '--json'], { dir, env: { ...env, STUB_RESULTS_ALL: short } });
  assert.equal(gap.code, 2);
  assert.equal(gap.json.reason, 'unparseable');
});

test('B-C1-04: --out may not reach any .rlp-desk/plans, even through --project-dir, symlinks or case, and even when the tool is absent', async (t) => {
  const root = await createProject(t);
  const plans = path.join(root, '.rlp-desk', 'plans');
  const sealed = path.join(plans, 'test-spec-demo.md');
  await fs.mkdir(plans, { recursive: true });
  await fs.mkdir(path.join(root, 'packages', 'payments'), { recursive: true });
  await fs.writeFile(sealed, 'SEALED');
  await fs.symlink(plans, path.join(root, 'plink'));
  await fs.symlink(sealed, path.join(root, 'flink.md'));
  // dangling symlink: the target does not exist yet, so realpath alone would not see it
  await fs.symlink(path.join(plans, 'not-yet.md'), path.join(root, 'dangling.md'));
  const env = { PATH: '/usr/bin:/bin', HOME: root };
  const base = ['run', '--tool', 'stryker', '--target', 'src', '--json', '--project-dir', path.join('packages', 'payments')];
  const outs = [
    path.join('..', '..', '.rlp-desk', 'plans', 'test-spec-demo.md'),
    path.join(root, 'packages', 'payments', '..', '..', '.rlp-desk', 'plans', 'new.json'),
    path.join('..', '..', 'plink', 'new.json'),
    path.join('..', '..', 'flink.md'),
    path.join('..', '..', 'dangling.md'),
    path.join('..', '..', '.RLP-DESK', 'PLANS', 'new.json'),
  ];
  for (const out of outs) {
    const r = await run([...base, '--out', out], { dir: root, env });
    assert.equal(r.code, 64, out);
    assert.equal(r.stdout, '', out);
  }
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');
  assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-demo.md']);
  // a desk of the project dir itself is covered too
  const innerPlans = path.join(root, 'packages', 'payments', '.rlp-desk', 'plans');
  await fs.mkdir(innerPlans, { recursive: true });
  const inner = await run([...base, '--out', path.join('.rlp-desk', 'plans', 'x.json')], { dir: root, env });
  assert.equal(inner.code, 64);
  assert.equal(existsSync(path.join(plans, 'not-yet.md')), false);
  // a custom desk dir (RLP_DESK_RUNTIME_DIR) is guarded for both the caller's and the project's base
  const custom = { ...env, RLP_DESK_RUNTIME_DIR: '.desk' };
  await fs.mkdir(path.join(root, '.desk', 'plans'), { recursive: true });
  await fs.mkdir(path.join(root, 'packages', 'payments', '.desk', 'plans'), { recursive: true });
  const callerDesk = await run([...base, '--out', path.join('..', '..', '.desk', 'plans', 'x.json')], { dir: root, env: custom });
  assert.equal(callerDesk.code, 64);
  const projectDesk = await run([...base, '--out', path.join('.desk', 'plans', 'x.json')], { dir: root, env: custom });
  assert.equal(projectDesk.code, 64);
  // an ordinary location still works
  const ok = await run([...base, '--out', path.join('..', '..', 'artifacts', 'mutation.json')], { dir: root, env });
  assert.equal(ok.code, 2); // tool absent
  assert.equal(JSON.parse(await fs.readFile(path.join(root, 'artifacts', 'mutation.json'), 'utf8')).status, 'tool_absent');
});

test('R1-02: ignored mutants are reported in the evidence line and a warning (they are excluded from the score)', async (t) => {
  const derived = await deriveStryker(['Killed', 'Killed', 'Survived', 'Ignored', 'Ignored']);
  const probe = await createProject(t);
  const reportFile = await writeJson(probe, 'derived.json', derived);
  const { dir, env } = await strykerProject(t, { report: reportFile });
  const human = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '60'], { dir, env });
  assert.equal(human.code, 0);
  assert.match(human.stdout, /^mutation:stryker score=66\.67 min=60 total=5 ignored=2$/m);
  const json = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '60', '--json'], { dir, env });
  assert.equal(json.json.totals.ignored, 2);
  assert.ok(json.json.warnings.some((w) => /2 mutants? ignored/.test(w) && /MUT-SUPPRESSED/.test(w)));
  const clean = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '60', '--json'], { dir, env: { ...env, STUB_REPORT: fixturePath(STRYKER_REPORT) } });
  assert.ok(!clean.json.warnings.some((w) => /ignored/.test(w)));
});

test('R1-03: an unwritable --out and an unexpected internal error exit 2 (never 1), with the JSON still on stdout', async (t) => {
  const none = await createProject(t);
  const absentEnv = { PATH: '/usr/bin:/bin', HOME: none };
  const unwritable = await run(['run', '--tool', 'stryker', '--target', 'src', '--json', '--out', '/dev/null/x.json'], { dir: none, env: absentEnv });
  assert.equal(unwritable.code, 2);
  assert.equal(unwritable.json.status, 'tool_absent');
  assert.match(unwritable.stderr, /--out/);

  const { dir, env } = await strykerProject(t);
  const boom = await run(['run', '--tool', 'stryker', '--target', 'src', '--json'], { dir, env, extra: { exec: async () => { throw new Error('boom'); } } });
  assert.equal(boom.code, 2);
  assert.equal(boom.json.status, 'error');
  assert.equal(boom.json.reason, 'internal_error');
  assert.match(boom.json.detail, /boom/);
  assert.equal(boom.json.tool, 'stryker');
});

// ------------------------------------------------- round-2 review fixes


// A fake tool that plants a symlink at the --out destination (or swaps its parent
// directory for a symlink) while it runs, as the round-2 reviewer reproduced.
function plantingStub(plantBody) {
  return [
    STRYKER_STUB,
    plantBody,
  ].join('\n').replace('exit ${STUB_EXIT:-0}\n', '').concat('\nexit ${STUB_EXIT:-0}');
}

async function plantingProject(t, plantBody) {
  const proj = await strykerProject(t);
  await writeStub(path.join(proj.dir, 'node_modules', '.bin', 'stryker'), plantingStub(plantBody));
  const plans = path.join(proj.dir, '.rlp-desk', 'plans');
  const sealed = path.join(plans, 'test-spec-x.md');
  await fs.mkdir(plans, { recursive: true });
  await fs.writeFile(sealed, 'SEALED');
  return { ...proj, plans, sealed };
}

test('B-C2-01: a --out destination swapped to a symlink into plans/ during the run is never written through', async (t) => {
  const { dir, env, plans, sealed } = await plantingProject(t, 'ln -s "$PWD/.rlp-desk/plans/test-spec-x.md" report-out.json');
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json', '--out', 'report-out.json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.status, 'ok', 'the result is still printed');
  assert.match(r.stderr, /--out/);
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');
  assert.equal((await fs.lstat(path.join(dir, 'report-out.json'))).isSymbolicLink(), true);
  assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-x.md']);
});

test('B-C2-01: a --out parent directory swapped for a symlink into plans/ during the run is refused', async (t) => {
  const { dir, env, plans, sealed } = await plantingProject(t, 'rm -rf sub; ln -s "$PWD/.rlp-desk/plans" sub');
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json', '--out', path.join('sub', 'out.json')], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');
  assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-x.md']);
});

test('writeFileSafely: replaces a symlink destination instead of following it; keeps mode; no temp file left', async (t) => {
  const dir = await createProject(t);
  const victim = path.join(dir, 'victim.txt');
  await fs.writeFile(victim, 'VICTIM');
  const dest = path.join(dir, 'out.txt');
  await fs.symlink(victim, dest);
  await writeFileSafely(dest, 'NEW');
  assert.equal(await fs.readFile(victim, 'utf8'), 'VICTIM');
  assert.equal((await fs.lstat(dest)).isSymbolicLink(), false);
  assert.equal(await fs.readFile(dest, 'utf8'), 'NEW');

  await fs.chmod(dest, 0o600);
  await writeFileSafely(dest, 'NEWER');
  assert.equal((await fs.stat(dest)).mode & 0o777, 0o600);
  assert.deepEqual((await fs.readdir(dir)).sort(), ['out.txt', 'victim.txt']);
});

test('writeFileSafely: post-rename self-check throws when the destination is not our file or the parent changed, and removes only our own file', async (t) => {
  const root = await createProject(t);
  // (a) something else takes the destination right after our rename: not our dev+ino -> throw, foreign file untouched
  const a = path.join(root, 'a.txt');
  await assert.rejects(writeFileSafely(a, 'OURS', {
    afterRename: async () => { await fs.rm(a); await fs.writeFile(a, 'FOREIGN'); },
  }), /changed during the final rename/);
  assert.equal(await fs.readFile(a, 'utf8'), 'FOREIGN');
  // (b) the parent is swapped right after the rename: identity changed -> throw, nothing left in the new directory
  const parent = path.join(root, 'parent');
  await fs.mkdir(parent);
  await assert.rejects(writeFileSafely(path.join(parent, 'b.txt'), 'OURS', {
    afterRename: async () => { await fs.rename(parent, `${parent}.old`); await fs.mkdir(parent); },
  }), /changed during the final rename/);
  assert.deepEqual(await fs.readdir(parent), []);
  // (c) the normal path is untouched by the self-check
  const c = path.join(root, 'c.txt');
  await writeFileSafely(c, 'OK');
  assert.equal(await fs.readFile(c, 'utf8'), 'OK');
});

test('writeFileSafely: refuses when the parent directory is replaced after the temp file is written; a failing recheck leaves nothing behind', async (t) => {
  const root = await createProject(t);
  const parent = path.join(root, 'parent');
  await fs.mkdir(parent);
  const dest = path.join(parent, 'out.txt');
  await assert.rejects(writeFileSafely(dest, 'X', {
    afterTempWrite: async () => { await fs.rename(parent, `${parent}.old`); await fs.mkdir(parent); },
  }), /parent directory changed/);
  assert.deepEqual(await fs.readdir(parent), [], 'nothing was written into the replacement directory');

  const dir2 = path.join(root, 'two');
  await fs.mkdir(dir2);
  await assert.rejects(writeFileSafely(path.join(dir2, 'o.txt'), 'X', { recheck: async () => { throw new Error('policy says no'); } }), /policy says no/);
  assert.deepEqual(await fs.readdir(dir2), []);
});

test('writeGuardedOut: the destination is re-validated right before the rename (swap after the temp file is written)', async (t) => {
  const root = await createProject(t);
  const plans = path.join(root, '.rlp-desk', 'plans');
  await fs.mkdir(plans, { recursive: true });
  const sealed = path.join(plans, 'test-spec-x.md');
  await fs.writeFile(sealed, 'SEALED');
  const ctx = { baseDir: root, deskBases: [root], env: { PATH: '/usr/bin:/bin' } };
  await assert.rejects(writeGuardedOut('out.json', 'X', ctx, {
    afterTempWrite: async () => { await fs.symlink(sealed, path.join(root, 'out.json')); },
  }), /symlink/);
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');
  assert.deepEqual((await fs.readdir(root)).sort(), ['.rlp-desk', 'out.json']);
});

test('B-C2-05: passthrough options that override the wrapper-owned scope/report/gate are rejected before anything runs', async (t) => {
  const s = await strykerProject(t);
  const m = await mutmutProject(t);
  const g = await goProject(t);
  const rejected = [
    [s, 'stryker', ['--mutate', 'src/easy.js']],
    [s, 'stryker', ['--mutate=src/easy.js']],
    [s, 'stryker', ['-m', 'src/easy.js']],
    [s, 'stryker', ['-m=src/easy.js']],
    [s, 'stryker', ['-msrc/easy.js']],
    [s, 'stryker', ['--reporters', 'clear-text']],
    [s, 'stryker', ['--files', 'x.js']],
    [s, 'stryker', ['--thresholds.break', '0']],
    [s, 'stryker', ['stryker.easy.conf.json']],
    [m, 'mutmut', ['mypkg.easy.*']],
    [m, 'mutmut', ['--paths-to-mutate', 'x']],
    [m, 'mutmut', ['--max-children']],
    [g, 'go-mutesting', ['./other']],
    [g, 'go-mutesting', ['--disable', 'branch/*']],
    [g, 'go-mutesting', ['--disable=branch/*']],
    [g, 'go-mutesting', ['--match', 'Foo']],
    [g, 'go-mutesting', ['--blacklist=file']],
    [g, 'go-mutesting', ['--exec', 'true']],
    [g, 'go-mutesting', ['--config=x.yml']],
    [g, 'go-mutesting', ['--no-exec']],
  ];
  for (const [proj, tool, extra] of rejected) {
    const r = await run(['run', '--tool', tool, '--target', tool === 'go-mutesting' ? './...' : 'src', '--json', '--', ...extra], { dir: proj.dir, env: proj.env });
    assert.equal(r.code, 64, `${tool} -- ${extra.join(' ')}`);
    assert.equal(r.stdout, '');
    assert.equal((await callsOf(proj.calls)).length, 0, `${tool} -- ${extra.join(' ')} spawned nothing`);
  }
  // harmless tuning options are still forwarded
  const ok1 = await run(['run', '--tool', 'stryker', '--target', 'src', '--json', '--', '--concurrency', '2', '--logLevel', 'warn'], { dir: s.dir, env: s.env });
  assert.equal(ok1.json.status, 'ok');
  const ok2 = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--json', '--', '--max-children', '2'], { dir: m.dir, env: m.env });
  assert.equal(ok2.json.status, 'ok');
  assert.ok((await callsOf(m.calls))[0].endsWith('run mypkg.* --max-children 2'));
  const ok3 = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--json', '--', '--verbose', '--debug'], { dir: g.dir, env: g.env });
  assert.equal(ok3.json.status, 'ok');
  assert.ok((await callsOf(g.calls))[0].endsWith(':: ./... --verbose --debug'));
});

test('B-C2-05: a Stryker report that mutated files outside --target is not scored (exit 2 scope_mismatch)', async (t) => {
  const derived = await deriveStryker(['Killed', 'Killed', 'Killed', 'Survived']);
  derived.files['lib/easy.js'] = { language: 'javascript', source: '', mutants: derived.files['src/age.js'].mutants.slice(0, 2).map((m, i) => ({ ...m, id: `e${i}`, status: 'Killed' })) };
  const probe = await createProject(t);
  const reportFile = await writeJson(probe, 'derived.json', derived);
  const { dir, env } = await strykerProject(t, { report: reportFile });
  const bad = await run(['run', '--tool', 'stryker', '--target', 'src/**/*.js', '--min-score', '0', '--json'], { dir, env });
  assert.equal(bad.code, 2);
  assert.equal(bad.json.reason, 'scope_mismatch');
  assert.match(bad.json.detail, /lib\/easy\.js/);
  // every file inside the target (glob, comma list, directory prefix, brace) is fine
  for (const target of ['src/**/*.js,lib/**/*.js', '{src,lib}/*.js', 'src/age.js,lib/easy.js', 'src/age.js:1:1-9:9,lib', './lib/**,src/**']) {
    const ok = await run(['run', '--tool', 'stryker', '--target', target, '--min-score', '0', '--json'], { dir, env });
    assert.equal(ok.json.status, 'ok', target);
  }
});

test('B-C2-06: a report.json that already exists as ANY entry (dangling symlink included) is refused; nothing is written through it', async (t) => {
  const { dir, env, calls } = await goProject(t);
  const plans = path.join(dir, '.rlp-desk', 'plans');
  await fs.mkdir(plans, { recursive: true });
  await fs.symlink(path.join(plans, 'test-spec-new.md'), path.join(dir, 'report.json')); // dangling
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_json_exists');
  assert.equal((await callsOf(calls)).length, 0);
  assert.deepEqual(await fs.readdir(plans), []);
  assert.equal((await fs.lstat(path.join(dir, 'report.json'))).isSymbolicLink(), true, 'the user\'s entry is left alone');
});

test('B-C2-06: a report.json that the tool run turns into a symlink is not read or followed', async (t) => {
  const { dir, env } = await goProject(t, { extraEnv: { STUB_NOWRITE: '1' } });
  await writeStub(path.join(dir, 'pathbin', 'go-mutesting'), `${GO_STUB.replace(/\nexit .*$/u, '')}\nln -s "$STUB_REPORT" report.json`);
  const r = await run(['run', '--tool', 'go-mutesting', '--target', './...', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_missing');
  assert.equal(existsSync(path.join(dir, 'report.json')) || (await fs.lstat(path.join(dir, 'report.json')).catch(() => null)) !== null, false, 'cleaned up');
});

// ------------------------------------------------- round-3 review fixes

// Every option of `stryker run --help` in 10.1.1 (read from the installed CLI, scratch dir), classified.
// Allowed = cannot change mutant selection, the kill decision (timeouts count as kills), the runner,
// plugins, incremental reuse or the report. Everything else is refused.
const STRYKER_10_1_1_ALLOWED = [
  ['--disableBail'], ['--concurrency', '2'], ['-c', '2'], ['--maxConcurrentTestRunners', '2'], ['--maxTestRunnerReuse', '0'],
  ['--logLevel', 'warn'], ['--fileLogLevel', 'off'], ['--allowConsoleColors', 'false'], ['--cleanTempDir', 'always'],
  ['--coverageAnalysis', 'off'],
];
const STRYKER_10_1_1_REFUSED = [
  ['-f', 'x'], ['--files', 'x'], ['--ignorePatterns', 'x'], ['--ignoreStatic'], ['--incremental'], ['--allowEmpty'],
  ['--incrementalFile', 'x'], ['--force'], ['-m', 'x'], ['--mutate', 'x'], ['-t', 'x'], ['--testFiles', 'x'],
  ['-b', 'x'], ['--buildCommand', 'x'], ['--commandRunner.command', 'x'], ['--dryRunOnly'], ['--checkers', 'x'],
  ['--checkerNodeArgs', 'x'], ['--testRunner', 'x'], ['--testRunnerNodeArgs', 'x'], ['--reporters', 'x'], ['--plugins', 'x'],
  ['--appendPlugins', 'x'], ['--timeoutMS', '1'], ['--timeoutFactor', '0.1'], ['--dryRunTimeoutMinutes', '1'],
  ['--dashboard.project', 'x'], ['--inPlace'], ['--tempDirName', 'x'], ['-h'], ['--help'], ['--thresholds.break', '0'],
  ['--someFutureOption'], ['--coverageAnalysis', 'bogus'], ['--concurrency', 'two'],
];

test('R3-02: Stryker passthrough is a closed allow-list: only options that cannot change selection, kill decision, runner, plugins, incremental reuse or report', () => {
  for (const args of STRYKER_10_1_1_ALLOWED) assert.doesNotThrow(() => validatePassthrough('stryker', args), args.join(' '));
  for (const args of STRYKER_10_1_1_REFUSED) assert.throws(() => validatePassthrough('stryker', args), /not allowed/, args.join(' '));
  // go-mutesting: an exec timeout counts a slow mutant as killed; recursive testing changes the kill basis
  for (const args of [['--exec-timeout', '1'], ['--exec-timeout=1'], ['--test-recursive']]) {
    assert.throws(() => validatePassthrough('go-mutesting', args), /not allowed/, args.join(' '));
  }
  for (const args of [['--verbose'], ['--debug'], ['--verbose', '--debug']]) assert.doesNotThrow(() => validatePassthrough('go-mutesting', args));
  assert.doesNotThrow(() => validatePassthrough('mutmut', ['--max-children', '2']));
});

async function plantReportParents(t, plant) {
  const { dir, env, calls } = await strykerProject(t);
  const plans = path.join(dir, '.rlp-desk', 'plans');
  const sealed = path.join(plans, 'test-spec-x.md');
  await fs.mkdir(plans, { recursive: true });
  await fs.writeFile(sealed, 'SEALED');
  await plant({ dir, plans, sealed });
  return { dir, env, calls, plans, sealed };
}

test('B-C3-02: a pre-planted symlink at the Stryker report path or any parent is refused before the tool runs', async (t) => {
  const plants = {
    'file (existing target)': async ({ dir, sealed }) => { await fs.mkdir(path.join(dir, 'reports', 'mutation'), { recursive: true }); await fs.symlink(sealed, path.join(dir, 'reports', 'mutation', 'mutation.json')); },
    'file (dangling)': async ({ dir, plans }) => { await fs.mkdir(path.join(dir, 'reports', 'mutation'), { recursive: true }); await fs.symlink(path.join(plans, 'new.md'), path.join(dir, 'reports', 'mutation', 'mutation.json')); },
    'reports/mutation dir': async ({ dir, plans }) => { await fs.mkdir(path.join(dir, 'reports'), { recursive: true }); await fs.symlink(plans, path.join(dir, 'reports', 'mutation')); },
    'reports dir': async ({ dir, plans }) => { await fs.symlink(plans, path.join(dir, 'reports')); },
    'file is a directory': async ({ dir }) => { await fs.mkdir(path.join(dir, 'reports', 'mutation', 'mutation.json'), { recursive: true }); },
  };
  for (const [name, plant] of Object.entries(plants)) {
    const { dir, env, calls, plans, sealed } = await plantReportParents(t, plant);
    const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
    assert.equal(r.code, 2, name);
    assert.equal(r.json.reason, 'report_path_unsafe', name);
    assert.equal((await callsOf(calls)).length, 0, `${name}: tool not spawned`);
    assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED', name);
    assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-x.md'], name);
  }
});

test('B-C3-02: a report that the run turns into a symlink is not read or scored', async (t) => {
  const { dir, env } = await strykerProject(t);
  await writeStub(path.join(dir, 'node_modules', '.bin', 'stryker'), [
    'mkdir -p reports/mutation',
    'cp "$STUB_REPORT" reports/outside.json',
    'ln -s "$PWD/reports/outside.json" reports/mutation/mutation.json',
  ].join('\n'));
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_path_unsafe');
});

test('R3-03: scope check supports character classes, extglobs, braces, absolute targets', () => {
  const project = '/proj';
  const out = (files, target) => filesOutsideTarget(files, target, project);
  assert.deepEqual(out(['src/a.js', 'src/b.js', 'src/c.js'], 'src/[ab].js'), ['src/c.js']);
  assert.deepEqual(out(['src/a.js', 'src/c.js'], 'src/[!a].js'), ['src/a.js']);
  assert.deepEqual(out(['src/a.js', 'src/m.js', 'src/z.js'], 'src/[a-m].js'), ['src/z.js']);
  assert.deepEqual(out(['src/a.js', 'src/b.js', 'src/c.js'], 'src/+(a|b).js'), ['src/c.js']);
  assert.deepEqual(out(['src/a.js', 'src/b.js', 'src/c.js'], 'src/@(a|b).js'), ['src/c.js']);
  assert.deepEqual(out(['src/.js', 'src/a.js', 'src/aa.js', 'src/b.js'], 'src/*(a).js'), ['src/b.js']);
  assert.deepEqual(out(['src/.js', 'src/a.js', 'src/b.js'], 'src/?(a).js'), ['src/b.js']);
  // !(...) is approximated by "any segment text": a deliberate superset (integrity check, not file selection)
  assert.deepEqual(out(['src/a.js', 'lib/a.js'], '{src,lib}/**/!(*.spec).js'), []);
  assert.deepEqual(out(['src/x/y/a.js', 'test/a.js'], 'src/**/*.js'), ['test/a.js']);
  // absolute targets (inside the project) are compared as project-relative; outside the project matches nothing
  assert.deepEqual(out(['src/a.js', 'lib/b.js'], '/proj/src/a.js'), ['lib/b.js']);
  assert.deepEqual(out(['src/a.js', 'lib/b.js'], '/proj/src'), ['lib/b.js']);
  assert.deepEqual(out(['src/a.js'], '/elsewhere/src/a.js'), ['src/a.js']);
  // a character class is not mistaken for a literal, and an unclosed [ is literal
  assert.deepEqual(out(['src/[x.js', 'src/x.js'], 'src/[x.js'), ['src/x.js']);
});

test('R3-04: new files honour the umask; replacing keeps the existing mode', async (t) => {
  const dir = await createProject(t);
  const previous = process.umask(0o077);
  t.after(() => { process.umask(previous); });
  const a = path.join(dir, 'a.txt');
  await writeFileSafely(a, 'A');
  assert.equal((await fs.stat(a)).mode & 0o777, 0o600);
  process.umask(0o022);
  const b = path.join(dir, 'b.txt');
  await writeFileSafely(b, 'B');
  assert.equal((await fs.stat(b)).mode & 0o777, 0o644);
  process.umask(0);
  const c = path.join(dir, 'c.txt');
  await writeFileSafely(c, 'C');
  assert.equal((await fs.stat(c)).mode & 0o777, 0o666);
  await fs.chmod(a, 0o640);
  await writeFileSafely(a, 'A2');
  assert.equal((await fs.stat(a)).mode & 0o777, 0o640);
});

// ------------------------------------------------- final-pass fixes

test('R4-03: a Stryker report path that is a HARD LINK to another file is refused before the run and after it', async (t) => {
  const { dir, env, calls } = await strykerProject(t);
  const plans = path.join(dir, '.rlp-desk', 'plans');
  const sealed = path.join(plans, 'test-spec-x.md');
  await fs.mkdir(plans, { recursive: true });
  await fs.writeFile(sealed, 'SEALED');
  await fs.mkdir(path.join(dir, 'reports', 'mutation'), { recursive: true });
  await fs.link(sealed, path.join(dir, 'reports', 'mutation', 'mutation.json'));
  const r = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(r.code, 2);
  assert.equal(r.json.reason, 'report_path_unsafe');
  assert.match(r.json.detail, /hard link/);
  assert.equal((await callsOf(calls)).length, 0, 'tool not spawned');
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');

  // created during the run: not read
  await fs.rm(path.join(dir, 'reports'), { recursive: true });
  await writeStub(path.join(dir, 'node_modules', '.bin', 'stryker'), [
    'mkdir -p reports/mutation',
    'cp "$STUB_REPORT" reports/outside.json',
    'ln reports/outside.json reports/mutation/mutation.json',
  ].join('\n'));
  const during = await run(['run', '--tool', 'stryker', '--target', 'src', '--min-score', '0', '--json'], { dir, env });
  assert.equal(during.code, 2);
  assert.equal(during.json.reason, 'report_path_unsafe');
});

test('R4-03: a mutmut stats file that is a symlink or hard link is refused before export-cicd-stats runs', async (t) => {
  for (const kind of ['symlink', 'hardlink']) {
    const { dir, env, calls } = await mutmutProject(t);
    const sealed = path.join(dir, '.rlp-desk', 'plans', 'test-spec-x.md');
    await fs.mkdir(path.dirname(sealed), { recursive: true });
    await fs.writeFile(sealed, 'SEALED');
    await fs.mkdir(path.join(dir, 'mutants'), { recursive: true });
    if (kind === 'symlink') await fs.symlink(sealed, path.join(dir, 'mutants', 'mutmut-cicd-stats.json'));
    else await fs.link(sealed, path.join(dir, 'mutants', 'mutmut-cicd-stats.json'));
    const r = await run(['run', '--tool', 'mutmut', '--target', 'mypkg', '--min-score', '0', '--json'], { dir, env });
    assert.equal(r.code, 2, kind);
    assert.equal(r.json.reason, 'report_path_unsafe', kind);
    assert.ok(!(await callsOf(calls)).some((c) => c.startsWith('export-cicd-stats')), `${kind}: export not run`);
    assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED', kind);
  }
});

test('writeFileSafely: a destination that is a hard link to another file is replaced, never written through', async (t) => {
  const dir = await createProject(t);
  const victim = path.join(dir, 'victim.txt');
  await fs.writeFile(victim, 'VICTIM');
  const dest = path.join(dir, 'out.txt');
  await fs.link(victim, dest);
  await writeFileSafely(dest, 'NEW');
  assert.equal(await fs.readFile(victim, 'utf8'), 'VICTIM');
  assert.equal(await fs.readFile(dest, 'utf8'), 'NEW');
  assert.equal((await fs.stat(dest)).nlink, 1);
});
