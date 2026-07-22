// vision-adopt §1a (gate-receipt test-spec coverage) + §1c (contract-revision
// audit chain). Node side.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  writeGateReceipt,
  verifyGateReceipt,
  computePrdContentHash,
  computeLegacyPrdHash,
  listContractFiles,
  computeFileHashes,
  appendContractRevisions,
  gateReceiptPath,
} from '../../src/node/util/gate-receipt.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function tmpPlans(t) {
  const root = path.join(repoRoot, '.tmp', 'vision-adopt');
  await fsp.mkdir(root, { recursive: true });
  const dir = await fsp.mkdtemp(path.join(root, 'case-'));
  const plans = path.join(dir, 'plans');
  await fsp.mkdir(plans, { recursive: true });
  t.after(async () => { await fsp.rm(dir, { recursive: true, force: true }); });
  return { dir, plans };
}

// ---------------------------------------------------------------------------
// §1a: the sealed set now covers test-spec files.
// ---------------------------------------------------------------------------
test('§1a: computePrdContentHash includes test-spec files; editing test-spec is a mismatch', async (t) => {
  const { plans } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  const prdOnly = computePrdContentHash(plans, 'demo');

  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts main\n');
  const withTs = computePrdContentHash(plans, 'demo');
  assert.notEqual(prdOnly, withTs, 'adding a test-spec must change the sealed hash');

  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1' });
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');

  // Edit the test-spec → mismatch (test-spec is now sealed).
  await fsp.appendFile(path.join(plans, 'test-spec-demo.md'), 'EDIT\n');
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'mismatch');
});

test('§1a: receipt records the full contract set + per-file hashes (schema 1.1)', async (t) => {
  const { plans } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  await fsp.writeFile(path.join(plans, 'prd-demo-US-001.md'), 'us1\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo-US-001.md'), 'ts1\n');
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:2' });
  const receipt = JSON.parse(fs.readFileSync(gateReceiptPath(plans, 'demo'), 'utf8'));

  assert.equal(receipt.schema_version, '1.1');
  assert.deepEqual(receipt.prd_files, [
    'prd-demo.md', 'prd-demo-US-001.md', 'test-spec-demo.md', 'test-spec-demo-US-001.md',
  ]);
  assert.deepEqual(
    Object.keys(receipt.file_hashes).sort(),
    ['prd-demo-US-001.md', 'prd-demo.md', 'test-spec-demo-US-001.md', 'test-spec-demo.md'],
  );
  assert.deepEqual(receipt.file_hashes, computeFileHashes(plans, 'demo'));
});

// HIGH-1: a released schema-1.0 receipt (PRD-only prd_sha256, no file_hashes)
// must not false-mismatch once test-spec files exist alongside it.
async function writeLegacyReceipt(plans, slug) {
  const legacy = {
    schema_version: '1.0',
    slug,
    prd_sha256: computeLegacyPrdHash(plans, slug),
    prd_files: ['prd-' + slug + '.md'],
    scorecard: 'PASS:1',
    passed_at: '2026-01-01T00:00:00Z',
  };
  await fsp.writeFile(gateReceiptPath(plans, slug), JSON.stringify(legacy, null, 2) + '\n');
}

test('§1a HIGH-1: schema-1.0 receipt + untouched PRD+test-spec → ok, no revision record', async (t) => {
  const { plans, dir } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  await writeLegacyReceipt(plans, 'demo');

  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');
  const log = path.join(dir, 'logs', 'demo', 'contract-revisions.jsonl');
  assert.deepEqual(appendContractRevisions(plans, 'demo', log), []);
  assert.equal(fs.existsSync(log), false);
});

