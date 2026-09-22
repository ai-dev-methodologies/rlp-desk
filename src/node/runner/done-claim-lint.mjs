// Layer 1.5 pre-gate: deterministic done-claim TDD-sequence lint.
//
// Pure function — no I/O. Runs AFTER the worker submits its done-claim and
// BEFORE the LLM verifier is dispatched, on BOTH leaders (this is the Node
// mirror; the zsh production predicate is `run_pregate_doneclaim_lint` in
// src/scripts/lib_ralph_desk.zsh, driven by the same shared fixtures). It
// rejects malformed BUILD-mode claims with per-AC step-index coordinates so a
// pure format defect never burns a 20-25min LLM cross-verification round.
//
// The predicate below is the SINGLE SOURCE OF TRUTH shared by the worker-prompt
// done-claim format spec and the verifier's Worker Process Audit (governance
// §3a Layer 1.5) — a claim that passes this lint must not be re-failed on
// step-sequence/label format grounds.

import { isBuildClaim } from '../shared/done-claim-kind.mjs';

const PHASES = ['write_test', 'verify_red', 'implement', 'verify_green'];
const CLAIM_AC_RE = /^\s*(AC[0-9]+)\s*:/;

// acs(step) = split (ac_id) on ",", trim per token, drop empty and the exact
// bundle token "all" (an "all"-labeled step does NOT satisfy any AC's four
// phases — mirrors the codex Worker Process Audit criterion). Type coercion:
// a non-string ac_id (number/object/null/absent) is treated as "" so the step
// contributes NO ACs — never a coerced label like "3" (parity with the jq guard).
function acsOf(step) {
  const raw = (step && typeof step.ac_id === 'string') ? step.ac_id : '';
  return raw
    .split(',')
    .map((token) => token.replace(/\s+/g, ''))
    .filter((token) => token !== '' && token !== 'all');
}

/**
 * Deterministic per-AC TDD-sequence lint of a parsed done-claim.
 *
 * @param {*} doneClaim parsed done-claim JSON ({us_id, claims[], execution_steps[]})
 * @param {{env?: object, attemptHistoryExists?: boolean}} [options] env defaults to
 *   process.env (RLP_DONECLAIM_LINT opt-out). attemptHistoryExists is caller-computed
 *   (a filesystem check for this iteration's persisted iter-NNN.attempt-history.md — see
 *   governance §1f¾) since this function stays pure/no-I/O; defaults to false so every
 *   existing call site (and every pre-escalation done-claim) is unaffected.
 * @returns {{status:'skip'|'pass'|'fail', reason?:string, violations?:Array<{ac:string, idx:number[]}>}}
 */
export function lintDoneClaimTddSequence(doneClaim, { env = process.env, attemptHistoryExists = false } = {}) {
  // Opt-out (reason `disabled`).
  if (env && env.RLP_DONECLAIM_LINT === '0') {
    return { status: 'skip', reason: 'disabled' };
  }
  // Missing/unparseable done-claim — fail-open (reason `unparseable`).
  if (!doneClaim || typeof doneClaim !== 'object' || Array.isArray(doneClaim)) {
    return { status: 'skip', reason: 'unparseable' };
  }
  // Approach-escalation enforcement (governance §1f¾): when the Leader has
  // persisted an attempt-history artifact for this iteration (repeated failure
  // already upgraded the Worker model and the next prompt demanded a
  // materially different strategy), the done-claim MUST name that strategy
  // in a top-level `approach_summary` field. This is INDEPENDENT of the
  // TDD-sequence check below — it runs even for confirmation/replay claims
  // (no write_test step) that the TDD-sequence check itself skips, since a
  // US resolved via verify_existing can silently repeat a failed "fix" just
  // as easily as a fresh build. No artifact for this iteration → not required; this
  // is a conditional check gated on escalation being active, never a
  // blanket done-claim requirement.
  if (attemptHistoryExists) {
    const summary = doneClaim.approach_summary;
    if (typeof summary !== 'string' || summary.trim().length === 0) {
      return { status: 'fail', reason: 'approach_summary_missing', violations: [] };
    }
  }
  const steps = doneClaim.execution_steps;
  if (!Array.isArray(steps) || steps.length === 0) {
    return { status: 'skip', reason: 'no-steps' };
  }
  // Only BUILD-mode claims are linted. A claim with no write_test step is a
  // confirmation/replay claim (verify_existing/verify) and is exempt — this
  // prevents false positives against resume/confirmation claims. The predicate
  // is shared with the commit oracle's empty-commit check (G3/RC-9) so the two
  // can never disagree on what "build claim" means.
  if (!isBuildClaim(doneClaim)) {
    return { status: 'skip', reason: 'not-build' };
  }

  // ACS = unique( union of acs(step) over all steps ∪ claimsACs ). The
  // claims-derived union is a DELIBERATE strengthening over the reference jq:
  // it catches the degenerate claim that labels every step `all` (which would
  // otherwise yield an empty ACS and vacuously pass).
  const acSet = new Set();
  for (const step of steps) {
    for (const ac of acsOf(step)) {
      acSet.add(ac);
    }
  }
  const claims = Array.isArray(doneClaim.claims) ? doneClaim.claims : [];
  for (const claim of claims) {
    if (typeof claim !== 'string') {
      continue;
    }
    const match = claim.match(CLAIM_AC_RE);
    if (match) {
      acSet.add(match[1]);
    }
  }
  // Sort as strings to mirror jq `unique` (parity with the zsh predicate).
  const acs = [...acSet].sort();

  const violations = [];
  for (const ac of acs) {
    const idx = PHASES.map((phase) => {
      const i = steps.findIndex((step) => step && step.step === phase && acsOf(step).includes(ac));
      return i; // findIndex returns -1 when absent — matches the jq `// -1`
    });
    const sorted = [...idx].sort((a, b) => a - b);
    const inversion = idx.some((v, i) => v !== sorted[i]);
    if (Math.min(...idx) < 0 || inversion) {
      violations.push({ ac, idx });
    }
  }

  if (violations.length > 0) {
    return { status: 'fail', violations };
  }
  return { status: 'pass', violations: [] };
}

export default lintDoneClaimTddSequence;
