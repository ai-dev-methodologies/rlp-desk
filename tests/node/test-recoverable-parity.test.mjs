// vision-adopt §2: recoverable-flag reconciliation (zsh ↔ Node).
//
// Node side of the shared-fixture parity test. The fixture
// tests/fixtures/recoverable-parity/matrix.json is the single source of truth
// for the reconciled taxonomy; tests/test_recoverable_parity.sh drives the zsh
// leader against the SAME fixture. Together they pin:
//   1. Node _classifyBlock(source).recoverable == the fixture's per-source value
//      (and reason_category matches).
//   2. Every source's recoverable equals its category default
//      (CATEGORY_RECOVERABLE) — the fail-fast invariant that infra_failure is
//      always recoverable=false.
//   3. CATEGORY_RECOVERABLE == the fixture's category_recoverable map (so the
//      zsh test, which only knows categories, is comparing against the same
//      contract).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { _classifyBlock, BLOCK_TAGS } from '../../src/node/runner/campaign-main-loop.mjs';
import { CATEGORY_RECOVERABLE, REASON_CATEGORIES } from '../../src/node/util/reason-category.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const matrix = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'tests', 'fixtures', 'recoverable-parity', 'matrix.json'), 'utf8'),
);

test('§2: CATEGORY_RECOVERABLE matches the shared fixture category_recoverable map', () => {
  assert.deepEqual(CATEGORY_RECOVERABLE, matrix.category_recoverable);
});

test('§2: every fixture category is a known reason_category (closed enum)', () => {
  for (const cat of Object.keys(matrix.category_recoverable)) {
    assert.ok(REASON_CATEGORIES.includes(cat), `unknown category in fixture: ${cat}`);
  }
});

test('§2: external_fact is present and recoverable=false (label-only halt taxonomy)', () => {
  assert.equal(CATEGORY_RECOVERABLE.external_fact, false);
  assert.ok(REASON_CATEGORIES.includes('external_fact'));
});

test('§2: infra_failure is fail-fast (recoverable=false) at the category level', () => {
  assert.equal(CATEGORY_RECOVERABLE.infra_failure, false);
});

for (const row of matrix.sources) {
  test(`§2: _classifyBlock(${row.source}) → recoverable=${row.recoverable}, category=${row.reason_category}`, () => {
    const tag = BLOCK_TAGS[row.source];
    assert.ok(tag, `BLOCK_TAGS.${row.source} must exist`);
    const result = _classifyBlock(tag, { state: { iteration: 0 }, slug: 'parity' });
    assert.equal(result.reason_category, row.reason_category, `category for ${row.source}`);
    assert.equal(result.recoverable, row.recoverable, `recoverable for ${row.source}`);
    // Per-source recoverable must equal the category default (no divergence).
    assert.equal(
      result.recoverable,
      CATEGORY_RECOVERABLE[row.reason_category],
      `${row.source} recoverable must equal category default for ${row.reason_category}`,
    );
  });
}

// LOW-1: the one documented exception — an unrecognized source fails safe with
// recoverable=false, stricter than metric_failure's category default (true).
test('§2: unrecognized source fails safe (recoverable=false, category=metric_failure)', () => {
  const row = matrix.unknown_source;
  const result = _classifyBlock('__no_such_block_tag__', { state: { iteration: 0 }, slug: 'parity' });
  assert.equal(result.reason_category, row.reason_category);
  assert.equal(result.recoverable, row.recoverable);
  // This is exactly where per-source recoverable is INTENTIONALLY stricter than
  // the category default — the documented exception to constancy.
  assert.notEqual(result.recoverable, CATEGORY_RECOVERABLE[row.reason_category]);
});
