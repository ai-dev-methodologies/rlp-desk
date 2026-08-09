// US-001: scripts/uninstall.js derives its removal set from the shared install
// manifest (scripts/install-manifest.js) instead of a private literal path list.
//
// Why this matters: a private list in the uninstaller is the same class of bug
// the manifest was created to kill — add an install entry, forget the uninstall
// entry, and users keep an orphaned 0o444 file forever (which also prevents the
// ralph-desk/ directory from ever being removed).
//
// House rules honored here (test-spec §Forbidden Shortcuts):
//   - never write to the real $HOME: every install/uninstall runs against a
//     mkdtempSync HOME, and the subprocess env HOME is overridden.
//   - never re-list the runtime paths in this file: expectations are computed
//     from manifest.runtimeSources(home) so this test cannot re-create the bug.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const manifestPath = path.join(repoRoot, 'scripts', 'install-manifest.js');
const uninstallPath = path.join(repoRoot, 'scripts', 'uninstall.js');
const postinstallPath = path.join(repoRoot, 'scripts', 'postinstall.js');

const manifest = require(manifestPath);
// Requiring the uninstaller must be side-effect-free (see AC5) — it is a module
// with a `require.main` guard, not a script that runs on import.
const uninstaller = require(uninstallPath);

const uninstallSource = fs.readFileSync(uninstallPath, 'utf8');

