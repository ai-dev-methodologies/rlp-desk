import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

test('resolveDeskRoot returns rootDir/.rlp-desk by default', async () => {
  const { resolveDeskRoot } = await import('../../src/node/util/desk-root.mjs');
  const result = resolveDeskRoot('/tmp/proj', {});
  assert.equal(result, path.join('/tmp/proj', '.rlp-desk'));
});

test('resolveDeskRoot honors RLP_DESK_RUNTIME_DIR env override', async () => {
  const { resolveDeskRoot } = await import('../../src/node/util/desk-root.mjs');
  const result = resolveDeskRoot('/tmp/proj', { RLP_DESK_RUNTIME_DIR: '.rlp-runtime' });
  assert.equal(result, path.join('/tmp/proj', '.rlp-runtime'));
});

test('resolveDeskRoot ignores empty env override', async () => {
  const { resolveDeskRoot } = await import('../../src/node/util/desk-root.mjs');
  const result = resolveDeskRoot('/tmp/proj', { RLP_DESK_RUNTIME_DIR: '' });
  assert.equal(result, path.join('/tmp/proj', '.rlp-desk'));
});

test('resolveDeskRoot rejects path traversal in env override', async () => {
  const { resolveDeskRoot } = await import('../../src/node/util/desk-root.mjs');
  assert.throws(
    () => resolveDeskRoot('/tmp/proj', { RLP_DESK_RUNTIME_DIR: '../escape' }),
    /must not contain/i,
  );
});

test('resolveDeskRoot rejects absolute path env override', async () => {
  const { resolveDeskRoot } = await import('../../src/node/util/desk-root.mjs');
  assert.throws(
    () => resolveDeskRoot('/tmp/proj', { RLP_DESK_RUNTIME_DIR: '/etc/passwd' }),
    /must be relative/i,
  );
});

test('LEGACY_DESK_REL exports legacy relative path', async () => {
  const { LEGACY_DESK_REL } = await import('../../src/node/util/desk-root.mjs');
  assert.equal(LEGACY_DESK_REL, path.join('.claude', 'ralph-desk'));
});
