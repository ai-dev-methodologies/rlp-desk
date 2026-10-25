import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import { buildTrend } from '../../src/node/reporting/campaign-trend.mjs';

// D1 (TODO L32) — cross-campaign trend analysis. `trend` is a read-only Node
// CLI subcommand over campaign*.jsonl. Design: .omc/artifacts/backlog-2026-10-25/d-roadmap-design.md D1.
//
// Hand-computed fixtures (counted ranges are stated per fixture below):
//   v1 (6 rows, iter 1-6): US-001 fail/pass, US-002 pass, US-003 fail/pass, ALL pass
//   v2 (5 rows, iter 1-5): US-001 pass, US-002 pass, US-003 fail/pass, ALL pass

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createProject(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'd1-campaign-trend');
  await fs.mkdir(tempRoot, { recursive: true });
  const dir = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

function zshRow({ iter, usId, verdict, w, v, model = 'sonnet', codex = 'N/A', consensus = 'off' }) {
  return {
    iter,
    us_id: usId,
    worker_model: model,
    worker_engine: 'claude',
    verifier_engine: 'claude',
    claude_verdict: verdict,
    codex_verdict: codex,
    consensus_mode: consensus,
    consecutive_failures: 0,
    model_upgraded: 0,
    duration_worker_s: w,
    duration_verifier_s: v,
    slug: 's',
    timestamp: `2026-10-0${Math.min(iter, 9)}T00:00:00Z`,
  };
}

function nodeRow({ iter, usId, verdict, duration, model = 'sonnet' }) {
  return {
    iter,
    us_id: usId,
    worker_model: model,
    worker_engine: 'claude',
    verdict,
    duration,
    timestamp: `2026-10-0${Math.min(iter, 9)}T00:00:00Z`,
  };
}

const V1 = [
  zshRow({ iter: 1, usId: 'US-001', verdict: 'fail', w: 40, v: 10, model: 'haiku' }),
  zshRow({ iter: 2, usId: 'US-001', verdict: 'pass', w: 30, v: 10, model: 'haiku' }),
  zshRow({ iter: 3, usId: 'US-002', verdict: 'pass', w: 20, v: 5 }),
  zshRow({ iter: 4, usId: 'US-003', verdict: 'fail', w: 60, v: 10 }),
  zshRow({ iter: 5, usId: 'US-003', verdict: 'pass', w: 20, v: 10 }),
  zshRow({ iter: 6, usId: 'ALL', verdict: 'pass', w: 10, v: 10 }),
];
// v1 totals: iterations 6, us_total 3, us_passed 3, first_pass 1/3 -> 0.3333,
// pass 4 / fail 2, duration 50+40+25+70+30+20 = 235, worker_model change haiku->sonnet = 1.

const V2 = [
  zshRow({ iter: 1, usId: 'US-001', verdict: 'pass', w: 20, v: 10 }),
  zshRow({ iter: 2, usId: 'US-002', verdict: 'pass', w: 15, v: 5 }),
  zshRow({ iter: 3, usId: 'US-003', verdict: 'fail', w: 30, v: 10 }),
  zshRow({ iter: 4, usId: 'US-003', verdict: 'pass', w: 15, v: 10 }),
  zshRow({ iter: 5, usId: 'ALL', verdict: 'pass', w: 5, v: 10 }),
];
// v2 totals: iterations 5, us_total 3, us_passed 3, first_pass 2/3 -> 0.6667,
// pass 4 / fail 1, duration 30+20+40+25+15 = 130, model changes 0.

// Same data as V2 in the Node-native row shape (verdict + duration).
const V2_NODE = [
  nodeRow({ iter: 1, usId: 'US-001', verdict: 'pass', duration: 30 }),
  nodeRow({ iter: 2, usId: 'US-002', verdict: 'pass', duration: 20 }),
  nodeRow({ iter: 3, usId: 'US-003', verdict: 'fail', duration: 40 }),
  nodeRow({ iter: 4, usId: 'US-003', verdict: 'pass', duration: 25 }),
  nodeRow({ iter: 5, usId: 'ALL', verdict: 'pass', duration: 15 }),
];

async function writeJsonl(file, rows, rawLines = []) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const body = [...rows.map((r) => JSON.stringify(r)), ...rawLines].join('\n') + '\n';
  await fs.writeFile(file, body, 'utf8');
}

