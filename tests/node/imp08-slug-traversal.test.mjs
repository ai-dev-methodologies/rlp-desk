import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';

// IMP-08 — slug path-traversal in run/status/clean must be REJECTED, not
// normalized.
//
// normalizeSlug('../../x') === 'x' (collapse non-alnum + trim). So using
// normalizeSlug as a *guard* for the destructive/read commands silently
// RETARGETS `clean ../../x` onto a real neighboring campaign `x` — and a
// containment assert passes because `x` is inside deskRoot. The guard must
// REJECT any non-canonical slug (exit 2), matching the zsh hard-reject, so a
// traversal input never maps onto a real campaign.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'imp08-slug-traversal');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function exists(p) {
  try { await fs.access(p); return true; } catch { return false; }
}

function runMain(argv, cwd) {
  let stderr = '';
  let stdout = '';
  return main(argv, {
    cwd,
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
    // never actually spawn/scaffold — a valid slug should get past the guard
    // and hit these injectables, an invalid one must fail before them.
    spawnZsh: async () => 0,
    zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
    fileExists: () => false,
    readStatus: async () => 'STATUS_OK',
  }).then((code) => ({ code, stderr, stdout }));
}

test('IMP-08: `clean ../../x` is rejected and does NOT delete a real neighboring campaign', async (t) => {
  const cwd = await createTempDir(t);
  const deskRoot = path.join(cwd, '.rlp-desk');
  // A real neighboring campaign `x` (what `../../x` normalizes onto) + its runtime.
  const victimRuntime = path.join(deskRoot, 'logs', 'x', 'runtime');
  await fs.mkdir(victimRuntime, { recursive: true });
  await fs.writeFile(path.join(victimRuntime, 'status.json'), '{"iteration":9}');
  // An outside-the-desk sentinel that a raw path.join traversal could reach.
  const outsideSentinel = path.join(cwd, 'OUTSIDE_SENTINEL');
  await fs.writeFile(outsideSentinel, 'do-not-delete');

  const { code, stderr } = await runMain(['clean', '../../x'], cwd);

  assert.equal(code, 1, 'clean must reject a traversal slug (exit 1 via thrown error)');
  assert.match(stderr, /invalid slug|slug/i);
  assert.equal(await exists(victimRuntime), true, 'neighbor campaign `x` runtime must survive');
  assert.equal(await exists(outsideSentinel), true, 'outside sentinel must survive');
});

test('IMP-08: status/run reject a traversal slug', async (t) => {
  const cwd = await createTempDir(t);
  await fs.mkdir(path.join(cwd, '.rlp-desk'), { recursive: true });

  const st = await runMain(['status', '../../x'], cwd);
  assert.equal(st.code, 1);
  assert.doesNotMatch(st.stdout, /STATUS_OK/, 'status must not run on a traversal slug');

  const rn = await runMain(['run', '../../x', '--mode', 'tmux'], cwd);
  assert.equal(rn.code, 1);
});

test('IMP-08: a canonical slug still passes the guard (clean succeeds)', async (t) => {
  const cwd = await createTempDir(t);
  const runtime = path.join(cwd, '.rlp-desk', 'logs', 'my-feature-1', 'runtime');
  await fs.mkdir(runtime, { recursive: true });
  await fs.writeFile(path.join(runtime, 'status.json'), '{"iteration":1}');

  const { code } = await runMain(['clean', 'my-feature-1'], cwd);
  assert.equal(code, 0, 'canonical slug must be accepted');
  assert.equal(await exists(runtime), false, 'clean removes the runtime for a valid slug');
});

test('IMP-08: an uppercase/non-canonical (but non-traversal) slug is rejected', async (t) => {
  const cwd = await createTempDir(t);
  await fs.mkdir(path.join(cwd, '.rlp-desk'), { recursive: true });
  const { code, stderr } = await runMain(['status', 'My_App'], cwd);
  assert.equal(code, 1, 'non-canonical slug must be rejected (matches zsh hard-reject)');
  assert.match(stderr, /invalid slug|slug/i);
});
