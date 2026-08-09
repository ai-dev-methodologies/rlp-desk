// Done-claim commit-integrity oracle predicate (US-001, PRD campaign-hardening-v1).
//
// The leader accepts a Worker done-claim that asserts a `commit` step with
// exit_code 0. Before dispatching the (probabilistic) verifier, the leader
// adjudicates that ground truth with git: a claimed commit must have actually
// advanced HEAD and left the tracked tree clean (Principle 1 — leader-side
// determinism over verifier judgment for checkable facts).
//
// This module is the PURE-FUNCTION predicate (Principle 6): it is I/O-free and
// takes injected git facts. The zsh production leader
// (lib_ralph_desk.zsh `_commit_oracle_check`) implements the identical logic;
// a shared-fixture parity matrix drives both. The Node loop feeds this predicate
// via a thin git-gathering wrapper (campaign-main-loop.mjs). Keeping the logic
// here — not inline in the loop — is what prevents zsh<->Node drift.

import { isBuildClaim } from './done-claim-kind.mjs';

// Locate the done-claim's commit assertion: the FIRST execution_steps entry
// with step === "commit" and exit_code 0 (accepts numeric 0 or string "0";
// governance §1f workers may serialize either). Returns the entry (with its
// commit_sha, which is the NEW structured field — AC1.1) or null when the claim
// does not assert a successful commit (→ oracle no-op).
export function findCommitClaim(doneClaim) {
  const steps = Array.isArray(doneClaim?.execution_steps) ? doneClaim.execution_steps : [];
  for (const step of steps) {
    if (!step || step.step !== 'commit') {
      continue;
    }
    const exit = step.exit_code;
    if (exit === 0 || exit === '0') {
      return step;
    }
  }
  return null;
}