function analyticsDir(project, slug = 's', hash = 'ab12cd34') {
  return path.join(project, '.rlp-desk', 'analytics', `${slug}--${hash}`);
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

async function snapshot(dir) {
  const out = {};
  async function walk(d) {
    for (const entry of await fs.readdir(d, { withFileTypes: true })) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) await walk(full);
      else out[path.relative(dir, full)] = await fs.readFile(full, 'utf8');
    }
  }
  await walk(dir);
  return out;
}

async function standardProject(t) {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign-v1.jsonl'), V1);
  await writeJsonl(path.join(dir, 'campaign-v2.jsonl'), V2);
  await writeJsonl(path.join(dir, 'campaign.jsonl'), V2_NODE);
  return { project, dir };
}

test('1: labels run oldest -> newest and metrics match the hand computation (zsh-shaped rows)', async (t) => {
  const { project } = await standardProject(t);
  const { code, stdout } = await runMain(['trend', 's', '--json'], project);
  assert.equal(code, 0);
  const doc = JSON.parse(stdout);
  assert.equal(doc.schema, 'rlp-desk.trend/1');
  assert.equal(doc.slug, 's');
  assert.deepEqual(doc.runs.map((r) => r.label), ['v1', 'v2', 'current']);
  const v1 = doc.runs[0];
  assert.equal(v1.rows, 6);
  assert.equal(v1.iterations, 6);
  assert.equal(v1.us_total, 3);
  assert.equal(v1.us_passed, 3);
  assert.equal(v1.first_pass_rate, 0.3333);
  assert.deepEqual(v1.verdicts, { pass: 4, fail: 2, split: 0, other: 0 });
  assert.equal(v1.duration_total_s, 235);
  assert.equal(v1.model_upgrades, 1);
  assert.deepEqual(v1.worker_models, ['haiku', 'sonnet']);
  assert.equal(v1.malformed, 0);
  const v2 = doc.runs[1];
  assert.equal(v2.iterations, 5);
  assert.equal(v2.first_pass_rate, 0.6667);
  assert.deepEqual(v2.verdicts, { pass: 4, fail: 1, split: 0, other: 0 });
  assert.equal(v2.duration_total_s, 130);
  assert.equal(v2.model_upgrades, 0);
  // delta v1 -> v2
  const d = doc.deltas[0];
  assert.equal(d.from, 'v1');
  assert.equal(d.to, 'v2');
  assert.equal(d.iterations, -1);
  assert.equal(d.first_pass_rate, 0.3334);
  assert.equal(d.fail, -1);
  assert.equal(d.duration_total_s, -105);
  assert.equal(d.model_upgrades, -1);
  assert.equal(d.verdicts.iterations, 'improved');
  assert.equal(d.verdicts.first_pass_rate, 'improved');
  assert.equal(doc.first_vs_last.from, 'v1');
  assert.equal(doc.first_vs_last.to, 'current');
});

test('2: Node-native row shape (verdict + duration) yields the same metrics as zsh rows', async (t) => {
  const { project } = await standardProject(t);
  const { stdout } = await runMain(['trend', 's', '--json'], project);
  const doc = JSON.parse(stdout);
  const strip = (r) => ({ ...r, label: undefined, first_ts: undefined, last_ts: undefined });
  assert.deepEqual(strip(doc.runs[2]), strip(doc.runs[1]));
  assert.deepEqual(doc.deltas[1].verdicts, {
    iterations: 'unchanged',
    first_pass_rate: 'unchanged',
    fail: 'unchanged',
    duration_total_s: 'unchanged',
    model_upgrades: 'unchanged',
    us_passed: 'unchanged',
  });
});

test('3: campaign-v10 sorts after campaign-v9 (numeric, not lexicographic)', async (t) => {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign-v10.jsonl'), V2);
  await writeJsonl(path.join(dir, 'campaign-v9.jsonl'), V1);
  await writeJsonl(path.join(dir, 'campaign-v2.jsonl'), V1);
  const { code, stdout } = await runMain(['trend', 's', '--json'], project);
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(stdout).runs.map((r) => r.label), ['v2', 'v9', 'v10']);
});

