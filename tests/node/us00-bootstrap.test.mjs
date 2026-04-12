import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

function getScratchDir(testName) {
  const safeName = testName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');

  return path.join(repoRoot, '.tmp', 'us00-bootstrap-tests', String(process.pid), safeName);
}

test('US-00 AC1 happy: resolveProjectPath returns an absolute path inside the repo', async () => {
  const { resolveProjectPath, projectRoot } = await import('../../src/node/shared/paths.mjs');
  const resolved = resolveProjectPath('src', 'scripts', 'run_ralph_desk.zsh');

  assert.equal(projectRoot, repoRoot);
  assert.equal(resolved, path.join(repoRoot, 'src', 'scripts', 'run_ralph_desk.zsh'));
});

test('US-00 AC1 boundary: resolveProjectPath with no segments returns the repo root', async () => {
  const { resolveProjectPath } = await import('../../src/node/shared/paths.mjs');

  assert.equal(resolveProjectPath(), repoRoot);
});

test('US-00 AC1 negative: resolveProjectPath rejects traversal outside the repo root', async () => {
  const { resolveProjectPath } = await import('../../src/node/shared/paths.mjs');

  assert.throws(() => resolveProjectPath('..'), /outside the project root/);
});

test('US-00 AC2 happy: writeFileAtomic creates a new file under the repo root', async (t) => {
  const { writeFileAtomic } = await import('../../src/node/shared/fs.mjs');
  const scratchRoot = getScratchDir(t.name);
  const target = path.join(scratchRoot, 'nested', 'artifact.txt');

  await fs.rm(scratchRoot, { recursive: true, force: true });

  await writeFileAtomic(target, 'first-pass');

  assert.equal(await fs.readFile(target, 'utf8'), 'first-pass');
});

test('US-00 AC2 boundary: writeFileAtomic overwrites existing content and leaves no tmp file behind', async (t) => {
  const { writeFileAtomic } = await import('../../src/node/shared/fs.mjs');
  const scratchRoot = getScratchDir(t.name);
  const target = path.join(scratchRoot, 'overwrite.txt');

  await fs.rm(scratchRoot, { recursive: true, force: true });
  await fs.mkdir(scratchRoot, { recursive: true });
  await fs.writeFile(target, 'stale');
  await writeFileAtomic(target, 'fresh');

  const directoryEntries = await fs.readdir(path.dirname(target));
  assert.equal(await fs.readFile(target, 'utf8'), 'fresh');
  assert.deepEqual(directoryEntries, ['overwrite.txt']);
});

test('US-00 AC2 negative: writeFileAtomic rejects writes outside the repo root', async () => {
  const { writeFileAtomic } = await import('../../src/node/shared/fs.mjs');
  const outsideTarget = path.join(path.dirname(repoRoot), 'us00-outside.txt');

  await assert.rejects(
    () => writeFileAtomic(outsideTarget, 'blocked'),
    /outside the project root/,
  );
});