test('§1a HIGH-1: schema-1.0 receipt still detects a real PRD edit (mismatch + record)', async (t) => {
  const { plans, dir } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  await writeLegacyReceipt(plans, 'demo');

  await fsp.appendFile(path.join(plans, 'prd-demo.md'), 'EDIT\n');
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'mismatch');
  const log = path.join(dir, 'logs', 'demo', 'contract-revisions.jsonl');
  const rec = appendContractRevisions(plans, 'demo', log);
  assert.equal(rec.length, 1);
  assert.equal(rec[0].file, '<contract-bundle>');
  assert.equal(rec[0].receipt_version, '1.0');
  // The record's new_hash uses the PRD-only basis (comparable to the 1.0 old_hash).
  assert.equal(rec[0].new_hash, computeLegacyPrdHash(plans, 'demo'));
});

test('§1a HIGH-1: editing ONLY the test-spec does NOT mismatch a 1.0 receipt (PRD-only basis)', async (t) => {
  const { plans } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  await writeLegacyReceipt(plans, 'demo');

  await fsp.appendFile(path.join(plans, 'test-spec-demo.md'), 'EDIT\n');
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');
});

test('§1a: no PRD → empty hash even if a test-spec exists (PRD is the anchor)', async (t) => {
  const { plans } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  assert.equal(computePrdContentHash(plans, 'demo'), '');
  assert.deepEqual(listContractFiles(plans, 'demo'), []);
});

// ---------------------------------------------------------------------------
// §1c: contract-revision audit chain.
// ---------------------------------------------------------------------------
test('§1c: drift appends a per-file revision record naming the changed file', async (t) => {
  const { plans, dir } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts\n');
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1' });
  const before = computeFileHashes(plans, 'demo')['test-spec-demo.md'];

  await fsp.writeFile(path.join(plans, 'test-spec-demo.md'), 'ts EDITED\n');
  const log = path.join(dir, 'logs', 'demo', 'contract-revisions.jsonl');
  const appended = appendContractRevisions(plans, 'demo', log);

  assert.equal(appended.length, 1);
  assert.equal(appended[0].file, 'test-spec-demo.md');
  assert.equal(appended[0].old_hash, before);
  assert.equal(appended[0].new_hash, computeFileHashes(plans, 'demo')['test-spec-demo.md']);
  assert.equal(appended[0].receipt_version, '1.1');
  assert.ok(appended[0].ts);

  // No author/actor attribution field (git-blame identification was rejected).
  assert.ok(!('author' in appended[0]) && !('actor' in appended[0]));
});

test('§1c: append-then-lock (0444) + idempotent on repeat', async (t) => {
  const { plans, dir } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1' });
  await fsp.appendFile(path.join(plans, 'prd-demo.md'), 'DRIFT\n');

  const log = path.join(dir, 'logs', 'demo', 'contract-revisions.jsonl');
  const first = appendContractRevisions(plans, 'demo', log);
  assert.equal(first.length, 1);
  const mode = fs.statSync(log).mode & 0o777;
  assert.equal(mode, 0o444, `log must be 0444 between appends, got ${mode.toString(8)}`);

  // Same drift → no duplicate record.
  const second = appendContractRevisions(plans, 'demo', log);
  assert.equal(second.length, 0);
  const lines = fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean);
  assert.equal(lines.length, 1);

  // A FURTHER edit → a new record (new new_hash).
  await fsp.appendFile(path.join(plans, 'prd-demo.md'), 'MORE\n');
  const third = appendContractRevisions(plans, 'demo', log);
  assert.equal(third.length, 1);
  assert.equal(fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).length, 2);
});

test('§1c: no receipt or no drift → no records', async (t) => {
  const { plans, dir } = await tmpPlans(t);
  await fsp.writeFile(path.join(plans, 'prd-demo.md'), 'prd\n');
  const log = path.join(dir, 'logs', 'demo', 'contract-revisions.jsonl');
  // No receipt yet.
  assert.deepEqual(appendContractRevisions(plans, 'demo', log), []);
  // Seal, no drift.
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1' });
  assert.deepEqual(appendContractRevisions(plans, 'demo', log), []);
  assert.equal(fs.existsSync(log), false);
});