test('4: consensus disagreement counts as split, never as pass', async (t) => {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign.jsonl'), [
    zshRow({ iter: 1, usId: 'US-001', verdict: 'pass', w: 1, v: 1, codex: 'fail', consensus: 'all' }),
    zshRow({ iter: 2, usId: 'US-002', verdict: 'pass', w: 1, v: 1, codex: 'pass', consensus: 'all' }),
  ]);
  const { stdout } = await runMain(['trend', 's', '--json'], project);
  const run = JSON.parse(stdout).runs[0];
  assert.deepEqual(run.verdicts, { pass: 1, fail: 0, split: 1, other: 0 });
  assert.equal(run.us_total, 2);
  assert.equal(run.us_passed, 1);
  assert.equal(run.first_pass_rate, 0.5);
});

test('5: corrupt and null lines are counted as malformed, exit stays 0, warning emitted', async (t) => {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign-v1.jsonl'), V1, ['{not json', 'null']);
  await writeJsonl(path.join(dir, 'campaign.jsonl'), V2);
  const json = await runMain(['trend', 's', '--json'], project);
  assert.equal(json.code, 0);
  const doc = JSON.parse(json.stdout);
  assert.equal(doc.runs[0].malformed, 2);
  assert.equal(doc.runs[0].rows, 6);
  assert.ok(doc.warnings.includes('v1: 2 malformed row(s) skipped'), JSON.stringify(doc.warnings));
  const md = await runMain(['trend', 's'], project);
  assert.equal(md.code, 0);
  assert.match(md.stdout, /v1: 2 malformed row\(s\) skipped/);
});

test('6: single run exits 0 with no deltas; zero runs and missing analytics exit 1', async (t) => {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign.jsonl'), V1);
  const one = await runMain(['trend', 's', '--json'], project);
  assert.equal(one.code, 0);
  const doc = JSON.parse(one.stdout);
  assert.deepEqual(doc.deltas, []);
  assert.equal(doc.first_vs_last, null);
  const md = await runMain(['trend', 's'], project);
  assert.equal(md.code, 0);
  assert.match(md.stdout, /need >= 2 runs for deltas/);

  const empty = await createProject(t);
  await fs.mkdir(analyticsDir(empty), { recursive: true });
  const none = await runMain(['trend', 's'], empty);
  assert.equal(none.code, 1);
  assert.match(none.stderr, /no campaign\*\.jsonl/);

  const missing = await createProject(t);
  const gone = await runMain(['trend', 's'], missing);
  assert.equal(gone.code, 1);
  assert.match(gone.stderr, /no analytics/);
});

test('7: direction labels follow the fixed table (lower is better for iterations, higher for first_pass_rate)', () => {
  const base = {
    rows: 1, iterations: 9, us_total: 4, us_passed: 4, first_pass_rate: 0.5,
    verdicts: { pass: 4, fail: 5, split: 0, other: 0 }, model_upgrades: 1,
    worker_models: [], duration_total_s: 100, first_ts: null, last_ts: null, malformed: 0,
  };
  const better = { ...base, label: 'v2', iterations: 6 };
  const worse = { ...base, label: 'v2', first_pass_rate: 0.25, us_passed: 3 };
  const same = { ...base, label: 'v2' };
  const a = { ...base, label: 'v1' };
  const improved = buildTrend({ slug: 's', analyticsDir: 'x', runs: [a, better] }).deltas[0];
  assert.equal(improved.iterations, -3);
  assert.equal(improved.verdicts.iterations, 'improved');
  const regressed = buildTrend({ slug: 's', analyticsDir: 'x', runs: [a, worse] }).deltas[0];
  assert.equal(regressed.first_pass_rate, -0.25);
  assert.equal(regressed.verdicts.first_pass_rate, 'regressed');
  assert.equal(regressed.verdicts.us_passed, 'regressed');
  const unchanged = buildTrend({ slug: 's', analyticsDir: 'x', runs: [a, same] }).deltas[0];
  assert.ok(Object.values(unchanged.verdicts).every((v) => v === 'unchanged'));
  // higher duration is worse
  const slower = buildTrend({ slug: 's', analyticsDir: 'x', runs: [a, { ...base, label: 'v2', duration_total_s: 150 }] }).deltas[0];
  assert.equal(slower.verdicts.duration_total_s, 'regressed');
});

test('8: us_id ALL rows count toward iterations and durations but not per-US metrics', async (t) => {
  const project = await createProject(t);
  const dir = analyticsDir(project);
  await writeJsonl(path.join(dir, 'campaign.jsonl'), [
    zshRow({ iter: 1, usId: 'US-001', verdict: 'pass', w: 10, v: 0 }),
    zshRow({ iter: 2, usId: 'ALL', verdict: 'fail', w: 5, v: 5 }),
  ]);
  const run = JSON.parse((await runMain(['trend', 's', '--json'], project)).stdout).runs[0];
  assert.equal(run.iterations, 2);
  assert.equal(run.us_total, 1);
  assert.equal(run.us_passed, 1);
  assert.equal(run.first_pass_rate, 1);
  assert.equal(run.duration_total_s, 20);
  assert.deepEqual(run.verdicts, { pass: 1, fail: 1, split: 0, other: 0 });
});

test('9: --json is byte-identical across invocations; markdown carries the direction table', async (t) => {
  const { project } = await standardProject(t);
  const a = await runMain(['trend', 's', '--json'], project);
  const b = await runMain(['trend', 's', '--json'], project);
  assert.equal(a.stdout, b.stdout);
  assert.equal(JSON.parse(a.stdout).schema, 'rlp-desk.trend/1');
  const md = await runMain(['trend', 's'], project);
  assert.match(md.stdout, /\| v1 \|/);
  assert.match(md.stdout, /Reading/);
  assert.match(md.stdout, /lower is better/i);
});

test('10: read-only by default; --out writes exactly one new file', async (t) => {
  const { project } = await standardProject(t);
  const before = await snapshot(project);
  await runMain(['trend', 's', '--json'], project);
  await runMain(['trend', 's'], project);
  assert.deepEqual(await snapshot(project), before);

  const outFile = path.join(project, 'trend.md');
  const res = await runMain(['trend', 's', '--out', outFile], project);
  assert.equal(res.code, 0);
  const after = await snapshot(project);
  const added = Object.keys(after).filter((k) => !(k in before));
  assert.deepEqual(added, ['trend.md']);
  assert.equal(after['trend.md'], res.stdout);
  for (const k of Object.keys(before)) assert.equal(after[k], before[k]);
});

test('11: pointer wins over a stale <slug>--* dir; two dirs without a pointer exit 1 naming both', async (t) => {
  const project = await createProject(t);
  const stale = analyticsDir(project, 's', 'aaaaaaaa');
  const real = analyticsDir(project, 's', 'bbbbbbbb');
  await writeJsonl(path.join(stale, 'campaign.jsonl'), V1);
  await writeJsonl(path.join(real, 'campaign.jsonl'), V2);
  const ambiguous = await runMain(['trend', 's'], project);
  assert.equal(ambiguous.code, 1);
  assert.match(ambiguous.stderr, /s--aaaaaaaa/);
  assert.match(ambiguous.stderr, /s--bbbbbbbb/);
  assert.match(ambiguous.stderr, /--dir/);

  await fs.writeFile(path.join(project, '.rlp-desk', 'analytics', 's.current'), `${real}\n`, 'utf8');
  const pointed = await runMain(['trend', 's', '--json'], project);
  assert.equal(pointed.code, 0);
  const doc = JSON.parse(pointed.stdout);
  assert.equal(doc.runs[0].iterations, 5); // V2, not the stale V1 (6)
  assert.match(doc.analytics_dir, /s--bbbbbbbb$/);
});

test('12: dispatch and help; traversal slug is rejected; unknown option is a usage error', async (t) => {
  const project = await createProject(t);
  const help = await runMain(['trend', '--help'], project);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /Usage: node src\/node\/run\.mjs trend/);
  const top = await runMain(['--help'], project);
  assert.match(top.stdout, /^ {2}trend /m);
  const bad = await runMain(['trend', '../x'], project);
  assert.equal(bad.code, 1);
  assert.match(bad.stderr, /invalid slug/);
  const opt = await runMain(['trend', 's', '--bogus'], project);
  assert.equal(opt.code, 64);
  const last = await runMain(['trend', 's', '--last', '0'], project);
  assert.equal(last.code, 64);
});

