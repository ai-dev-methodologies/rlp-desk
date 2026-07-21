// request-f §3 — operator ledger-seed. Behavioral tests: a real tmp git repo
// with a `.rlp-desk/plans/prd-<slug>.md` fixture. Success appends a PRD-bound,
// audit-visible (`seeded:true`) entry via the real CLI main(); every failure
// mode is nonzero AND leaves the ledger file untouched (fail-closed).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import { normalizeVerdict } from '../../src/node/shared/verdict-schema.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

const SLUG = 'demo';
const PRD_BODY = '### US-000: Zero\n- AC1: a\n### US-001: One\n- AC1: b\n';

function git(cwd, args) {
  const res = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (res.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${res.stderr}`);
  return res.stdout.trim();
}

// A real git repo with a committed .rlp-desk/plans/prd-demo.md and a claude-leg
// pass verdict for US-000. Returns handy paths + HEAD sha.
async function tmpRepo(t, { usId = 'US-000', prdBody = PRD_BODY } = {}) {
  const root = path.join(repoRoot, '.tmp', 'ledger-seed');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'case-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });

  const plans = path.join(dir, '.rlp-desk', 'plans');
  const memos = path.join(dir, '.rlp-desk', 'memos');
  await fs.mkdir(plans, { recursive: true });
  await fs.mkdir(memos, { recursive: true });
  await fs.writeFile(path.join(plans, `prd-${SLUG}.md`), prdBody);

  git(dir, ['init', '-q']);
  git(dir, ['config', 'user.email', 't@t']);
  git(dir, ['config', 'user.name', 't']);
  git(dir, ['add', '-A']);
  git(dir, ['commit', '-qm', 'c1']);
  const head = git(dir, ['rev-parse', 'HEAD']);

  const evidence = path.join(dir, 'verdict.json');
  await fs.writeFile(evidence, JSON.stringify({ us_id: usId, verdict: 'pass' }));

  const ledger = path.join(memos, `${SLUG}-verified.jsonl`);
  return { dir, plans, memos, ledger, evidence, head };
}

function capture() {
  const chunks = [];
  return { stream: { write: (s) => { chunks.push(s); return true; } }, text: () => chunks.join('') };
}

async function seed(dir, argv) {
  const out = capture();
  const err = capture();
  const code = await main(['ledger-seed', ...argv], { cwd: dir, stdout: out.stream, stderr: err.stream });
  return { code, out: out.text(), err: err.text() };
}

function readLedgerLines(ledger) {
  if (!fsSync.existsSync(ledger)) return [];
  return fsSync.readFileSync(ledger, 'utf8').split('\n').filter((l) => l.trim() !== '');
}

test('success: appends a PRD-bound entry with all fields correct', async (t) => {
  const { dir, ledger, evidence, head } = await tmpRepo(t);
  const { code, err } = await seed(dir, [
    SLUG, 'US-000', '--evidence', evidence, '--note', 'claude fresh x2 pass; codex old-doctrine fail',
  ]);
  assert.equal(code, 0, err);

  const lines = readLedgerLines(ledger);
  assert.equal(lines.length, 1);
  const entry = JSON.parse(lines[0]);

  assert.equal(entry.us_id, 'US-000');
  assert.equal(entry.commit, head, 'commit == HEAD by default');
  assert.equal(entry.seeded, true);
  assert.equal(entry.operator_note, 'claude fresh x2 pass; codex old-doctrine fail');
  assert.match(entry.verified_at, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal('iter' in entry, false, 'no iter field per §3 (no ledger reader needs it)');

  // prd == git hash-object of the PRD file.
  const expectedPrd = git(dir, ['hash-object', path.join(dir, '.rlp-desk', 'plans', `prd-${SLUG}.md`)]);
  assert.equal(entry.prd, expectedPrd);

  // File is relocked 0444 after the append.
  const mode = fsSync.statSync(ledger).mode & 0o777;
  assert.equal(mode, 0o444, `ledger should be 0444, got ${mode.toString(8)}`);
});

test('success: a second seed appends (append-only, no clobber of a 0444 ledger)', async (t) => {
  const { dir, ledger, evidence } = await tmpRepo(t);
  const first = await seed(dir, [SLUG, 'US-000', '--evidence', evidence, '--note', 'first']);
  assert.equal(first.code, 0, first.err);

  // Second US-001 evidence.
  const ev2 = path.join(dir, 'verdict-1.json');
  await fs.writeFile(ev2, JSON.stringify({ us_id: 'US-001', verdict: 'passed' })); // synonym
  const second = await seed(dir, [SLUG, 'US-001', '--evidence', ev2, '--note', 'second']);
  assert.equal(second.code, 0, second.err);

  const lines = readLedgerLines(ledger);
  assert.equal(lines.length, 2, 'append-only: both entries present');
  assert.equal(JSON.parse(lines[0]).us_id, 'US-000');
  assert.equal(JSON.parse(lines[1]).us_id, 'US-001');
  assert.equal(normalizeVerdict({ verdict: 'passed' }).verdict, 'pass'); // sanity: synonym accepted
});

// --- failure modes: each nonzero AND ledger NOT modified ---

async function assertFailsClosed(t, { mutate, argv, match }) {
  const ctx = await tmpRepo(t);
  const before = readLedgerLines(ctx.ledger); // typically []
  if (mutate) await mutate(ctx);
  const { code, err } = await seed(ctx.dir, argv(ctx));
  assert.notEqual(code, 0, 'must exit nonzero');
  if (match) assert.match(err, match);
  assert.deepEqual(readLedgerLines(ctx.ledger), before, 'ledger must be untouched on failure');
}

test('failure: evidence path missing', async (t) => {
  await assertFailsClosed(t, {
    argv: ({ dir }) => [SLUG, 'US-000', '--evidence', path.join(dir, 'nope.json'), '--note', 'n'],
    match: /evidence file not found/,
  });
});

test('failure: evidence invalid JSON', async (t) => {
  await assertFailsClosed(t, {
    mutate: async ({ evidence }) => { await fs.writeFile(evidence, 'not json {{{'); },
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence, '--note', 'n'],
    match: /not valid JSON/,
  });
});

test('failure: evidence verdict is fail', async (t) => {
  await assertFailsClosed(t, {
    mutate: async ({ evidence }) => { await fs.writeFile(evidence, JSON.stringify({ us_id: 'US-000', verdict: 'fail' })); },
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence, '--note', 'n'],
    match: /verdict is not "pass"/,
  });
});

test('failure: evidence us_id mismatch (incl. an "ALL" evidence file)', async (t) => {
  await assertFailsClosed(t, {
    mutate: async ({ evidence }) => { await fs.writeFile(evidence, JSON.stringify({ us_id: 'ALL', verdict: 'pass' })); },
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence, '--note', 'n'],
    match: /does not match US-000/,
  });
});

test('failure: PRD file missing', async (t) => {
  await assertFailsClosed(t, {
    mutate: async ({ dir }) => { await fs.rm(path.join(dir, '.rlp-desk', 'plans', `prd-${SLUG}.md`)); },
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence, '--note', 'n'],
    match: /PRD not found/,
  });
});

test('failure: us_id not present in PRD markers', async (t) => {
  await assertFailsClosed(t, {
    argv: ({ evidence }) => [SLUG, 'US-999', '--evidence', evidence, '--note', 'n'],
    // evidence us_id is US-000, so US-999 fails the evidence-match gate first —
    // still fail-closed. Use matching evidence to exercise the PRD-membership gate:
    match: /does not match US-999|not a US marker/,
  });
});

test('failure: us_id shape invalid', async (t) => {
  await assertFailsClosed(t, {
    argv: ({ evidence }) => [SLUG, 'US_000', '--evidence', evidence, '--note', 'n'],
    match: /invalid us_id/,
  });
});

test('failure: us_id in PRD but absent as a marker (matching evidence)', async (t) => {
  // PRD has US-000/US-001 only; seed US-002 with matching evidence → membership gate.
  await assertFailsClosed(t, {
    mutate: async ({ evidence }) => { await fs.writeFile(evidence, JSON.stringify({ us_id: 'US-002', verdict: 'pass' })); },
    argv: ({ evidence }) => [SLUG, 'US-002', '--evidence', evidence, '--note', 'n'],
    match: /not a US marker/,
  });
});

test('failure: --note missing', async (t) => {
  await assertFailsClosed(t, {
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence],
    match: /note is required/,
  });
});

test('failure: --commit not resolvable', async (t) => {
  await assertFailsClosed(t, {
    argv: ({ evidence }) => [SLUG, 'US-000', '--evidence', evidence, '--note', 'n', '--commit', 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'],
    match: /does not resolve to a commit/,
  });
});

test('failure: --commit resolvable but NOT an ancestor of HEAD (divergent branch)', async (t) => {
  const ctx = await tmpRepo(t);
  // Create a divergent commit on a side branch that is NOT an ancestor of HEAD.
  git(ctx.dir, ['checkout', '-q', '-b', 'side']);
  await fs.writeFile(path.join(ctx.dir, 'side.txt'), 'x');
  // Stage ONLY side.txt — a `git add -A` would track the untracked evidence
  // file, and the detached checkout below would then delete it.
  git(ctx.dir, ['add', 'side.txt']);
  git(ctx.dir, ['commit', '-qm', 'side commit']);
  const sideSha = git(ctx.dir, ['rev-parse', 'HEAD']);
  // Detach onto the original commit so HEAD == ctx.head and sideSha (its child)
  // is NOT an ancestor of HEAD — branch-name-agnostic (main vs master).
  git(ctx.dir, ['checkout', '-q', ctx.head]);

  const before = readLedgerLines(ctx.ledger);
  const { code, err } = await seed(ctx.dir, [
    SLUG, 'US-000', '--evidence', ctx.evidence, '--note', 'n', '--commit', sideSha,
  ]);
  assert.notEqual(code, 0);
  assert.match(err, /not an ancestor of HEAD/);
  assert.deepEqual(readLedgerLines(ctx.ledger), before, 'ledger untouched');
});
