import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function makeTmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-runlegacy-'));
}

test('detectLegacyDeskInRunMode returns null when no legacy directory', async () => {
  const { detectLegacyDeskInRunMode } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const tmp = makeTmp();
  const result = detectLegacyDeskInRunMode(tmp);
  assert.equal(result, null);
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('detectLegacyDeskInRunMode returns guidance object when legacy exists', async () => {
  const { detectLegacyDeskInRunMode } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const tmp = makeTmp();
  fs.mkdirSync(path.join(tmp, '.claude', 'ralph-desk'), { recursive: true });

  const result = detectLegacyDeskInRunMode(tmp);
  assert.notEqual(result, null);
  assert.equal(result.legacyPath, path.join(tmp, '.claude', 'ralph-desk'));
  assert.match(result.message, /mv \.claude\/ralph-desk \.rlp-desk/);
  assert.match(result.message, /Legacy/);

  fs.rmSync(tmp, { recursive: true, force: true });
});

test('detectLegacyDeskInRunMode honors RLP_DESK_RUNTIME_DIR target', async () => {
  const { detectLegacyDeskInRunMode } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const tmp = makeTmp();
  fs.mkdirSync(path.join(tmp, '.claude', 'ralph-desk'), { recursive: true });

  const result = detectLegacyDeskInRunMode(tmp, { RLP_DESK_RUNTIME_DIR: '.rlp-runtime' });
  assert.notEqual(result, null);
  assert.match(result.message, /mv \.claude\/ralph-desk \.rlp-runtime/);

  fs.rmSync(tmp, { recursive: true, force: true });
});
