import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { lintDoneClaimTddSequence } from '../../src/node/runner/done-claim-lint.mjs';

// Layer 1.5 — done-claim TDD-sequence lint (Node predicate).
// Iterates the shared fixtures under tests/fixtures/done-claim-lint/ — the SAME
// fixtures tests/test_doneclaim_lint.sh drives through the zsh predicate for
// parity — and asserts EXACT expected output. Plus a disabled-env case.

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const fixtureDir = path.join(projectRoot, 'tests/fixtures/done-claim-lint');

// A fixture is `<name>.json` (the done-claim) with a sibling `<name>.expected.json`
// (the exact expected result). An OPTIONAL sibling `<name>.meta.json` carries
// out-of-band test-setup that is NOT part of a real done-claim's shape — today
// just `{"attemptHistoryExists": boolean}` (governance §1f¾) — kept in its own
// file rather than a reserved key on the done-claim itself, so every `<name>.json`
// stays a realistic, self-contained done-claim and the zsh harness (which drives
// the SAME files by creating/omitting an on-disk iter-NNN.attempt-history.md
// artifact instead of passing a function argument) can read the identical meta
// file to decide whether to create it. Absent meta file = attemptHistoryExists
// false, so every pre-existing fixture is untouched.
const fixtures = fs
  .readdirSync(fixtureDir)
  .filter((f) => f.endsWith('.json') && !f.endsWith('.expected.json') && !f.endsWith('.meta.json'))
  .map((f) => f.replace(/\.json$/, ''))
  .sort();

for (const name of fixtures) {
  test(`fixture ${name} → exact expected output`, () => {
    const doneClaim = JSON.parse(fs.readFileSync(path.join(fixtureDir, `${name}.json`), 'utf8'));
    const expected = JSON.parse(fs.readFileSync(path.join(fixtureDir, `${name}.expected.json`), 'utf8'));
    const metaPath = path.join(fixtureDir, `${name}.meta.json`);
    const attemptHistoryExists = fs.existsSync(metaPath)
      ? JSON.parse(fs.readFileSync(metaPath, 'utf8')).attemptHistoryExists === true
      : false;
    // Force a clean env so RLP_DONECLAIM_LINT in the runner's shell can't skew it.
    const actual = lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists });
    assert.deepEqual(actual, expected);
  });
}

test('RLP_DONECLAIM_LINT=0 → skip disabled (even for a would-fail claim)', () => {
  const doneClaim = JSON.parse(
    fs.readFileSync(path.join(fixtureDir, 'fail-us002-repro.json'), 'utf8'),
  );
  const actual = lintDoneClaimTddSequence(doneClaim, { env: { RLP_DONECLAIM_LINT: '0' } });
  assert.deepEqual(actual, { status: 'skip', reason: 'disabled' });
});

test('missing/unparseable done-claim → skip unparseable (fail-open)', () => {
  assert.deepEqual(lintDoneClaimTddSequence(null, { env: {} }), { status: 'skip', reason: 'unparseable' });
  assert.deepEqual(lintDoneClaimTddSequence([], { env: {} }), { status: 'skip', reason: 'unparseable' });
});

test('empty/absent execution_steps → skip no-steps', () => {
  assert.deepEqual(
    lintDoneClaimTddSequence({ claims: ['AC1: x'] }, { env: {} }),
    { status: 'skip', reason: 'no-steps' },
  );
  assert.deepEqual(
    lintDoneClaimTddSequence({ execution_steps: [] }, { env: {} }),
    { status: 'skip', reason: 'no-steps' },
  );
});

// Approach-escalation enforcement (reaudit wave 1 — makes the
// "APPROACH ESCALATION REQUIRED" Worker-prompt demand mechanically checkable
// instead of aspirational). attemptHistoryExists mirrors "the Leader found a
// persisted <us_id>.attempt-history.md for this US" — the caller computes it
// from the filesystem; this pure function never touches disk itself.

test('attemptHistoryExists=true + missing approach_summary → fail approach_summary_missing', () => {
  const doneClaim = { us_id: 'US-001', claims: ['AC1: x'], execution_steps: [] };
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists: true }),
    { status: 'fail', reason: 'approach_summary_missing', violations: [] },
  );
});

test('attemptHistoryExists=true + empty/whitespace approach_summary → fail approach_summary_missing', () => {
  const doneClaim = { us_id: 'US-001', approach_summary: '   ', execution_steps: [] };
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists: true }),
    { status: 'fail', reason: 'approach_summary_missing', violations: [] },
  );
});

test('attemptHistoryExists=true + non-string approach_summary → fail approach_summary_missing', () => {
  const doneClaim = { us_id: 'US-001', approach_summary: 42, execution_steps: [] };
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists: true }),
    { status: 'fail', reason: 'approach_summary_missing', violations: [] },
  );
});

test('attemptHistoryExists=true + non-empty approach_summary → falls through to normal TDD-sequence result', () => {
  const doneClaim = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'pass-plain.json'), 'utf8'));
  doneClaim.approach_summary = 'Rewrote the parser to stream input instead of buffering it whole, unlike the two prior buffered-read attempts.';
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists: true }),
    { status: 'pass', violations: [] },
  );
});

test('attemptHistoryExists=false (default) → approach_summary is never required, even if absent', () => {
  const doneClaim = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'pass-plain.json'), 'utf8'));
  assert.deepEqual(lintDoneClaimTddSequence(doneClaim, { env: {} }), { status: 'pass', violations: [] });
});

test('attemptHistoryExists=true but RLP_DONECLAIM_LINT=0 → still skip disabled (opt-out wins)', () => {
  const doneClaim = { us_id: 'US-001', execution_steps: [] };
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: { RLP_DONECLAIM_LINT: '0' }, attemptHistoryExists: true }),
    { status: 'skip', reason: 'disabled' },
  );
});

test('attemptHistoryExists=true + unparseable done-claim → still skip unparseable (cannot read a field off null)', () => {
  assert.deepEqual(
    lintDoneClaimTddSequence(null, { env: {}, attemptHistoryExists: true }),
    { status: 'skip', reason: 'unparseable' },
  );
});

test('attemptHistoryExists=true + confirmation-mode claim (verify_existing, no write_test) still requires approach_summary', () => {
  const doneClaim = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'skip-confirmation.json'), 'utf8'));
  // Sanity: this fixture is the confirmation/replay shape the TDD-sequence
  // lint itself skips — the approach_summary requirement must NOT inherit
  // that skip, since an escalated US resolved via verify_existing is just as
  // capable of silently repeating a failed "fix" as a fresh build.
  assert.deepEqual(
    lintDoneClaimTddSequence(doneClaim, { env: {}, attemptHistoryExists: true }),
    { status: 'fail', reason: 'approach_summary_missing', violations: [] },
  );
});