test('13: no-slug mode lists every slug sorted by name with newest-vs-previous', async (t) => {
  const project = await createProject(t);
  const beta = analyticsDir(project, 'beta', 'cccccccc');
  const alpha = analyticsDir(project, 'alpha', 'dddddddd');
  await writeJsonl(path.join(beta, 'campaign.jsonl'), V1);
  await writeJsonl(path.join(alpha, 'campaign-v1.jsonl'), V1);
  await writeJsonl(path.join(alpha, 'campaign.jsonl'), V2);
  await fs.writeFile(path.join(project, '.rlp-desk', 'analytics', 'beta.current'), `${beta}\n`, 'utf8');
  const { code, stdout } = await runMain(['trend', '--json'], project);
  assert.equal(code, 0);
  const doc = JSON.parse(stdout);
  assert.equal(doc.schema, 'rlp-desk.trend/1');
  assert.deepEqual(doc.slugs.map((s) => s.slug), ['alpha', 'beta']);
  assert.equal(doc.slugs[0].run_count, 2);
  assert.equal(doc.slugs[0].newest_vs_previous.from, 'v1');
  assert.equal(doc.slugs[0].newest_vs_previous.to, 'current');
  assert.equal(doc.slugs[1].run_count, 1);
  assert.equal(doc.slugs[1].newest_vs_previous, null);
});

