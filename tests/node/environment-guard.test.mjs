import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Hermeticity: campaign-main-loop.mjs loads the model ladder at import time
// from the ambient override path — force a nonexistent override BEFORE the
// dynamic import (same guard as effort-timeout.test.mjs / models-ladder.test.mjs).
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
process.env.RLP_DESK_MODELS_FILE = path.join(repoRoot, '.tmp', 'environment-guard-test', 'no-override.json');
const {
  verdictFailureCategory,
  escalationEligible,
  recordFailureCounters,
  nextWorkerModel,
} = await import('../../src/node/runner/campaign-main-loop.mjs');

// Governance ("Verifier: reasoning in verify-verdict.json") classifies failures
// per ISSUE, so the field lands at any of three placements depending on the
// producer. Reading only top-level let an issue-level `environment` verdict
// climb the ladder on a verifier safety-classifier refusal.
test('verdictFailureCategory resolves all four documented placements', () => {
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
  // reasoning[] is the per-check array the verifier contract actually emits
  // (Verdict JSON block in init_ralph_desk.zsh).
  assert.equal(
    verdictFailureCategory({
      verdict: 'fail',
      reasoning: [{ check: 'IL-1 Evidence Gate', decision: 'fail', failure_category: 'environment' }],
    }),
    'environment',
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
  // Placement precedence: issues[] → reasoning[] → checks[].
  assert.equal(
    verdictFailureCategory({
      issues: [{ failure_category: 'integration' }],
      reasoning: [{ failure_category: 'environment' }],
      checks: [{ failure_category: 'spec' }],
    }),
    'integration',
  );
  assert.equal(
    verdictFailureCategory({
      reasoning: [{ failure_category: 'environment' }],
      checks: [{ failure_category: 'spec' }],
    }),
    'environment',
  );
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
  for (const placement of ['top', 'issues', 'reasoning', 'checks']) {
    const build = (cat) => {
      if (placement === 'top') return { failure_category: cat };
      if (placement === 'issues') return { issues: [{ id: 'AC1', failure_category: cat }] };
      if (placement === 'reasoning') return { reasoning: [{ check: 'IL-1', failure_category: cat }] };
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

// --- ladder rung arithmetic (N1) --------------------------------------------
// The guard on the model ASSIGNMENT is not sufficient on its own: the rung is
// `stage = floor(counter / 3)` walked from the ORIGINAL model, so if
// environment failures advance the counter that feeds it, a later genuine
// failure climbs a rung it never earned. These drive the real exported
// `recordFailureCounters` + `nextWorkerModel` — not a copy of the rule — so
// removing the eligibility gate in the source fails them.
const envVerdict = { verdict: 'fail', issues: [{ id: 'AC1', failure_category: 'environment' }] };
const implVerdict = { verdict: 'fail', issues: [{ id: 'AC1', failure_category: 'implementation' }] };

function runFailureSequence(verdicts, startModel = 'gpt-5.6-luna:high') {
  const state = { worker_model: startModel, consecutive_failures: 0, escalation_eligible_failures: 0 };
  for (const verdict of verdicts) {
    const eligible = recordFailureCounters(state, verdict);
    // Terminal escalation still walks the ALL-failures counter (unchanged).
    if (nextWorkerModel(state.worker_model, state.consecutive_failures) === 'BLOCKED') {
      return { ...state, blocked: true };
    }
    if (eligible) {
      const ladderModel = nextWorkerModel(state.worker_model, state.escalation_eligible_failures);
      if (ladderModel !== 'BLOCKED') state.worker_model = ladderModel;
    }
  }
  return { ...state, blocked: false };
}

test('N1-A: environment failures do not advance the rung for a later real failure', () => {
  // A: env, env, implementation — the implementation failure is the FIRST
  // eligible one, so it must behave exactly like case B.
  const a = runFailureSequence([envVerdict, envVerdict, implVerdict]);
  assert.equal(a.worker_model, 'gpt-5.6-luna:high', 'env noise must not buy a rung');
  assert.equal(a.consecutive_failures, 3, 'CB counter still counts every failure');
  assert.equal(a.escalation_eligible_failures, 1);

  // B: the same single genuine failure with no env noise.
  const b = runFailureSequence([implVerdict]);
  assert.equal(b.worker_model, 'gpt-5.6-luna:high');
  assert.equal(b.escalation_eligible_failures, 1);

  // The A-vs-B equality IS the finding: identical eligible history, identical model.
  assert.equal(a.worker_model, b.worker_model);
});

test('N1-C: six environment failures plus one real failure still skip no rungs', () => {
  const c = runFailureSequence([...Array(6).fill(envVerdict), implVerdict]);
  assert.equal(c.worker_model, 'gpt-5.6-luna:high', 'must not land on terra:max having never run luna:max');
  assert.equal(c.escalation_eligible_failures, 1);
  assert.equal(c.consecutive_failures, 7);
});

test('N1: eligible failures still climb normally, one rung per 3', () => {
  // Three eligible failures = stage 1 = one rung.
  const three = runFailureSequence([implVerdict, implVerdict, implVerdict]);
  assert.equal(three.worker_model, 'gpt-5.6-luna:max');
  assert.equal(three.escalation_eligible_failures, 3);
  // Interleaved env failures do not change where the eligible ones land.
  const interleaved = runFailureSequence([
    implVerdict, envVerdict, implVerdict, envVerdict, implVerdict,
  ]);
  assert.equal(interleaved.worker_model, 'gpt-5.6-luna:max');
  assert.equal(interleaved.escalation_eligible_failures, 3);
  assert.equal(interleaved.consecutive_failures, 5);
});

test('recordFailureCounters: counter semantics and backward-compatible defaults', () => {
  // A status.json written before escalation_eligible_failures existed resumes
  // with the field absent — it must default to 0, not NaN.
  const legacy = { consecutive_failures: 4 };
  assert.equal(recordFailureCounters(legacy, implVerdict), true);
  assert.equal(legacy.consecutive_failures, 5);
  assert.equal(legacy.escalation_eligible_failures, 1);

  const env = { consecutive_failures: 0, escalation_eligible_failures: 0 };
  assert.equal(recordFailureCounters(env, envVerdict), false);
  assert.equal(env.consecutive_failures, 1, 'CB counter is never gated');
  assert.equal(env.escalation_eligible_failures, 0, 'rung counter is gated');
});
