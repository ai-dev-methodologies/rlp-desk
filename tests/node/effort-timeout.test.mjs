import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Hermeticity: campaign-main-loop.mjs loads the model ladder at import time
// from the ambient override path — force a nonexistent override BEFORE the
// dynamic import (same guard as models-ladder.test.mjs).
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
process.env.RLP_DESK_MODELS_FILE = path.join(repoRoot, '.tmp', 'effort-timeout-test', 'no-override.json');
const { effectiveIterTimeoutMs } = await import('../../src/node/runner/campaign-main-loop.mjs');

test('effort-aware timeout: x2 for :max, x1.5 for :xhigh, base otherwise', () => {
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-luna:max'), 1_200_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-terra:max'), 1_200_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-luna:xhigh'), 900_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-sol:high'), 600_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'haiku'), 600_000);
  assert.equal(effectiveIterTimeoutMs(600_000, undefined), 600_000);
});
