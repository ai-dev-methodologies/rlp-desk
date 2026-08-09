# Verification History — Self-Verification & Dogfooding Ledger

Append-only record of every self-verification (SV) gate run and dogfooding
campaign used to validate rlp-desk itself. Newest entry first. Each entry
records: date, what was verified, method/configuration, results, findings
(with disposition), and artifact pointers. Owner standing rule (2026-08-09):
every SV/dogfood verification MUST be recorded here.

Entry template:

```
## YYYY-MM-DD — <title>
- Target: <feature/release verified>
- Method: <SV gate | dogfood campaign | both> + configuration
- Result: <PASS/FAIL + terminal states>
- Findings: <id — severity — one-line — disposition>
- Artifacts: <paths/commits>
```

---

## 2026-08-08 — luna-first dogfood: tmux + native campaigns (v0.23.0 validation)

- **Target**: v0.23.0 luna-first routing in production use — worker
  `gpt-5.6-luna:high`, tiered verifiers, cross-engine consensus, and the new
  campaign cost summary, exercised on BOTH leaders (tmux/zsh and native/LLM).
- **Method**: two real campaigns on branch `polish/v0230-docs`.
  1. `v0230-polish` (tmux, zsh leader): 2 specification-type US (stale
     governance citation fix in campaign-main-loop.mjs; README "What's new in
     v0.23.0" section). Config: `--worker-model gpt-5.6-luna:high
     --verifier-model claude-sonnet-5:high --final-verifier-model
     claude-fable-5:max --consensus all --consensus-model gpt-5.6-luna:max
     --final-consensus-model gpt-5.6-sol:xhigh --verify-mode per-us --debug`,
     `RLP_LEADER_SPLIT_WIDTH=80` (90-col terminal).
  2. `v0230-polish-nv` (native, LLM leader): 1 verification-type US
     (`verify_existing` gate) confirming the changes hold; worker luna:high
     via `codex exec`, per-US verifier sonnet tier, final verifier fable tier.
- **Result**: both campaigns **COMPLETE**.
  - tmux: run 1 hit max-iter 8 exactly at leader-finalize (both US already
    verified) → TIMEOUT; resume with max-iter 12 finished final verify +
    final consensus in 11m07s (run 1: 72m39s). 0 ladder escalations; one
    consensus disagreement (claude=pass / codex=fail) resolved in a fix round
    at the SAME model — cross-engine consensus caught what the claude leg
    passed.
  - native: 3 worker iterations (1 environment-polluted, 1 COMMIT-INTEGRITY
    fix round), 0 ladder escalations; per-US PASS + final PASS.
- **Cost summary validation** (the experiment's purpose):
  - tmux: est. 26,228 tokens total → sol-equivalent ≈ **≤2,573** (luna legs
    ×0.04; single final sol:xhigh leg ×1.0) ≈ **~10× saving** vs a
    hypothetical sol:high worker (ESTIMATED — zsh bytes/4 basis).
  - native: codex-reported ~434k raw tokens (cache-inflated) ×0.04 ≈ 17.3k
    sol-equivalent — nominal **~25× saving** on worker legs. Native leader
    rendered the ⑩ sol-equivalent summary correctly
    (`.rlp-desk/logs/v0230-polish-nv/campaign-report.md`).
  - luna-first thesis held: luna:high resolved BOTH fix rounds without any
    ladder climb (strong-oracle environment).
- **Findings**:
  - G1 — MEDIUM — zsh leader's campaign-report lacks the sol-equivalent
    computation (⑩ is LLM-leader prompt text; tmux report prints raw token
    lines only) — OPEN, follow-up candidate.
  - G2 — MEDIUM — repo `.gitignore` missing `.rlp-desk/` (v0.13 path
    migration leftover): caused workers to commit runtime artifacts, edit
    .gitignore, and restore a moved-aside legacy tracked dir — OPEN, 1-line
    fix candidate.
  - G3 — LOW — verification-type US × commit-integrity oracle interaction:
    tmux worker created an EMPTY commit to satisfy the oracle (dropped from
    the branch before merge); `verify_existing` iterations should be exempt
    from commit expectations — OPEN.
  - G4 — LOW — narrow terminals (<110 cols) fail pane creation without
    `RLP_LEADER_SPLIT_WIDTH`; no automatic degrade — OPEN.
  - ISSUE-1 — INFO — duplicated `git reset` step logged in a done-claim
    (logging artifact; end state independently verified) — recorded only.
- **Artifacts**: commits `3d346e3` (US-001), `c895036` (US-002) on
  `polish/v0230-docs`; campaign logs `.rlp-desk/logs/v0230-polish*/`
  (campaign-report.md, campaign-report-v1.md, cost-log.jsonl, runs/
  superseded archive); gate receipts `.rlp-desk/plans/gate-receipt-*.json`.

## 2026-08-02/03 — v0.23.0 luna-first build: SV gate + final review (pre-ship)

- **Target**: luna-first cost routing implementation (v0.23.0): models.json
  ladder, effort-aware timeouts (both leaders), environment failure-category
  guard, doctrine/docs, CLI defaults.
- **Method**: subagent-driven development with per-task reviews, then the
  project-mandated 3-scenario Self-Verification Gate (LOW/MEDIUM/CRITICAL
  walkthroughs against real artifacts, opus judge), re-run after every fix
  wave (3 gate rounds total), plus a final whole-branch review (opus) over
  the 15-commit diff. Full test evidence per round: `npm run test:node`
  (586/586), `npm run test:zsh` (exit 0), sv-large-campaign ladder harness
  (20/20).
- **Result**: SV gate **FAIL → FAIL → PASS (3/3 scenarios)**; final review
  **MERGE-READY**; shipped as v0.23.0.
- **Findings** (all fixed pre-ship unless noted):
  - F1 — CRITICAL — zsh effort-aware timeout dead code (role case mismatch
    "Worker" vs lowercase compare) — FIXED + production-string test pins.
  - F2 — HIGH — Node leader (default mode) lacked the environment guard
    entirely — FIXED (escalationEligible at both nextWorkerModel paths).
  - F3 — HIGH — guard probed a non-existent verdict array; real per-check
    array differs — FIXED (4-arm extractor: top-level/issues/reasoning/checks
    + contract-pin tests).
  - N1 — HIGH — environment failures still advanced ladder arithmetic via
    the shared failure counter — FIXED (dual counter:
    `escalation_eligible_failures` for the ladder, `consecutive_failures`
    for CB; legacy-resume fallback).
  - I1 — IMPORTANT — environment guard was inert at runtime (verifier
    contract never asked for failure_category) — FIXED (Verdict JSON schema
    + Rules + extractor arms + contract-pin tests).
  - I2 — IMPORTANT — zsh effort multiplier could never apply to claude
    workers (stale codex-model default defeated the fallback) — FIXED
    (engine-aware effort read).
  - Plus F4-F7, N2-N4, M1-M3, E1/E2 (doc/consistency tier) — all FIXED;
    D2/D3 informational — parked.
- **Lesson**: green test suites passed all three of F1/F2/F3 because
  coverage was grep-based or used non-production inputs — the SV gate's
  artifact-walkthrough method (tracing real call paths with real strings)
  is what caught them. Mutation-verification of fixes (re-introduce defect →
  tests must fail) adopted as standard practice.
- **Artifacts**: commits `9088709..4fbf873` on main (v0.23.0);
  spec `docs/superpowers/specs/2026-08-03-luna-first-cost-routing-design.md`;
  plan `docs/superpowers/plans/2026-08-03-luna-first-cost-routing.md`.
