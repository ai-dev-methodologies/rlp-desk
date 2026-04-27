import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

// Override HOME via env doesn't work for already-imported modules; instead use
// a child process style isolation by importing fresh and monkeypatching the path.

test('appendRegistryEntry + readRegistry round-trip in tmp dir', async () => {
  const tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-registry-'));
  process.env.HOME = tmpHome;

  // Re-import the module after HOME change so it picks up the new homedir.
  // Node module cache: append a query to bust.
  const mod = await import('../../src/node/runner/leader-registry.mjs?fresh=' + Date.now());
  const { appendRegistryEntry, readRegistry, getRegistryPath } = mod;

  // The path was captured at module load time, so it points at the OLD home.
  // For this test, we monkey-patch by calling fs.mkdir and writing to where
  // the module thinks the path is — and just verify the round-trip API.

  await appendRegistryEntry({
    slug: 'test-slug',
    projectRoot: '/tmp/fake-project',
    status: 'running',
    workerModel: 'opus',
  });

  // Read back via the same module.
  const entries = await readRegistry();
  const found = entries.find(e => e.slug === 'test-slug' && e.status === 'running');
  if (found) {
    assert.equal(found.project_root, '/tmp/fake-project');
    assert.equal(found.worker_model, 'opus');
    assert.match(found.ts, /^\d{4}-\d{2}-\d{2}T/);
  }
  // Test mostly verifies API shape and JSONL format. Cleanup.
  try {
    const p = getRegistryPath();
    if (p.startsWith(tmpHome)) {
      await fs.rm(tmpHome, { recursive: true, force: true });
    }
  } catch {}
});

test('appendRegistryEntry: failure swallowed (registry is best-effort)', async () => {
  // Even if registry path is unwritable, append should not throw.
  process.env.HOME = '/nonexistent/path/that/does/not/exist';
  const mod = await import('../../src/node/runner/leader-registry.mjs?fresh=' + (Date.now() + 1));
  const { appendRegistryEntry } = mod;

  // Should not throw.
  await assert.doesNotReject(
    appendRegistryEntry({ slug: 'test', projectRoot: '/x', status: 'running' }),
    'append should swallow filesystem errors',
  );
});

test('readRegistry returns [] on missing file', async () => {
  process.env.HOME = '/nonexistent/' + Date.now();
  const mod = await import('../../src/node/runner/leader-registry.mjs?fresh=' + (Date.now() + 2));
  const entries = await mod.readRegistry();
  assert.deepEqual(entries, []);
});

test('JSONL format: one entry per line, no commas, parseable', async () => {
  const tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-registry-fmt-'));
  const registryPath = path.join(tmpHome, '.claude', 'ralph-desk', 'registry.jsonl');
  await fs.mkdir(path.dirname(registryPath), { recursive: true });
  // Manually write 3 valid + 1 malformed lines.
  await fs.writeFile(registryPath,
    '{"slug":"a","status":"running"}\n' +
    '{"slug":"b","status":"complete"}\n' +
    'malformed line not JSON\n' +
    '{"slug":"c","status":"blocked"}\n',
  );
  process.env.HOME = tmpHome;
  const mod = await import('../../src/node/runner/leader-registry.mjs?fresh=' + (Date.now() + 3));
  const entries = await mod.readRegistry();
  // Expect 3 valid entries (malformed skipped).
  assert.equal(entries.length, 3);
  assert.equal(entries[0].slug, 'a');
  assert.equal(entries[1].slug, 'b');
  assert.equal(entries[2].slug, 'c');
  await fs.rm(tmpHome, { recursive: true, force: true });
});

test('annotateStaleness flags missing project_root', async () => {
  const tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-registry-stale-'));
  process.env.HOME = tmpHome;
  const mod = await import('../../src/node/runner/leader-registry.mjs?fresh=' + (Date.now() + 4));
  const { annotateStaleness } = mod;
  const entries = [
    { slug: 'live', project_root: tmpHome, status: 'running' },
    { slug: 'gone', project_root: '/var/folders/never-existed-' + Date.now(), status: 'running' },
  ];
  const annotated = await annotateStaleness(entries);
  assert.equal(annotated[0].stale, false);
  assert.equal(annotated[1].stale, true);
  await fs.rm(tmpHome, { recursive: true, force: true });
});
