import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildApproachSummaryMissingFixContract } from '../../src/node/runner/campaign-main-loop.mjs';

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const mainLoopSrc = fs.readFileSync(
  path.join(projectRoot, 'src/node/runner/campaign-main-loop.mjs'),
  'utf8',
);

// Governance §1f¾ / DEFECT-2b Node parity: when the Layer 1.5 lint fails with
// reason `approach_summary_missing` (lintDoneClaimTddSequence, done-claim-lint.mjs),
// the generic buildDoneClaimLintFixContract renders `{ac,idx}` violations — which
// are always [] for this reason — and would hand the Worker a blank, useless list.
// This is the dedicated fix-contract builder for that branch, mirroring the zsh
// `_pregate_register_fail_doneclaim_lint`'s approach_summary_missing branch
// (lib_ralph_desk.zsh) in INTENT (names the field, cites the attempt-history
// path, is NOT a re-implementation demand), not in exact wording.

test('names the required approach_summary field', () => {
  const contract = buildApproachSummaryMissingFixContract(7, '/logs/slug/iter-007.attempt-history.md');
  assert.match(contract, /approach_summary/);
});

test('cites the attempt-history artifact path', () => {
  const path = '/logs/slug/iter-007.attempt-history.md';
  const contract = buildApproachSummaryMissingFixContract(7, path);
  assert.ok(contract.includes(path), 'contract must include the exact attempt-history path');
});

test('does NOT render the generic {ac,idx} TDD-sequence body', () => {
  const contract = buildApproachSummaryMissingFixContract(7, '/logs/slug/iter-007.attempt-history.md');
  assert.doesNotMatch(contract, /PRE-GATE FAILURE \(done-claim format lint\)/);
  assert.doesNotMatch(contract, /idx=/);
});

test('carries the iteration number in the header, matching the sibling builder\'s format', () => {
  const contract = buildApproachSummaryMissingFixContract(7, '/logs/slug/iter-007.attempt-history.md');
  assert.match(contract, /# Fix Contract \(PRE-GATE FAILURE, iteration 7\)/);
});

test('does not, by itself, demand re-implementing the deliverable', () => {
  // This is a format requirement (add a field), not a correctness re-derivation —
  // the contract text should say so explicitly, matching the zsh sibling's framing.
  const contract = buildApproachSummaryMissingFixContract(7, '/logs/slug/iter-007.attempt-history.md');
  assert.match(contract, /not.*re-implement/i);
});

// Structural wiring pins (same convention as the zsh side's own
// "structural: Node & zsh predicates + call sites are wired" section in
// tests/test_doneclaim_lint.sh — a full runCampaign() mock is not the
// established pattern for this call site; see clearStaleVerdict's tests
// for the same "test the extracted small function, structurally pin the
// call site" split). Confirms the Layer 1.5 call site actually computes and
// passes attemptHistoryExists, and actually branches to this builder on
// approach_summary_missing — a wired predicate that is never invoked with
// attemptHistoryExists:true is the exact defect this whole feature exists
// to fix, so this is not optional coverage.
test('call site computes attemptHistoryExists from the iter-NNN.attempt-history.md path', () => {
  assert.match(mainLoopSrc, /attempt-history\.md/);
  assert.match(mainLoopSrc, /attemptHistoryExists\s*=\s*fsSync\.existsSync\(attemptHistoryPath\)/);
});

test('call site passes attemptHistoryExists into lintDoneClaimTddSequence', () => {
  assert.match(
    mainLoopSrc,
    /lintDoneClaimTddSequence\(lintDoneClaim,\s*\{\s*env:\s*lintEnv,\s*attemptHistoryExists\s*\}\)/,
  );
});

test('call site branches to buildApproachSummaryMissingFixContract on reason === approach_summary_missing', () => {
  assert.match(mainLoopSrc, /lintResult\.reason === 'approach_summary_missing'/);
  assert.match(mainLoopSrc, /buildApproachSummaryMissingFixContract\(state\.iteration, attemptHistoryPath\)/);
});
