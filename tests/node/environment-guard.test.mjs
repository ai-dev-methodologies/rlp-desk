import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Hermeticity: campaign-main-loop.mjs loads the model ladder at import time
// from the ambient override path — force a nonexistent override BEFORE the
// dynamic import (same guard as effort-timeout.test.mjs / models-ladder.test.mjs).
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
process.env.RLP_DESK_MODELS_FILE = path.join(repoRoot, '.tmp', 'environment-guard-test', 'no-override.json');
const { verdictFailureCategory, escalationEligible } = await import('../../src/node/runner/campaign-main-loop.mjs');

// Governance ("Verifier: reasoning in verify-verdict.json") classifies failures
// per ISSUE, so the field lands at any of three placements depending on the
// producer. Reading only top-level let an issue-level `environment` verdict
// climb the ladder on a verifier safety-classifier refusal.
test('verdictFailureCategory resolves all three documented placements', () => {
  assert.equal(
    verdictFailureCategory({ verdict: 'fail', failure_category: 'environment' }),
    'environment',
  );
  assert.equal(
    verdictFailureCategory({ verdict: 'fail', issues: [{ id: 'AC1', failure_category: 'environment' }] }),
    'environment',
  );
  assert.equal(
    verdictFailureCategory({ verdict: 'fail', checks: [{ name: 'IL-1', failure_category: 'flaky' }] }),
    'flaky',
  );
  assert.equal(
    verdictFailureCategory({ verdict: 'fail', issues: [{ id: 'AC1', description: 'off-by-one' }] }),
    '',
  );
});

test('verdictFailureCategory precedence and malformed inputs', () => {
  // Explicit top-level classification wins over per-issue entries.
  assert.equal(
    verdictFailureCategory({
      failure_category: 'implementation',
      issues: [{ failure_category: 'environment' }],
    }),
    'implementation',
  );
  // First category found wins within a list; entries without one are skipped.
  assert.equal(
    verdictFailureCategory({ issues: [{ id: 'AC1' }, { id: 'AC2', failure_category: 'spec' }] }),
    'spec',
  );
  // checks[] is only consulted when issues[] yields nothing.
  assert.equal(
    verdictFailureCategory({
      issues: [{ failure_category: 'integration' }],
      checks: [{ failure_category: 'environment' }],
    }),
    'integration',
  );
  for (const bad of [undefined, null, '', 'environment', 42, {}, { issues: 'not-an-array' }, { issues: [null] }]) {
    assert.equal(verdictFailureCategory(bad), '', `expected '' for ${JSON.stringify(bad)}`);
  }
});

test('escalationEligible truth table — only environment/flaky block the ladder', () => {
  for (const placement of ['top', 'issues', 'checks']) {
    const build = (cat) => {
      if (placement === 'top') return { failure_category: cat };
      if (placement === 'issues') return { issues: [{ id: 'AC1', failure_category: cat }] };
      return { checks: [{ name: 'IL-1', failure_category: cat }] };
    };
    assert.equal(escalationEligible(build('environment')), false, `environment/${placement}`);
    assert.equal(escalationEligible(build('flaky')), false, `flaky/${placement}`);
    for (const cat of ['spec', 'implementation', 'integration', '']) {
      assert.equal(escalationEligible(build(cat)), true, `${cat || '<empty>'}/${placement}`);
    }
  }
  // Absent / unusable verdicts fail open toward escalation (pre-change behavior).
  assert.equal(escalationEligible({ verdict: 'fail' }), true);
  assert.equal(escalationEligible(undefined), true);
  assert.equal(escalationEligible(null), true);
});
