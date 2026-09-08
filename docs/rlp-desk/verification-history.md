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

## 2026-09-08 — Model-generation wave: Fable 5.1 + Codex 6 Astra (fix/reaudit-wave-1)

- **Target**: adding Claude Fable 5.1 (`claude-fable-5-1`) and Codex 6 Astra
  (`gpt-6-astra`) to the model registry, the two upgrade ladders, the
  role/complexity routing tables and the engine-classification code. Landed on
  `fix/reaudit-wave-1` on top of the 2026-09-07 audit-remediation wave; not
  merged to main.
- **Method**: implement→independent-review pairs with mutation controls, one
  round of the mandatory 3-scenario SV gate (LOW/MEDIUM/CRITICAL, fresh Worker
  execution in throwaway sandboxes), plus a separate adversarial review that ran
  in parallel with the gate. `gpt-6-astra`'s reasoning-level catalog was
  established by live one-token probes in a read-only sandbox rather than
  mirrored from `gpt-5.6-sol`, because `models_cache.json` does not list the
  model.
- **Result**: **INCOMPLETE — the gate re-run after the fixes did not run.**
  Gate round 1 returned 27/33 assertions with 6 findings; the parallel review
  returned PASS with 6 further findings. All 12 were fixed and each fix carries
  a mutation control, but the LOW/MEDIUM/CRITICAL re-run against the corrected
  tree was not executed before the session ended. Suites at commit time were
  green (`npm run test:node` 751/751, `npm run manifest:check` in sync). Per
  CLAUDE.md the gate must PASS before merge; see
  `docs/plans/model-generation-wave-handoff.md` for the scenario design to
  re-run.
- **Findings** (all FIXED unless noted):
  - HIGH — the bare alias `fable` classified as the CODEX engine in all four
    implementations, and a bare canonical `gpt-*` id classified as CLAUDE, so
    `--worker-model gpt-6-astra` — the exact string in `models.json` and every
    doc table — would have invoked `claude --model gpt-6-astra`.
  - HIGH — neither ladder could reach its generation's top model. Claude
    terminated at `opus` while every doc recommended `claude-fable-5-1:max` for
    final verification; codex terminated at `gpt-5.6-sol:xhigh` with astra an
    unreachable island.
  - HIGH — an intermediate revision of this wave put `gpt-6-astra` in the worker
    default, which starts the high-volume role at the ceiling, empties the
    upgrade ladder and makes `check_model_upgrade` return `already_max` from
    iteration one. Reverted; an invariant test now derives each engine's ceiling
    from `models.json` at test time and asserts the shipped worker default sits
    at least two rungs below it.
  - CRITICAL (gate) — the model-specific `minimal` rejection reached only the
    env-var path. `parse_model_flag`, which every documented CLI invocation uses,
    performed no vocabulary validation, so the fix was inert for real users.
    Both paths now call one shared `_validate_model_level()`.
  - MEDIUM — `--consensus-model` and `--final-consensus-model` bypassed both
    validators, and the runtime consensus dispatch never expanded bare codex
    aliases, so `--consensus-model astra:high` would have invoked `codex -m astra`.
  - MEDIUM — a restore test retyped the shipped line it was meant to verify, so
    deleting `WORKER_EFFORT="$_ORIGINAL_WORKER_EFFORT"` left the whole suite
    green. Rewritten to extract and execute the real block, then confirmed the
    mutation turns exactly that test red.
  - MEDIUM — three tests from the previous wave built their pre-fix oracle with
    `git show HEAD:`; committing that wave made HEAD stop being a pre-fix
    baseline and they failed loudly. Re-anchored to a fixed commit.
  - Plus doc drift in six locations where one bullet of a hunk was updated and
    its neighbour was not.
- **Lesson**: a green suite proved nothing three separate times in this wave —
  a dead ladder whose tests never set the triggering variable, a restore test
  that retyped its own subject, and a gate that passed against a scenario set
  omitting an existing committed contract test. Mutation controls and
  execute-the-shipped-line extraction are the only assertions that discriminated.
- **Artifacts**: `docs/plans/model-generation-wave-handoff.md` (full continuation
  kit incl. the measured `gpt-6-astra` reasoning-level table and the open
  `cost_factors` decision).

## 2026-09-07 — Audit-remediation wave: 137-agent re-audit fix wave + 4-round SV gate (fix/reaudit-wave-1)

- **Target**: audit-remediation wave from a 137-agent re-audit of v0.25.0 (8
  HIGH / 24 MEDIUM confirmed findings). This wave fixed the top items: the
  claude-engine worker model ladder was dead (an engine-blind key in
  `check_model_upgrade`), F-8 auto-commit was committing the whole index and
  the D-20 gate was false-reading C-quoted paths, signal traps let the leader
  resume after cleanup instead of terminating, init's PRD/test-spec reset used
  a BSD-only `sed -i ''` and a bare `rm` deletion, the zsh test harness was
  only running 2 of 97 files locally, Node SV reports rendered `undefined`
  over zsh-written analytics, `_auto_detect_engine` used an eval-assignment,
  and seven documentation-vs-code drifts. Branch `fix/reaudit-wave-1` off
  `main` @ 6d94518 (v0.25.0), not yet merged.