test('14: --last N keeps the newest N runs; --dir overrides discovery', async (t) => {
  const { project, dir } = await standardProject(t);
  const last = JSON.parse((await runMain(['trend', 's', '--last', '2', '--json'], project)).stdout);
  assert.deepEqual(last.runs.map((r) => r.label), ['v2', 'current']);
  assert.equal(last.first_vs_last.from, 'v2');

  const other = await createProject(t);
  const viaDir = await runMain(['trend', 's', '--dir', dir, '--json'], other);
  assert.equal(viaDir.code, 0);
  assert.equal(JSON.parse(viaDir.stdout).runs.length, 3);
});

test('15: explicit --dir without any campaign*.jsonl (missing or empty) exits 1 in both modes', async (t) => {
  const project = await createProject(t);
  const missing = path.join(project, 'nope');
  const empty = path.join(project, 'empty');
  await fs.mkdir(empty, { recursive: true });
  for (const dir of [missing, empty]) {
    const summary = await runMain(['trend', '--dir', dir], project);
    assert.equal(summary.code, 1, `summary mode, ${path.basename(dir)}`);
    assert.match(summary.stderr, /no campaign\*\.jsonl/);
    assert.equal(summary.stdout, '');
    const slug = await runMain(['trend', 's', '--dir', dir], project);
    assert.equal(slug.code, 1, `slug mode, ${path.basename(dir)}`);
    assert.match(slug.stderr, /no campaign\*\.jsonl/);
  }
});

test('16: --out is refused inside any .rlp-desk/plans (relative escape, symlinked parent, symlinked file); nothing is written', async (t) => {
  const { project, dir } = await standardProject(t);
  const plans = path.join(project, '.rlp-desk', 'plans');
  const sealed = path.join(plans, 'test-spec-s.md');
  await fs.mkdir(plans, { recursive: true });
  await fs.writeFile(sealed, 'SEALED');
  await fs.symlink(plans, path.join(project, 'plink'));
  await fs.symlink(sealed, path.join(project, 'flink.md'));
  await fs.symlink(path.join(plans, 'not-yet.md'), path.join(project, 'dangling.md'));
  const sub = path.join(project, 'packages', 'x');
  await fs.mkdir(sub, { recursive: true });
  const attempts = [
    [project, ['trend', 's', '--out', path.join('.rlp-desk', 'plans', 'test-spec-s.md')]],
    [sub, ['trend', 's', '--dir', dir, '--out', path.join('..', '..', '.rlp-desk', 'plans', 'test-spec-s.md')]],
    [project, ['trend', 's', '--out', path.join('plink', 'test-spec-s.md')]],
    [project, ['trend', 's', '--out', 'flink.md']],
    [project, ['trend', 's', '--out', 'dangling.md']],
    [project, ['trend', 's', '--out', path.join('.RLP-DESK', 'PLANS', 'new.md')]],
  ];
  for (const [cwd, argv] of attempts) {
    const res = await runMain(argv, cwd);
    assert.equal(res.code, 64, argv.join(' '));
    assert.match(res.stderr, /plans|symlink/);
    assert.equal(res.stdout, '');
  }
  assert.equal(await fs.readFile(sealed, 'utf8'), 'SEALED');
  assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-s.md']);
});