function tempHome(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    // Installed files are 0o444; unlock before removal or rmSync hits EACCES.
    try {
      execFileSync('chmod', ['-R', 'u+w', dir]);
    } catch {
      /* best effort */
    }
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function install(home) {
  execFileSync(process.execPath, [postinstallPath], {
    env: { ...process.env, HOME: home },
    stdio: 'pipe',
  });
}

function runUninstall(home) {
  return execFileSync(process.execPath, [uninstallPath], {
    env: { ...process.env, HOME: home },
    stdio: 'pipe',
  });
}

function fileTargets(home) {
  return uninstaller.removalTargets(home).files;
}

function manifestTargets(home) {
  return manifest.runtimeSources(home).map(([, targetPath]) => targetPath);
}

// Swap manifest.runtimeSources for the duration of `fn`. Both this file and
// uninstall.js resolve the same absolute path, so they share one require-cache
// instance — mutating the export here is observed by the uninstaller only if it
// reads the manifest at call time (which is exactly what AC4 pins down).
function withRuntimeSources(factory, fn) {
  const original = manifest.runtimeSources;
  manifest.runtimeSources = factory(original);
  try {
    return fn();
  } finally {
    manifest.runtimeSources = original;
  }
}

// ---------------------------------------------------------------------------
// AC1 — every single-file target comes from manifest.runtimeSources(home)
// ---------------------------------------------------------------------------

test('AC1: every manifest runtime target is in the uninstall removal set', () => {
  const home = '/tmp/rlp-ac1-home';
  const removal = new Set(fileTargets(home));
  const missing = manifestTargets(home).filter((target) => !removal.has(target));
  assert.deepEqual(missing, [], 'manifest entries absent from the removal set would be orphaned on uninstall');
  assert.ok(manifestTargets(home).length > 10, 'sanity: the manifest must actually carry the install set');
});

test('AC1: the removal set is exactly the manifest set plus documented non-manifest entries', () => {
  const home = '/tmp/rlp-ac1b-home';
  const { deskDir } = manifest.installLayout(home);
  const expected = [...manifestTargets(home), path.join(deskDir, 'UNLOCK.md')];
  assert.deepEqual([...fileTargets(home)].sort(), expected.sort());
  assert.equal(fileTargets(home).length, manifestTargets(home).length + 1, 'exactly one non-manifest entry is allowed');
});

test('AC1: uninstall.js contains no literal copy of any runtime path', () => {
  // The bug being removed was a second hand-maintained copy of the install set.
  // Deriving the forbidden strings from the manifest keeps this guard honest.
  const offenders = manifest
    .runtimeSources('/tmp/rlp-ac1c-home')
    .map(([, target]) => path.basename(target))
    .filter((basename) => uninstallSource.includes(basename));
  assert.deepEqual(offenders, [], 'runtime paths must live only in install-manifest.js');
  assert.match(uninstallSource, /install-manifest\.js/, 'uninstall.js must consume the shared manifest');
});

// ---------------------------------------------------------------------------
// AC2 (boundary) — UNLOCK.md is not a manifest entry but must still be removed
// ---------------------------------------------------------------------------

test('AC2: UNLOCK.md is genuinely not a manifest entry', () => {
  // Premise of this AC: postinstall's writeUnlockDoc() generates UNLOCK.md from
  // a string literal, so it has no source file and cannot be a manifest pair.
  const home = '/tmp/rlp-ac2-home';
  const unlockish = manifest.runtimeSources(home).filter(([source, target]) =>
    source.endsWith('UNLOCK.md') || path.basename(target) === 'UNLOCK.md');
  assert.deepEqual(unlockish, []);
});

test('AC2: UNLOCK.md is still in the removal set', () => {
  const home = '/tmp/rlp-ac2b-home';
  const { deskDir } = manifest.installLayout(home);
  assert.ok(fileTargets(home).includes(path.join(deskDir, 'UNLOCK.md')));
});

test('AC2: the non-manifest entry is explicitly commented', () => {
  // AC2 requires the exception be *documented* at the point of use, so the next
  // reader knows it is deliberate and not a leftover of the old literal list.
  const commentLines = uninstallSource
    .split('\n')
    .filter((line) => /^\s*\/\//.test(line));
  assert.ok(commentLines.some((line) => line.includes('UNLOCK.md')), 'UNLOCK.md needs an explanatory comment');
  assert.ok(commentLines.some((line) => /not a manifest entry/i.test(line)), 'the comment must state it is a non-manifest entry');
});

// ---------------------------------------------------------------------------
// AC3 (equivalence) — real install then real uninstall in a throwaway HOME
// ---------------------------------------------------------------------------

test('AC3: a real install is fully removed by a real uninstall', (t) => {
  const home = tempHome(t, 'rlp-uninstall-e2e-');
  install(home);

  const targets = manifestTargets(home);
  const { deskDir, commandsDir, docsDir, nodeDir } = manifest.installLayout(home);
  const unlockPath = path.join(deskDir, 'UNLOCK.md');

  // Fixture is real: the tree exists and the installed files are write-locked,
  // so the removal path must survive 0o444 (PRD boundary case).
  const notInstalled = targets.filter((target) => !fs.existsSync(target));
  assert.deepEqual(notInstalled, [], 'postinstall must have produced the whole manifest set');
  assert.ok(fs.existsSync(unlockPath), 'postinstall must have written UNLOCK.md');
  const locked = targets.filter((target) => (fs.statSync(target).mode & 0o222) === 0);
  assert.ok(locked.length > 0, 'sanity: installed files are chmod 0o444');

  runUninstall(home);

  const leftBehind = targets.filter((target) => fs.existsSync(target));
  assert.deepEqual(leftBehind, [], 'every manifest target must be gone after uninstall');

  // Equivalence, stated the way AC3 states it: the set the manifest-derived
  // uninstaller *declares* it removes is exactly what is gone from disk.
  const declared = uninstaller.removalTargets(home);
  const declaredLeft = [...declared.files, ...declared.directories].filter((p) => fs.existsSync(p));
  assert.deepEqual(declaredLeft, [], 'the declared removal set must match what was actually removed');

  assert.equal(fs.existsSync(unlockPath), false, 'UNLOCK.md must be gone (AC2 end-to-end)');
  assert.equal(fs.existsSync(path.join(commandsDir, 'rlp-desk.md')), false, 'the slash-command file must be gone');
  assert.equal(fs.existsSync(docsDir), false, 'the docs tree must be gone');
  assert.equal(fs.existsSync(nodeDir), false, 'the node runtime tree must be gone');
  assert.equal(fs.existsSync(deskDir), false, 'an emptied ralph-desk/ must be removed');
});

test('AC3 (boundary): a partially installed tree does not make uninstall throw', (t) => {
  const home = tempHome(t, 'rlp-uninstall-partial-');
  install(home);

  const targets = manifestTargets(home);
  const { deskDir, nodeDir } = manifest.installLayout(home);
  // Simulate a half-removed / hand-mangled install.
  for (const target of targets.slice(0, 3)) {
    fs.chmodSync(target, 0o644);
    fs.rmSync(target);
  }
  fs.rmSync(path.join(deskDir, 'UNLOCK.md'));
  execFileSync('chmod', ['-R', 'u+w', nodeDir]);
  fs.rmSync(nodeDir, { recursive: true, force: true });

  runUninstall(home); // execFileSync throws on a non-zero exit
  const leftBehind = targets.filter((target) => fs.existsSync(target));
  assert.deepEqual(leftBehind, []);
  assert.equal(fs.existsSync(deskDir), false);
});

test('AC3 (boundary): a non-empty ralph-desk/ is not removed', (t) => {
  const home = tempHome(t, 'rlp-uninstall-nonempty-');
  install(home);

  const { deskDir } = manifest.installLayout(home);
  const foreign = path.join(deskDir, 'my-own-notes.txt');
  fs.writeFileSync(foreign, 'user file, not ours\n');

  runUninstall(home);

  assert.ok(fs.existsSync(deskDir), 'a directory still holding user files must survive');
  assert.deepEqual(fs.readdirSync(deskDir), ['my-own-notes.txt']);
  const leftBehind = manifestTargets(home).filter((target) => fs.existsSync(target));
  assert.deepEqual(leftBehind, [], 'our own files are still all gone');
});

// ---------------------------------------------------------------------------
// AC4 (drift guard) — the removal set is DERIVED, not copied
// ---------------------------------------------------------------------------

test('AC4: a new manifest entry grows the removal set', () => {
  const home = '/tmp/rlp-ac4-home';
  const { deskDir } = manifest.installLayout(home);
  const synthetic = path.join(deskDir, 'synthetic-future-entry.md');
  const before = fileTargets(home).length;

  const grown = withRuntimeSources(
    (original) => (h) => [
      ...original(h),
      ['src/synthetic-future-entry.md', path.join(manifest.installLayout(h).deskDir, 'synthetic-future-entry.md')],
    ],
    () => fileTargets(home),
  );

  assert.equal(grown.length, before + 1, 'the removal set must track the manifest');
  assert.ok(grown.includes(synthetic), 'a future manifest entry must be removed without editing uninstall.js');
});

test('AC4: shrinking the manifest shrinks the removal set', () => {
  const home = '/tmp/rlp-ac4b-home';
  const only = path.join(manifest.installLayout(home).deskDir, 'solo.md');
  const shrunk = withRuntimeSources(
    () => (h) => [['src/solo.md', path.join(manifest.installLayout(h).deskDir, 'solo.md')]],
    () => fileTargets(home),
  );
  // 1 manifest entry + the single documented non-manifest entry.
  assert.equal(shrunk.length, 2);
  assert.ok(shrunk.includes(only));
});

test('AC4: the manifest is read at call time, not captured at module load', () => {
  // If uninstall.js destructured runtimeSources at require time, the swap below
  // would be invisible and the drift guard would silently stop working.
  const home = '/tmp/rlp-ac4c-home';
  const sentinel = path.join(manifest.installLayout(home).deskDir, 'call-time-sentinel.md');
  const seen = withRuntimeSources(
    () => (h) => [['src/call-time-sentinel.md', path.join(manifest.installLayout(h).deskDir, 'call-time-sentinel.md')]],
    () => fileTargets(home),
  );
  assert.ok(seen.includes(sentinel));
  assert.ok(!fileTargets(home).includes(sentinel), 'and the swap is properly restored afterwards');
});

test('AC4: a synthetic manifest entry is actually deleted from disk', (t) => {
  // The guard is on behavior, not just on the returned array.
  const home = tempHome(t, 'rlp-uninstall-drift-');
  const { deskDir } = manifest.installLayout(home);
  fs.mkdirSync(deskDir, { recursive: true });
  const synthetic = path.join(deskDir, 'synthetic-locked-entry.md');
  fs.writeFileSync(synthetic, 'installed by a future version\n');
  fs.chmodSync(synthetic, 0o444); // installed files are write-locked

  withRuntimeSources(
    () => (h) => [['src/synthetic-locked-entry.md', path.join(manifest.installLayout(h).deskDir, 'synthetic-locked-entry.md')]],
    () => uninstaller.uninstall(home),
  );

  assert.equal(fs.existsSync(synthetic), false, '0o444 files must be unlocked before removal');
});

// ---------------------------------------------------------------------------
// AC5 (negative) — code-only change; the uninstaller stays a safe module
// ---------------------------------------------------------------------------

test('AC5: uninstall.js parses cleanly', () => {
  execFileSync(process.execPath, ['--check', uninstallPath], { stdio: 'pipe' });
});

test('AC5: requiring uninstall.js does not uninstall anything', (t) => {
  // Making the removal set importable must never turn `require` into rm -rf:
  // this file, the leader tooling, and any future consumer import it while the
  // real $HOME holds a live install.
  const home = tempHome(t, 'rlp-uninstall-import-');
  const { deskDir } = manifest.installLayout(home);
  fs.mkdirSync(deskDir, { recursive: true });
  const canary = path.join(deskDir, 'UNLOCK.md');
  fs.writeFileSync(canary, 'canary\n');

  execFileSync(process.execPath, ['-e', `require(${JSON.stringify(uninstallPath)})`], {
    env: { ...process.env, HOME: home },
    stdio: 'pipe',
  });

  assert.ok(fs.existsSync(canary), 'import must be side-effect-free');
  assert.match(uninstallSource, /require\.main === module/, 'the entrypoint must be guarded');
});

test('AC5: the change is code-only — uninstall.js is not part of the install set', () => {
  const home = '/tmp/rlp-ac5-home';
  const installedSources = manifest.runtimeSources(home).map(([source]) => source);
  assert.ok(!installedSources.includes('scripts/uninstall.js'), 'no install re-sync is implied by this change');
  assert.ok(typeof uninstaller.removalTargets === 'function' && typeof uninstaller.uninstall === 'function');
});
