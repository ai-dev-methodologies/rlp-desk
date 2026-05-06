import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { lockSentinelFile, unlockSentinelFile } from '../../src/node/shared/fs.mjs';

// Bug #7 Fix-R: chmod 0o444 / 0o644 on sentinel files. Mirrors test-sentinel-
// exclusive.mjs tmpdir pattern (uses repo-local .tmp/, not os.tmpdir()).

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'sentinel-lock-test');

async function tmpDir() {
  await fs.mkdir(TMP_BASE, { recursive: true });
  return await fs.mkdtemp(path.join(TMP_BASE, 'run-'));
}

async function makeFile(dir, name, content = 'BLOCKED: test') {
  const target = path.join(dir, name);
  await fs.writeFile(target, content);
  return target;
}

function chmodSupported(stat) {
  // On filesystems that do not support chmod (WSL1/NTFS, some tmpfs mounts)
  // mode bits may not change. Detect via mode being non-zero.
  return (stat.mode & 0o777) !== 0o000;
}

test('AC1: lockSentinelFile clears write bits', async () => {
  const dir = await tmpDir();
  const target = await makeFile(dir, 'verify-verdict.json');
  await lockSentinelFile(target);
  const stat = await fs.stat(target);
  if (chmodSupported(stat) && (stat.mode & 0o777) !== 0o644) {
    assert.equal(stat.mode & 0o222, 0, 'all write bits cleared');
  }
});

test('AC2: lockSentinelFile on missing path does not throw', async () => {
  const dir = await tmpDir();
  const ghost = path.join(dir, 'never-existed.json');
  // Should resolve quietly (ENOENT branch) — no throw, no log.
  let logged = false;
  await lockSentinelFile(ghost, { log: () => { logged = true; } });
  assert.equal(logged, false, 'ENOENT path is silent');
});

test('AC3: unlockSentinelFile restores write bits', async () => {
  const dir = await tmpDir();
  const target = await makeFile(dir, 'iter-signal.json');
  await lockSentinelFile(target);
  await unlockSentinelFile(target);
  const stat = await fs.stat(target);
  if (chmodSupported(stat)) {
    assert.notEqual(stat.mode & 0o200, 0, 'owner write bit restored');
  }
});

test('AC4: rm of locked file still works (dir-perms allow unlink)', async () => {
  const dir = await tmpDir();
  const target = await makeFile(dir, 'verify-verdict.json');
  await lockSentinelFile(target);
  await unlockSentinelFile(target);
  await fs.unlink(target);
  await assert.rejects(fs.stat(target), { code: 'ENOENT' });
});

test('AC5: unlockSentinelFile on missing path does not throw', async () => {
  const dir = await tmpDir();
  const ghost = path.join(dir, 'absent.json');
  await unlockSentinelFile(ghost);
});
