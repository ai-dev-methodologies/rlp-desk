import test from 'node:test';
import assert from 'node:assert/strict';

test('T1: shouldRunFlywheel returns false when flywheel=off', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('off', { consecutive_failures: 3 }), false);
});

test('T2: shouldRunFlywheel returns true when flywheel=on-fail and consecutive_failures > 0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 1 }), true);
});

test('T3: shouldRunFlywheel returns false when flywheel=on-fail and consecutive_failures=0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 0 }), false);
});
