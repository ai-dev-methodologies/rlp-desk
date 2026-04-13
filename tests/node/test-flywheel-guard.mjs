import test from 'node:test';
import assert from 'node:assert/strict';

test('G1: RUN_DEFAULTS includes flywheelGuard off and flywheelGuardModel opus', async () => {
  const { main } = await import('../../src/node/run.mjs');
  assert.ok(main);
});

test('G2: --flywheel-guard flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  const code = await main(['run', 'test-slug', '--flywheel-guard'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard/);
});

test('G3: --flywheel-guard-model flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  const code = await main(['run', 'test-slug', '--flywheel-guard-model'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard-model/);
});

test('G4: help text includes flywheel guard flags', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  await main(['--help'], {
    cwd: '/tmp',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.match(stream.data, /--flywheel-guard off\|on/);
  assert.match(stream.data, /--flywheel-guard-model MODEL/);
});
