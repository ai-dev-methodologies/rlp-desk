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

## 2026-08-09 — OMX_STATE_ROOT isolation: SV gate + fix wave (v0.24.1)

- **Target**: campaign-launched codex sessions isolated from the operator's
  interactive omx state (follow-up to the v0.24.0 ENV finding: omx
  deep-interview guard blocked/wedged headless `codex exec`, 3 incidents on
  2026-08-09 incl. a 31m 0%-CPU hang). All codex launch surfaces now export
  `OMX_STATE_ROOT=<campaign runtime dir>/omx-state` — zsh leader (8 launch
  assembly sites), Node engine (`buildLaunchCommand` prefix via
  `paths.omxStateDir`, codex-only, no-dir = byte-identical compat), native
  leader templates (rlp-desk.md ④/⑦ + governance.md §native).
- **Method**: 3-scenario SV gate (opus, read-only) — S1 LOW docs/census
  coherence with independent 8-site count; S2 MEDIUM zsh quoting-context
  walkthrough of all 8 sites under 3 path shapes + mkdir-ordering proof incl.
  relaunch paths; S3 CRITICAL Node contract diff vs pre-change
  (`git show eb6d1c1`), caller census, adversarial probes vs us002 pins /
  codex-exit fallback / capacity-stall matching. Gate also verified the
  load-bearing premise: installed oh-my-codex honors OMX_STATE_ROOT (321 refs,
  root semantics — state lands at `<root>/.omx/state`).
- **Result**: **3/3 PASS**. Full Node suite 609/609; isolation test 7/7
  (post-fix-wave, incl. governance census + mutation checks); update-dialog
  16/16; zsh -n clean.
- **Findings**: 1 Polyp (MEDIUM) + 7 LOW, all dispositioned:
  - MEDIUM-1 — governance.md:678 native-leader template unprefixed (parallel
    artifact missed) — **fixed** + census extended to governance.md.
  - LOW-5 — zsh single-quote-unsafe interpolation at the send-keys sites —
    **fixed** with `${(q)OMX_STATE_DIR}` (Node already shQuote-safe).
  - LOW-7 — isolation test BRE mid-`$` false-FAIL under ugrep shim — **fixed**
    (grep -cF).
  - LOW-2/3/8 + F1.18 incident count — doc corrections **applied** (root
    semantics, consensus-leg note, tmux illustration).
  - LOW-6 — `OMX_ROOT` outranks `OMX_STATE_ROOT` in oh-my-codex — operator
    note added to F1.18 Recovery (no code change).
  - LOW-4 — deliberately-unprefixed doc mentions — accepted as documented.
- **Artifacts**: branch fix/omx-state-isolation commits 8edbd84 (feature) +
  8a3474d (fix wave); SV report
  .omc/state/sessions/17d4220c-*/sv-gate-omx-report.md; implementation report
  .omc/state/sessions/17d4220c-*/omx-report.md; failure-modes.md F1.18.

## 2026-08-09 — G1-G4 gap-fix build: ralplan consensus + ralph + SV gate + dual dogfood (v0.24.0)

- **Target**: the four 2026-08-08 dogfood findings — G1 zsh sol-equivalent cost
  summary (+ Node parity, Option C split raw/attribution), G2 tracked legacy
  dir removal, G3 empty-commit anti-fabrication (verifier contract + oracle
  predicate + fix contracts, both leaders), G4 leader-pane width auto-degrade
  (target/floor model, RLP_LEADER_DEGRADE_FLOOR=60).
- **Method**: ralplan consensus (Planner/Architect opus, Critic codex — plan
  rev-3 after 12 Architect RCs + 1 blocking contradiction fix + 5 codex-critic
  ITERATE items absorbed as in-flight fix rounds), ralph story loop (5 stories,
  executor subagents, mutation-verified fixes incl. 2 self-found bugs:
  stale-note leak, subshell global-discard), then the 3-scenario SV gate
  (opus, artifact walkthroughs + adversarial C3 attack probe), then DUAL
  dogfood: tmux campaign `g-dogfood` (real deferred fix: Node duration:0;
  luna:high; NO width knob) and native campaign `g-dogfood-nv`
  (verification-type, verify_existing).
- **Result**: SV gate **3/3 PASS** (10 findings: 6 LOW cigarette-fixed in-pass
  commit 7692c2e, 4 INFO accepted); suites 607+ node / full zsh sweep green;
  tmux dogfood **COMPLETE** (3 iters, 24m34s) — new Cost & Performance block
  rendered live and exact (9,935 raw luna tokens → 397 sol-equivalent ✓, 0
  strays, 0 escalations; enriched cost-log rows verified); G4 live probe
  against the real tmux pane (want=200 vs 147 cols) degraded correctly
  (WARN + rc=0 + note, fail-reason clear); native dogfood **COMPLETE** —
  verification-type run produced **zero commits** with the new conditional
  prompt rule live (G3 objective met in production; contrast: 2026-08-08 run
  fabricated empty commit 787b663).
- **Findings**:
  - ENV — operator-side omx "deep-interview" guard blocks/wedges headless
    `codex exec` worker runs (3 incidents; one 31m 0%-CPU hang). Classified
    environment per the new doctrine (engine-swap, no ladder move) — exactly
    the failure class G-series doctrine was built for. OPEN operator item:
    omx guard config for headless codex.
  - INFO — final-verify cost-log rows carry us_id "unknown" → renders as an
    "unknown" bucket in Final-model-per-US (data-faithful; polish candidate).
  - INFO — iter-signal precedent files used a "stop" key but the zsh leader
    parses `.status` (worker discovery; precedent corrected in-campaign).
  - Process failure recorded in gotchas (project commit 0b7f5a1 + global):
    unattended-run stall on an unmonitored background critic — timebox+poll
    now mandatory; reviews never serialize ahead of implementation.
- **Artifacts**: branch fix/dogfood-gaps-g1-g4 commits 2d8ea98..2bc40d9 (incl.
  in-campaign duration fix 2bc40d9); plan .omc/plans/dogfood-gaps-g1-g4.md;
  SV report + executor reports under .omc/state/sessions/17d4220c-*/;
  campaign logs .rlp-desk/logs/g-dogfood*/.

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
