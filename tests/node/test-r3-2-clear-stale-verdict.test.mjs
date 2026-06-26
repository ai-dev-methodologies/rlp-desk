// R3-2 — Node parity with zsh R3-1 (run_ralph_desk.zsh:4074).
//
// The Node leader consumes the verdict via pollForSignal(paths.verdictFile),
// which returns the first valid JSON it reads with NO mtime/freshness gate. The
// verdict file is left on disk after consumption (loop-top only unlocks; the
// reaper kills the pane, not the file). So before each verifier dispatch the
// leader must clear the prior verdict, else:
//   - runFinalSequentialVerify re-reads US-(n-1)'s verdict for US-(n), and
//   - a finalize iteration that skips loop-top cleanup accepts a leftover verdict.
//
// These tests pin both halves with PRODUCTION code paths: the real
// clearStaleVerdict helper and the real pollForSignal poller.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

import { clearStaleVerdict } from '../../src/node/runner/campaign-main-loop.mjs';
import { pollForSignal } from '../../src/node/polling/signal-poller.mjs';

const testFile = fileURLToPath(import.meta.url);

async function tempDir(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'r3-2-'));
  t.after(async () => {
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  });
  return dir;
}

test('clearStaleVerdict removes an existing (0o444-locked) verdict file', async (t) => {
  const dir = await tempDir(t);
  const verdict = path.join(dir, 'slug-verify-verdict.json');
  await fs.writeFile(verdict, JSON.stringify({ verdict: 'pass', us_id: 'US-001' }), 'utf8');
  await fs.chmod(verdict, 0o444); // mirror the sentinel lock the leader applies

  await clearStaleVerdict(verdict);

  await assert.rejects(fs.access(verdict), /ENOENT/, 'verdict file should be gone');
});

test('clearStaleVerdict is a no-op when the verdict file is missing (and skips falsy paths)', async (t) => {
  const dir = await tempDir(t);
  const verdict = path.join(dir, 'absent-verify-verdict.json');
  // Must not throw on a missing file (idempotent cleanup contract), and must
  // skip undefined/null entries (defensive — call sites pass two paths).
  await clearStaleVerdict(verdict, undefined, null);
  await assert.rejects(fs.access(verdict), /ENOENT/);
});

test('clearStaleVerdict clears BOTH the canonical and legacy verdict paths', async (t) => {
  // HIGH (codex R3-2 review): the main-loop poll passes legacyVerdictFile as a
  // no-freshness-gate fallback, so a stale legacy verdict must be cleared too.
  const dir = await tempDir(t);
  const canonical = path.join(dir, 'slug-verify-verdict.json');
  const legacy = path.join(dir, 'legacy-slug-verify-verdict.json');
  for (const f of [canonical, legacy]) {
    await fs.writeFile(f, JSON.stringify({ verdict: 'pass', us_id: 'US-001' }), 'utf8');
    await fs.chmod(f, 0o444);
  }

  await clearStaleVerdict(canonical, legacy);

  await assert.rejects(fs.access(canonical), /ENOENT/, 'canonical verdict should be gone');
  await assert.rejects(fs.access(legacy), /ENOENT/, 'legacy verdict should be gone');
});

test('clearStaleVerdict propagates a non-ENOENT unlink failure instead of swallowing it', async (t) => {
  // MEDIUM (codex R3-2 review): swallowing every fs.rm error would leave a stale
  // verdict on disk to be consumed by the next poll. A directory target is a
  // deterministic non-ENOENT failure (fs.rm without recursive rejects on a dir).
  const dir = await tempDir(t);
  const asDir = path.join(dir, 'verdict-is-a-dir');
  await fs.mkdir(asDir);
  t.after(async () => { await fs.chmod(asDir, 0o755).catch(() => {}); });

  await assert.rejects(
    clearStaleVerdict(asDir),
    (err) => Boolean(err) && err.code !== 'ENOENT',
    'a real unlink failure must surface (so a stale verdict can never be silently consumed)',
  );
});

test('real pollForSignal returns a STALE verdict immediately (no freshness gate)', async (t) => {
  // This is the bug R3-2 guards against: without a pre-dispatch clear, the very
  // next poll grabs whatever valid JSON is already on disk.
  const dir = await tempDir(t);
  const verdict = path.join(dir, 'slug-verify-verdict.json');
  const stale = { verdict: 'pass', us_id: 'US-001', round: 1 };
  await fs.writeFile(verdict, JSON.stringify(stale), 'utf8');

  const got = await pollForSignal(verdict, { paneId: null, timeoutMs: 2000, pollIntervalMs: 25 });
  assert.deepEqual(got, stale, 'poll must surface the stale verdict — proves there is no mtime gate');
});

test('after clearStaleVerdict, pollForSignal waits (times out) for a fresh verdict', async (t) => {
  // The fix: once the stale verdict is cleared, the poll no longer has anything
  // to read and blocks until the real verifier writes — modeled here as "no
  // fresh write before the deadline", so the poll must time out rather than
  // return the previous verdict.
  const dir = await tempDir(t);
  const verdict = path.join(dir, 'slug-verify-verdict.json');
  await fs.writeFile(verdict, JSON.stringify({ verdict: 'pass', us_id: 'US-001' }), 'utf8');
  await fs.chmod(verdict, 0o444);

  await clearStaleVerdict(verdict);

  await assert.rejects(
    pollForSignal(verdict, { paneId: null, timeoutMs: 300, pollIntervalMs: 25 }),
    (err) => err && err.name === 'TimeoutError',
    'with the stale verdict cleared, the poll must wait for a fresh write, not return the old one',
  );
});

void testFile;
