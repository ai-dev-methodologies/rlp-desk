import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

// IMP-06 — the REAL upgrade path: postinstall over a 0o444-locked tree.
//
// Every real install leaves ~/.claude/ralph-desk files at chmod 0o444
// (write-protect + banner, v0.12.0). So "copy over a read-only tree" is the
// only upgrade path users ever exercise — postinstall.js carries dedicated
// unlockTree/removePath machinery (R-V5-1: EACCES on copy-over-0444;
// ENOTEMPTY on dir replace) that had ZERO test coverage: AC8.1 seeded 0644
// files, so a regression here would brick `npm install` upgrades for the
// whole user base while every gate stayed green.
//
// Load-bearing note (verified during authoring): POSIX unlink permission
// lives on the parent DIRECTORY, so 0o444 *files* in writable dirs are
// removable without unlockTree, and copyFile() has its own inline
// chmod-0644 for the copy-over-0444 EACCES case. What makes unlockTree
// itself load-bearing is a NON-WRITABLE DIRECTORY (0o555) inside the old
// node/ tree: rmSync cannot unlink its children until unlockTree chmods the
// dir 0o755. Case (d) below pins exactly that.
//
// Teeth checks (2026-07-07, recorded in the commit body):
//   - unlockTree no-op'd  → FAILS (rmSync EACCES/ENOTEMPTY on the 0o555 dir).
//   - copyFile's inline chmod removed → FAILS (EACCES copying over the
//     0o444 runner).

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'imp06-postinstall-locked');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    // The tree may be re-locked at 0o444 by postinstall; unlock before rm.
    await fs.chmod(directory, 0o755).catch(() => {});
    await execFileAsync('chmod', ['-R', 'u+w', directory]).catch(() => {});
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

test('IMP-06: postinstall upgrades over a 0o444-locked tree (EACCES + ENOTEMPTY + symlink-skip branches)', async (t) => {
  const fakeHome = await createTempDir(t);
  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  await fs.mkdir(path.join(deskDir, 'node'), { recursive: true });

  // (a) 0o444 top-level runtime file — the EACCES copy-over branch.
  const runnerPath = path.join(deskDir, 'run_ralph_desk.zsh');
  await fs.writeFile(runnerPath, '#!/bin/zsh\necho stale-locked\n', 'utf8');
  await fs.chmod(runnerPath, 0o444);

  // (b) 0o444 child inside the node/ subtree — the ENOTEMPTY dir-replace branch.
  const staleChild = path.join(deskDir, 'node', 'stale-locked.mjs');
  await fs.writeFile(staleChild, '// old locked runtime\n', 'utf8');
  await fs.chmod(staleChild, 0o444);

  // (c) symlink inside the tree — the symlink-skip branch: postinstall must
  // remove/replace the LINK without touching its target.
  const linkTarget = path.join(fakeHome, 'outside-target.txt');
  await fs.writeFile(linkTarget, 'do-not-touch\n', 'utf8');
  await fs.symlink(linkTarget, path.join(deskDir, 'node', 'link-to-outside'));

  // (d) NON-WRITABLE directory (0o555) with a child — the branch unlockTree
  // exists for: rmSync cannot unlink children of a read-only dir, so without
  // unlockTree's dir-chmod the node/ tree replacement throws EACCES/ENOTEMPTY.
  const lockedDir = path.join(deskDir, 'node', 'locked-dir');
  await fs.mkdir(lockedDir, { recursive: true });
  await fs.writeFile(path.join(lockedDir, 'stale-inner.mjs'), '// old\n', 'utf8');
  await fs.chmod(lockedDir, 0o555);

  const { stdout } = await execFileAsync(process.execPath, ['scripts/postinstall.js'], {
    cwd: repoRoot,
    env: { ...process.env, HOME: fakeHome },
  });
  assert.match(stdout, /Done!/);

  // Fresh content replaced the locked stale bodies.
  const runnerBody = await fs.readFile(runnerPath, 'utf8');
  assert.doesNotMatch(runnerBody, /stale-locked/, 'locked stale runner must be overwritten');
  assert.match(runnerBody, /Ralph Desk Tmux Runner/, 'fresh source body must land');
  assert.equal(await exists(staleChild), false, 'locked stale node/ child must be removed');
  assert.equal(await exists(lockedDir), false, '0o555 stale dir must be removed (unlockTree branch)');
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), true);

  // Symlink handled without touching its target.
  assert.equal(
    await fs.readFile(linkTarget, 'utf8'),
    'do-not-touch\n',
    'symlink TARGET must never be modified',
  );

  // Lock restored: installed files back at 0o444.
  const mode = (await fs.stat(runnerPath)).mode & 0o777;
  assert.equal(mode, 0o444, `installed runner must be re-locked 0o444 (got ${mode.toString(8)})`);
});
