import { test } from 'node:test';
import assert from 'node:assert/strict';

import { lintDoneClaimTddSequence } from '../../src/node/runner/done-claim-lint.mjs';

// reaudit wave 4 -- L2: approach_summary blank-detection parity between the
// Node predicate (this file) and the zsh mirror (run_pregate_doneclaim_lint
// in src/scripts/lib_ralph_desk.zsh, tests/test_reaudit_wave4_lib.sh
// "L2" section drives the SAME codepoints through that side).
//
// Before this fix: `summary.trim()` strips JS's \s whitespace class (which
// already covers NBSP U+00A0, U+2007, U+3000, and even the BOM/ZWNBSP
// U+FEFF) but NOT the zero-width format characters U+200B-U+200D or U+2060
// (WORD JOINER) -- a value made entirely of one of those four survived
// .trim() as "present" here, while the zsh mirror's [[:space:]] strip
// (under a C locale) let NBSP/U+2007/U+3000 survive as "present" too. The
// two leaders disagreed on the same done-claim. Both sides now strip the
// identical codepoint set (see BLANK_RE in done-claim-lint.mjs).

const buildClaim = (approach_summary) => ({
  us_id: 'US-001',
  approach_summary,
  execution_steps: [],
});

const BLANK_ONLY_CASES = [
  ['U+00A0 NBSP only', '\u00A0'],
  ['U+2007 FIGURE SPACE only', '\u2007'],
  ['U+3000 IDEOGRAPHIC SPACE only', '\u3000'],
  ['U+200B ZERO WIDTH SPACE only', '\u200B'],
  ['U+200C ZERO WIDTH NON-JOINER only', '\u200C'],
  ['U+200D ZERO WIDTH JOINER only', '\u200D'],
  ['U+2060 WORD JOINER only', '\u2060'],
  ['U+FEFF BOM/ZWNBSP only', '\uFEFF'],
  ['mixed NBSP + zero-width + BOM', '\u00A0\u200B\uFEFF\u2060'],
  ['plain ASCII spaces (regression)', '   '],
];

for (const [label, value] of BLANK_ONLY_CASES) {
  test(`approach_summary blank-only (${label}) -> fail approach_summary_missing`, () => {
    const actual = lintDoneClaimTddSequence(buildClaim(value), {
      env: {},
      attemptHistoryExists: true,
    });
    assert.deepEqual(actual, { status: 'fail', reason: 'approach_summary_missing', violations: [] });
  });
}

test('approach_summary with real content surrounded by the same blank chars -> passes the escalation branch', () => {
  const value = '\u00A0\u200Bswitched to a recursive descent parser\u2060\uFEFF';
  const actual = lintDoneClaimTddSequence(buildClaim(value), {
    env: {},
    attemptHistoryExists: true,
  });
  // No execution_steps -> falls through to the no-steps skip, proving the
  // approach-escalation branch itself did NOT fire (a fail here would have
  // reason approach_summary_missing).
  assert.deepEqual(actual, { status: 'skip', reason: 'no-steps' });
});

test('attemptHistoryExists=false -> blank-only approach_summary is never checked (branch inert)', () => {
  const actual = lintDoneClaimTddSequence(buildClaim('\u200B'), {
    env: {},
    attemptHistoryExists: false,
  });
  assert.deepEqual(actual, { status: 'skip', reason: 'no-steps' });
});

// Mutation control: the old `summary.trim().length === 0` check is
// reconstructed inline here (not re-imported) and shown to WRONGLY treat a
// zero-width-only value as non-blank -- proving the cases above actually
// exercise the fix rather than something the old code already handled.
test('mutation control: old summary.trim() check would have missed a zero-width-only value', () => {
  const value = '\u200B\u200C\u200D\u2060';
  const oldCheckSaysBlank = value.trim().length === 0;
  assert.equal(
    oldCheckSaysBlank,
    false,
    'sanity: .trim() alone does not strip zero-width characters -- this is exactly the bug L2 fixes',
  );
});
