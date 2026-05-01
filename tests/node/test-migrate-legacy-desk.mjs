import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function makeTmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-mig-'));
}

test('migrateLegacyDesk renames legacy to new when only legacy exists', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();
  const legacy = path.join(tmp, '.claude', 'ralph-desk');
  fs.mkdirSync(path.join(legacy, 'memos'), { recursive: true });
  fs.writeFileSync(path.join(legacy, 'memos', 'x.md'), 'data', 'utf8');

  const result = migrateLegacyDesk(tmp);
  assert.equal(result.action, 'migrated');

  const newDeskRoot = path.join(tmp, '.rlp-desk');
  assert.equal(fs.existsSync(newDeskRoot), true);
  assert.equal(fs.existsSync(path.join(newDeskRoot, 'memos', 'x.md')), true);
  assert.equal(fs.existsSync(legacy), false);
  assert.equal(fs.existsSync(path.join(tmp, '.rlp-desk-migration.lock')), false, 'lock cleaned up');

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('migrateLegacyDesk refuses when both legacy and new exist (conflict)', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();
  fs.mkdirSync(path.join(tmp, '.claude', 'ralph-desk'), { recursive: true });
  fs.mkdirSync(path.join(tmp, '.rlp-desk'), { recursive: true });

  assert.throws(
    () => migrateLegacyDesk(tmp),
    /both directories exist/i,
  );
  assert.equal(fs.existsSync(path.join(tmp, '.rlp-desk-migration.lock')), false, 'lock cleaned up after error');

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('migrateLegacyDesk is no-op when neither directory exists', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();

  const result = migrateLegacyDesk(tmp);
  assert.equal(result.action, 'noop');
  assert.equal(fs.existsSync(path.join(tmp, '.rlp-desk-migration.lock')), false);

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('migrateLegacyDesk is no-op when only new directory exists', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();
  fs.mkdirSync(path.join(tmp, '.rlp-desk'), { recursive: true });

  const result = migrateLegacyDesk(tmp);
  assert.equal(result.action, 'noop');

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('migrateLegacyDesk refuses when concurrent lock exists', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();
  fs.mkdirSync(path.join(tmp, '.claude', 'ralph-desk'), { recursive: true });

  const lockPath = path.join(tmp, '.rlp-desk-migration.lock');
  fs.writeFileSync(lockPath, String(process.pid), 'utf8');

  assert.throws(
    () => migrateLegacyDesk(tmp),
    /already in progress/i,
  );

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('migrateLegacyDesk respects RLP_DESK_RUNTIME_DIR env override target', async () => {
  const { migrateLegacyDesk } = await import('../../src/node/init/campaign-initializer.mjs');
  const tmp = makeTmp();
  const legacy = path.join(tmp, '.claude', 'ralph-desk');
  fs.mkdirSync(legacy, { recursive: true });

  const result = migrateLegacyDesk(tmp, { RLP_DESK_RUNTIME_DIR: '.rlp-runtime' });
  assert.equal(result.action, 'migrated');
  assert.equal(fs.existsSync(path.join(tmp, '.rlp-runtime')), true);
  assert.equal(fs.existsSync(legacy), false);

  fs.rmSync(tmp, { recursive: true, force: true });
});