- **Method**: parallel implement→independent-review pairs (executor + a
  separate reviewer per item, mutation controls required), then the mandatory
  3-scenario SV gate (LOW L1+L3, MEDIUM L1+L2+L3, CRITICAL
  L1+L2+L3+security+error-path) run over four rounds — each round a fresh
  Worker execution in throwaway sandboxes plus an independent Verifier that
  re-executed the load-bearing assertions itself.
- **Result**: Full suites: `npm run test:node` 720/720, `npm run test:zsh`
  102 files exit 0, `zsh tests/sv-gate-fast.sh` 99/99, `npm run
  manifest:check` in sync. SV gate: round 1 FAIL (see findings); rounds 2 and
  3 returned PASS verdicts from their verifiers, but **the round-3 verdict
  did not hold** — its state was subsequently shown to violate the committed
  contract AC1-L3-neg, because the gate's scenario set did not include
  `tests/test_us001_prd_splitting.sh`, so round 3's PASS was issued against an
  incomplete assertion set. Round 4 **PASS (3/3)** after the correction, from
  an independent verifier who re-executed every load-bearing assertion in 12
  fresh sandboxes and killed 11 of 11 mutants (round-4 worker: 27/27
  assertions). Whole-branch final review, run after the gate concluded:
  **MERGE-READY**.
- **Findings**:
  - Round-1 gate found two **pre-existing** `split_prd_by_us` defects the
    diff had not touched — a missing null-glob qualifier crashing `--mode
    fresh` on dash-form US headings and leaving the test-spec missing, and
    `awk -v` eating backslashes in project paths — **fixed**.
  - Later rounds found the same defect class in `split_test_spec_by_us`, plus
    a `close(out)`-then-reopen truncation that silently discarded a US body,
    and a tmp-file leak — **fixed**.
  - HIGH — a round-2 verifier found the first A-5 signal-trap fix was wrong:
    a function-scoped `EXIT` trap runs only its first command when the
    process is terminated by `exit`, so cleanup never ran — **fixed** with
    `setopt POSIX_TRAPS` plus an explicit chain.
  - HIGH — the team lead's own full `test:zsh` run caught that this wave's
    heading-regex unification had broken the committed negative contract
    AC1-L3-neg in `tests/test_us001_prd_splitting.sh` (a 2-hash `## US-NNN:`
    PRD heading must not split) — neither per-item green suites, per-item
    review, nor the round-3 gate itself had caught it, because the gate's own
    scenario set never ran that file. **Fixed**: reverted to a strict 3-hash
    PRD constant, with a separate permissive constant retained only for
    `_extract_prd_us_list`.
  - HIGH (process) — a gate whose scenario set omits an existing committed
    contract test can return a **false PASS**: round 3 passed while that
    exact contract was broken. `tests/test_us001_prd_splitting.sh` (and the
    full `npm run test:zsh`) must be part of the gate's suite list for any
    change touching the split/heading paths, not run only afterward by the
    team lead.
  - Round 4 (corrective) evidence: independent verifier **PASS 3/3**; mutant
    kill table **11/11**, with `tests/test_init_data_safety.sh` (73
    assertions) as the load-bearing net and `tests/test_us001_prd_splitting.sh`
    killing the ERE-widening mutant specifically. Suites re-run by the
    verifier itself: `test_us001_prd_splitting.sh` 19,
    `test_init_data_safety.sh` 73, `test_us004_self_verification.sh` 46,
    `test_us008_self_verification_e2e.sh` 33, `test_us006_init_presets.sh` 13,
    `test_vision_adopt.sh` 21, `sv-gate-bug7-mode-prose.sh` 16,
    `test_request_f_docs.sh` 13, `sv-gate-fast.sh` 99 — all passing.
  - MEDIUM — one mutant (removal of the render self-heal) escaped the
    committed suite in round 2 — **fixed**, now covered by new test cases.
  - Lesson: per-item green suites and per-item reviews both missed the
    cross-cutting contract break, and a scenario set that does not enumerate
    every existing committed contract test can pass a gate round while that
    contract is broken; only the full-suite run and the corrective round-4
    re-verification caught and closed it. Mutation controls and `git show
    HEAD:` oracles were required of every new test in this wave going
    forward.
- **Artifacts**: done-claims and per-round archives under the session
  scratchpad `svgate/scenario-{low,medium,critical}.done-claim.json` (+
  `.round1..round3.json`); new test files `tests/test_init_data_safety.sh`
  (73 assertions), `tests/test_signal_trap.sh`,
  `tests/test_auto_detect_engine_safety.sh`,
  `tests/test_git_dirty_names_lib.sh`, `tests/test_lib_split_heading_forms.sh`,
  `tests/node/c1c2-analytics-reader-hardening.test.mjs`.

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
