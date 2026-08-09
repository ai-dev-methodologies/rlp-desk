// Done-claim kind classifier (G3, RC-9).
//
// SHARED because two independent predicates key on the same question — "is this
// a BUILD-mode claim?" — and they must never drift apart:
//   * runner/done-claim-lint.mjs   — only build claims get the per-AC TDD lint.
//   * shared/commit-oracle.mjs     — only NON-build claims get the empty-commit
//                                    anti-fabrication check.
// Layering: this module lives in shared/ precisely so commit-oracle.mjs (which
// is I/O-free and must import nothing from runner/) can use it. The zsh mirror
// is the `any(.execution_steps[]; .step == "write_test")` jq predicate in
// lib_ralph_desk.zsh (run_pregate_doneclaim_lint + _commit_oracle_check).
//
// The classifier is a PROXY, deliberately: a claim carrying a `write_test` step
// is build work; a claim without one is confirmation/replay/verification-SHAPED
// — which includes refactor and doc iterations that are genuinely build work.
// Consumers must be correct for that over-capture (the commit oracle is: an
// empty commit is never warranted by any claim type).

export function isBuildClaim(doneClaim) {
  const steps = Array.isArray(doneClaim?.execution_steps) ? doneClaim.execution_steps : [];
  return steps.some((step) => step && step.step === 'write_test');
}
