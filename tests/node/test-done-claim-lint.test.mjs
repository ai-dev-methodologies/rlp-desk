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

const fixtures = fs
  .readdirSync(fixtureDir)
  .filter((f) => f.endsWith('.json') && !f.endsWith('.expected.json'))
  .map((f) => f.replace(/\.json$/, ''))
  .sort();

for (const name of fixtures) {
  test(`fixture ${name} → exact expected output`, () => {
    const doneClaim = JSON.parse(fs.readFileSync(path.join(fixtureDir, `${name}.json`), 'utf8'));
    const expected = JSON.parse(fs.readFileSync(path.join(fixtureDir, `${name}.expected.json`), 'utf8'));
    // Force a clean env so RLP_DONECLAIM_LINT in the runner's shell can't skew it.
    const actual = lintDoneClaimTddSequence(doneClaim, { env: {} });
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
