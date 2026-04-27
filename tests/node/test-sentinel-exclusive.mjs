import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeSentinelExclusive } from '../../src/node/shared/fs.mjs';

// v5.7 §4.24 — first-writer-wins semantics for sentinel files.
// Note: writeSentinelExclusive uses ensureProjectPath, which restricts writes
// to within the repo root. Tests therefore use a project-local .tmp dir
// (gitignored) instead of os.tmpdir().

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'sentinel-test');

async function tmpDir() {
  await fs.mkdir(TMP_BASE, { recursive: true });
  return await fs.mkdtemp(path.join(TMP_BASE, 'run-'));
}

test('first call writes the sentinel', async () => {
  const dir = await tmpDir();
  const target = path.join(dir, 'blocked.md');
  const result = await writeSentinelExclusive(target, 'BLOCKED: first');
  assert.equal(result.wrote, true);
  const body = await fs.readFile(target, 'utf8');
  assert.equal(body, 'BLOCKED: first');
});

test('second call refuses to overwrite (first-writer-wins)', async () => {
  const dir = await tmpDir();
  const target = path.join(dir, 'blocked.md');
  await writeSentinelExclusive(target, 'BLOCKED: first');
  const result = await writeSentinelExclusive(target, 'BLOCKED: second');
  assert.equal(result.wrote, false);
  assert.equal(result.reason, 'already_exists');
  const body = await fs.readFile(target, 'utf8');
  assert.equal(body, 'BLOCKED: first', 'content must be from first writer');
});

test('parallel race — exactly one writer wins', async () => {
  const dir = await tmpDir();
  const target = path.join(dir, 'blocked.md');
  const writers = [];
  for (let i = 0; i < 20; i++) {
    writers.push(writeSentinelExclusive(target, `BLOCKED: writer ${i}`));
  }
  const results = await Promise.all(writers);
  const winners = results.filter((r) => r.wrote);
  const losers = results.filter((r) => !r.wrote);
  assert.equal(winners.length, 1, 'exactly one writer wins');
  assert.equal(losers.length, 19, 'all others see already_exists');
  losers.forEach((r) => assert.equal(r.reason, 'already_exists'));
});

test('creates parent directory if missing', async () => {
  const dir = await tmpDir();
  const target = path.join(dir, 'memos', 'subdir', 'blocked.md');
  const result = await writeSentinelExclusive(target, 'BLOCKED: nested');
  assert.equal(result.wrote, true);
  const body = await fs.readFile(target, 'utf8');
  assert.equal(body, 'BLOCKED: nested');
});

// v5.7 §4.24: writeSentinelExclusive intentionally does NOT call
// ensureProjectPath — sentinels are written under campaign root (any path),
// not the rlp-desk source root. Caller is responsible for path validation.
test('writes outside rlp-desk repo root succeed (campaign root semantics)', async () => {
  const tmpExternal = await fs.mkdtemp('/tmp/sentinel-external-');
  const target = path.join(tmpExternal, 'blocked.md');
  const result = await writeSentinelExclusive(target, 'BLOCKED: external');
  assert.equal(result.wrote, true);
  const body = await fs.readFile(target, 'utf8');
  assert.equal(body, 'BLOCKED: external');
  await fs.rm(tmpExternal, { recursive: true, force: true });
});

test('filesystem errors other than target-EEXIST propagate', async () => {
  // /dev/null is a char device; mkdir on it gives EEXIST (which here is NOT
  // the sentinel-already-exists case — the parent itself is unwriteable).
  // Either way the function must throw, not silently succeed.
  await assert.rejects(() => writeSentinelExclusive('/dev/null/blocked.md', 'x'));
});