// Evaluate the oracle against injected git facts. Pure — no git, no fs.
//
// facts:
//   doneClaim              parsed done-claim object (or null)
//   iterStartHead          HEAD sha captured at THIS iteration's start
//                          (per-iteration snapshot, AC1.3), '' when the repo had
//                          no commits at iteration start
//   currentHead            current HEAD sha, '' when the repo still has no commits
//   claimedShaResolves     git cat-file -e <claimedSha>^{commit} succeeded
//                          (only consulted when a commit_sha is present)
//   claimedShaReachable    <claimedSha> is an ancestor of HEAD
//                          (only consulted when a commit_sha is present)
//   trackedDirtyWorkerFiles worker-attributable tracked-dirty files: the
//                          Bug #8 tracked-only `git diff --name-only <base>`
//                          MINUS the campaign-preexisting-dirty set and MINUS
//                          untracked cruft (AC1.2 — NOT git status --porcelain)
//   claimedCommitEmptyTree tri-state (G3): true when the claimed commit's tree
//                          equals its parent's (`git diff --quiet <sha>^ <sha>`),
//                          false when it carries a real delta, 'unknown' when
//                          the parent is unavailable (root commit / shallow
//                          clone) — 'unknown' ACCEPTS, it is never a rejection
//                          and never an infra failure. Only consulted when a
//                          commit_sha is present (there is no other anchor to
//                          diff), so the no-sha transition rule is unaffected.
//
// returns { asserted, ok, reason, detail, claimedSha }.
//   asserted=false → no commit asserted → no-op (ok=true).
//   asserted=true, ok=true → claim corroborated → pass-through.
//   asserted=true, ok=false → mismatch → caller routes to the fix loop.
export function evaluateCommitOracle(facts = {}) {
  const {
    doneClaim = null,
    iterStartHead = '',
    currentHead = '',
    claimedShaResolves = false,
    claimedShaReachable = false,
    trackedDirtyWorkerFiles = [],
    claimedCommitEmptyTree = 'unknown',
  } = facts;

  const claim = findCommitClaim(doneClaim);
  if (!claim) {
    // verify_existing / confirmation mode / no commit step → silent no-op.
    return { asserted: false, ok: true, reason: null, detail: null, claimedSha: null };
  }

  const claimedSha = firstStr(claim.commit_sha);
  // HEAD advanced beyond the per-iteration start snapshot. A non-empty
  // currentHead that differs from iterStartHead proves this iteration produced a
  // commit — including the first-commit case (iterStartHead '' on a fresh repo).
  // Using the per-ITERATION snapshot (not the campaign baseline) is what rejects
  // "clean tree + HEAD advanced by an EARLIER iteration + lie THIS iteration".
  const headAdvanced = currentHead !== '' && currentHead !== iterStartHead;
  const trackedDirty = (trackedDirtyWorkerFiles ?? []).length > 0;

  if (!claimedSha) {
    // Transition rule (AC1.1): a commit-claim WITHOUT the structured commit_sha
    // is unverifiable (older workers predate US-005's prompt contract). Treat it
    // as a mismatch ONLY if HEAD did not advance — the blatant "claimed a commit
    // but nothing landed" case. Once commit_sha is emitted, the full check below
    // applies. (The tracked-dirty delta is deliberately NOT asserted here: with
    // no SHA to anchor the claim, HEAD-advance is the only signal we trust.)
    if (headAdvanced) {
      return { asserted: true, ok: true, reason: null, detail: null, claimedSha: null };
    }
    return {
      asserted: true,
      ok: false,
      reason: 'commit_claim_no_sha_no_advance',
      detail:
        `done-claim asserts a successful commit but carries no commit_sha, and HEAD did not advance ` +
        `beyond the iteration-start snapshot (${short(iterStartHead) || 'none'}). The claimed commit did not land.`,
      claimedSha: null,
    };
  }

  // Full predicate: check A (HEAD advance + SHA resolves + SHA reachable) and
  // check B (tracked-dirty clean) INDEPENDENTLY (AC1.2), so the fix contract can
  // name exactly which invariant the worker's claim violated.
  const reasons = [];
  const details = [];
  if (!headAdvanced) {
    reasons.push('head_not_advanced');
    details.push(
      `HEAD did not advance beyond the iteration-start snapshot (${short(iterStartHead) || 'none'}); ` +
      `current HEAD ${short(currentHead) || 'none'}.`,
    );
  }
  if (!claimedShaResolves) {
    reasons.push('claimed_sha_absent');
    details.push(`claimed commit ${short(claimedSha)} does not resolve (git cat-file -e failed).`);
  } else if (!claimedShaReachable) {
    reasons.push('claimed_sha_unreachable');
    details.push(`claimed commit ${short(claimedSha)} is not reachable from HEAD.`);
  }
  if (trackedDirty) {
    reasons.push('tracked_tree_dirty');
    details.push(
      `tracked files remain uncommitted after the claimed commit: ` +
      `${(trackedDirtyWorkerFiles ?? []).slice(0, 5).join(', ')}.`,
    );
  }
  // G3 anti-fabrication: an empty commit records NO work, so it can never
  // corroborate a done-claim. The gate is scoped to claims carrying no
  // write_test step — the shape a verification/confirmation pass produces, and
  // the pressure point that made a worker fabricate one. Claims carrying a
  // write_test step are untouched in this release; the classifier bounds the
  // rejection's blast radius, it does not assert that the claim really was
  // verification work (a refactor/doc claim is build work and is still rejected
  // here — intended: the empty commit is the defect, not the claim type).
  // 'unknown' (root commit / shallow clone) accepts — see the fact contract above.
  if (!isBuildClaim(doneClaim) && claimedCommitEmptyTree === true) {
    reasons.push('empty_commit_on_confirmation_claim');
    details.push(
      `claimed commit ${short(claimedSha)} has the same tree as its parent (empty commit) ` +
      `and the done-claim carries no write_test step: the iteration recorded no work, so the ` +
      `commit is evidence of nothing (IL-1 evidence breach).`,
    );
  }

  if (reasons.length === 0) {
    return { asserted: true, ok: true, reason: null, detail: null, claimedSha };
  }

  return {
    asserted: true,
    ok: false,
    reason: reasons.join('+'),
    detail: details.join(' '),
    claimedSha,
  };
}

function firstStr(value) {
  if (typeof value === 'string' && value.trim() !== '') {
    return value.trim();
  }
  return null;
}

function short(sha) {
  return typeof sha === 'string' ? sha.slice(0, 10) : '';
}
