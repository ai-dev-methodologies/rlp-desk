# Bug Report Mechanism Overhaul — v1 (Architect-revised)

> **Status**: Planner v1 awaiting Codex Critic.
> **Mode**: deliberate.
> **Stop rule**: iterate until codex critic returns 0 P0 + 0 P1. P2 → backlog.
> **Critic instruction**: *approve unless P0 or P1 found.*
> **Changes from v0**: Architect ITERATE feedback applied — split into 3 sequenced PRs, exact file:line for Bug #10, `pattern_match` seed → P2 backlog, explicit `native-agent-revert` dependency, governance §1g rationale.

---

## 1. Problem statement (unchanged from v0)

10 hand-written 200-line bug reports (`Bug #1`–`Bug #10`, BOS dev `2026-05-01..05-07`) point at one root frustration: **bugs are endless and each one costs 30+ min of operator time to package** before the rlp-desk side can even start triage. Two distinct cost lines:

| Pain | Evidence | Cost line |
|---|---|---|
| **Recovery friction** (lose work on relaunch) | Bug #10 100%-reproducible: leader resets `phase=worker`, deletes operator-written iter-signal/done-claim | per BLOCKED, lost 30+ min of manual work |
| **Capture friction** (hand-write report) | All 10 reports re-collect env, version, command, pane logs, settings, gitignore — already on disk | per BLOCKED, 30+ min hand-writing |
| Cluster blindness | Bug #6/#7/#8 are all "worker hang variants"; cluster re-discovered each time | amortized over many BLOCKED |
| Reactive only | Bugs surface only after 30-min poll timeout | per BLOCKED, 30 min wall-clock |

The blocked-sentinel JSON (`schema_version: 2.0`) already classifies (`reason_category` / `recoverable` / `suggested_action`) but stops at the campaign boundary — it does not become a *bug report*. That gap is the target.

---

## 2. Principles (5)

1. **Capture-by-default, not by-request.** When the campaign blocks, the operator should not have to gather anything that already exists on disk.
2. **One canonical schema, two consumers.** A single `bug-report.json` feeds both BOS-side templates and rlp-desk-side triage; no divergent representations.
3. **Surgical diffs over new infra.** Extend the existing `blocked.{md,json}` writer + `/rlp-desk` subcommand surface; do not introduce a new daemon, queue, or service. **Sequenced PRs > one big PR.**
4. **Recovery must be idempotent.** Manual recovery of a BLOCKED campaign must not be silently overwritten on relaunch (Bug #10 contract).
5. **Earlier is cheaper.** A heartbeat-anomaly *warning* costs nothing; a 30-min BLOCKED poll-timeout is the most expensive form of feedback.

---

## 3. Decision drivers (top 3)

| # | Driver | Why it dominates |
|---|---|---|
| D1 | **Operator minutes per BLOCKED → first actionable report** | Today: 30+ min recovery + 30+ min hand-writing = 60+ min. Target: ≤2 min recovery (just relaunch) + ≤2 min report review. |
| D2 | **Cluster recognition (avoid duplicate `Bug #N` for same root cause)** | 5 of 10 reports cluster around "worker hang on sentinel" or "verifier post-sentinel race". Without similarity hinting we keep paying triage cost N times. |
| D3 | **Zero regression on `--mode tmux` 19th launch** + **zero merge collision with `feat/native-agent-revert`** | Per `docs/plans/native-agent-revert.md:7`, the production tmux path is mid-flight. PR-A (Bug #10 hygiene) and PR-B (bundler) BOTH must wait for `native-agent-revert` to land. Documented as hard dependency below. |

**Architect-flagged ranking shift**: the per-BLOCKED cost of *recovery loss* (Bug #10) > per-BLOCKED cost of *hand-writing*. PR-A (Bug #10) lands first because it has higher per-event leverage AND smaller surface.

---

## 4. Viable options

### Option A — **Sequenced bundle**: PR-A relaunch hygiene, PR-B bundler, PR-C governance/patterns *(recommended)*

Three sequenced PRs landed in order. Each has a single, narrow purpose; review surface bounded; dependencies explicit.

**Pros**: Surgical-diff principle satisfied; merge-conflict risk with `native-agent-revert` minimized; each PR reverts cleanly; per-PR self-verification scenarios stay scoped.

**Cons**: more wall-clock to land the full vision (3 land-cycles instead of 1). Acceptable: PR-A alone moves D1 by ~50% on its own.

### Option B — **One mega-PR** *(rejected per Architect)*

The v0 plan, kept here for the record. **Invalidated** because (a) merge collision with `native-agent-revert` is near-certain on `campaign-main-loop.mjs` + `governance.md` + `commands/rlp-desk.md` (3 of the 5 modified files overlap), (b) self-verification scope balloons (one PR triggers MEDIUM+CRITICAL on too many subsystems), (c) Bug #10 fix is delayed by bundler's review surface.

### Option C — **Heartbeat-first (early warning)** *(deferred to backlog)*

Same as v0 — orthogonal to the report-quality problem; defer to backlog.

### Option D — **External tracker integration** *(rejected, principle 3 violation)*

Same as v0.

### Option E — **Doc template only** *(rejected, does not move D1/D2)*

Same as v0.

### Why A wins

A directly addresses D1 (PR-A: recovery, PR-B: capture), D2 (PR-C: pattern_match operationalized), and D3 (PRs sequenced AFTER `native-agent-revert`). C is complementary; B/D/E fail principles or drivers.

---

## 5. Scope

### Hard dependency (all PRs)

**`feat/native-agent-revert` (P0+P1) MUST merge to `main` before PR-A starts.** Source: `docs/plans/native-agent-revert.md:7`. Documented in §3 D3. No PR-A/B/C work begins on shared files until that merge is verified by `git log main --oneline | head -3` showing the native-revert P0+P1 commits.

### PR-A — **Bug #10 relaunch hygiene** (lands first; ~1 file modified, ~1 test added; ~50-line surgical diff)

**P0**:

1. **Inject phase=verify honor branch** at `src/node/runner/campaign-main-loop.mjs`. Two surgical edits:
   - Verified ground-truth (read 2026-05-07): `readCurrentState` (`:364-389`) at `:371` already preserves `status.phase`. The bug is that the main loop unconditionally writes `state.phase = 'worker'` at `:1575` (every iteration, top of body) before `dispatchWorker`. Architect-flagged misattribution in v0 corrected.
   - Edit 1: after `readCurrentState` (`:1256`), BEFORE the main `while` loop, add a single-iteration "phase=verify recovery branch":
     ```
     if (state.phase === 'verify' && state.iteration > 0) {
       const valid = await _validateOperatorRecoveryArtifacts(paths, state);  // 5 checks (see §7 S2)
       if (valid) {
         _logRecovery('Resuming verify phase — operator manual recovery detected');
         state.phase = 'verify';                  // explicit re-affirm
         state._skipNextWorkerDispatch = true;    // consumed at :1575
       } else {
         _logRecovery(`phase=verify ignored: ${valid.reason}`);
         // fall through; default behavior (worker dispatch) remains
       }
     }
     ```
   - Edit 2: at `:1575`, guard the unconditional reset:
     ```
     if (!state._skipNextWorkerDispatch) {
       state.phase = 'worker';
       await writeStatus(...);
       await dispatchWorker(...);
     } else {
       state._skipNextWorkerDispatch = false;     // one-shot
     }
     ```
   - `_validateOperatorRecoveryArtifacts` is a new internal helper in the same file (~25 lines): exists+parses `iter-signal.json` AND `done-claim.json`; `us_id == state.current_us`; `iteration == state.iteration`; `iter_signal_quality == 'specific'`; both files newer than the most recent `iter-NNN.worker-prompt.md` mtime.
2. **Mirror the same guard in `src/scripts/run_ralph_desk.zsh`** for `--mode tmux`. **Verified injection points (read 2026-05-07, P1-1 corrected from v1)**: the iteration-body reset is **not** in any `start_iteration()` function — it lives at the top of the iteration body. Three concrete sites:
   - `:3053` — `rm -f "$SIGNAL_FILE" "$DONE_CLAIM_FILE" "$VERDICT_FILE"` **deletes operator-written recovery artifacts**. PR-A guard MUST wrap this with: skip the rm when `LAST_PHASE == "verify"` AND validator passes.
   - `:3084` — `update_status "worker" "running"` forces phase=worker. PR-A guard: skip when phase=verify+valid.
   - `:3087` (and following dispatch block down to ~`:3110`) — worker launch. PR-A guard: when phase=verify+valid, jump straight to verifier dispatch (mirrors the per-US verifier dispatch already in the file; reuse `dispatch_verifier_per_us`).
   - 5-check validator added to `lib_ralph_desk.zsh` as `_validate_operator_recovery_artifacts` (LAST_PHASE read from earlier `read_status` call site, audited at impl time).

**Tests**:

- `tests/node/test-relaunch-phase-verify-hygiene.test.mjs` (NEW) — 5 ACs (R1–R5 in §8).
- `tests/test-bug10-zsh-relaunch-hygiene.sh` (NEW) — zsh side, mirrors `test-bug7-post-sentinel-race.sh` style.

**No governance change in PR-A.** No new sentinel writer. Just the guard + helper + tests.

### PR-B — **Bug-report bundler** (lands second; ~3 modified + 4 new; bundler module + subcommand)

**P0**:

3. **`bug-report.json` writer** — new `src/node/shared/bug-report.mjs` exposes `writeBugReport({slug, classification, reason, paths, env, paneTails, recentArtifacts, now})`. Called from `_emitBlockedSentinel` in `campaign-main-loop.mjs:920-968` AFTER the existing JSON sidecar write succeeds. Idempotent via `writeSentinelExclusive` semantics (per-block `<iso>` filename).
4. **Mirror in zsh**: `_write_bug_report` in `lib_ralph_desk.zsh`, called from `write_blocked_sentinel`. Exact call-site count audited at implementation time (current grep shows ~10 invocations, all in one taxonomy).
5. **Redaction pass** — deny-list applied before write (12 secret-shape regex from §8 AC-W2); `meta.redacted_line_count` exposed for operator audit. Markdown render reads from JSON post-redaction.
6. **`pattern_match` field reserved-but-empty** — schema includes it; bundler writes `{ candidate_bug_ids: [], score: null, source: "deferred-to-PR-C" }`. No `docs/bug-patterns.json` shipped in PR-B.

**P1**:

7. **`/rlp-desk report <slug>` subcommand** — new section in `src/commands/rlp-desk.md`; reads latest `bug-reports/<slug>-*.json`, prints markdown to stdout. Optional `--headline "..."` flag. **No remote publish.**
8. **Schema doc** — `docs/rlp-desk/bug-report-schema.md` (NEW): JSON schema + worked example + .gitignore snippet recommendation.

**Tests**:

- `tests/node/test-bug-report-writer.test.mjs` (NEW) — 5 ACs (W1–W5 in §8).
- `tests/test-bug-report-zsh-emit.sh` (NEW).
- `tests/node/us006-campaign-main-loop.test.mjs` extension — 2 integration ACs (I1–I2 in §8).

### PR-C — **Pattern operationalization + governance §1g** (lands third; pattern data + governance ride-along justified)

**P1**:

9. **`docs/bug-patterns.json`** (NEW) — seed signatures for Bug #1–#10, hand-authored from BOS reports. Schema: `{bug_id, signature: {reason_category, failure_category, pane_token_bag[]}, fix_pr_url}`.
10. **Pattern-match implementation** — `bug-report.mjs` Jaccard implementation populates `pattern_match.candidate_bug_ids[]` + `score` (P2 cap: ≥0.7 = "candidate", < 0.7 = empty list). Output remains data-only — no inline CLI suggestion. v0 §7 S3 mitigation preserved.
11. **Governance §1g "Bug Report Capture"** — additive section; documents (a) every BLOCKED writes a bug-report invariant, (b) redaction rules + audit field, (c) PR-A relaunch hygiene contract (operator's recovery is honored). **Ride-along rationale**: §1g formalizes the contract that PR-A and PR-B implement; landing them as separate PRs without governance text leaves the invariants implicit. Per CLAUDE.md, governance changes require `ralplan + codex review` — this very plan satisfies that for §1g; PR-C's review surface is *only* the §1g text + pattern data + Jaccard ≤80 LOC implementation. Bounded.

**Tests**:

- `tests/node/test-bug-report-pattern-match.test.mjs` (NEW) — Jaccard determinism, threshold, regression on synthetic Bug #6 fixture. AC-W4 from §8 (relocated from PR-B).

### P2+ → `docs/plans/bug-report-overhaul-backlog.md` (separate file, NOT this PR-A/B/C set)

- Heartbeat-warning sidecar (Option C).
- GitHub Issues integration (Option D, after authn story).
- Pattern-learning loop that mines `~/.claude/ralph-desk/analytics/*/bug-reports/` for emerging clusters.
- Cross-campaign bug-report dashboard in `/rlp-desk analytics`.
- Auto-suggest "this looks like Bug #N — try fix-X" inline in CLI output (today: data-only).
- Operator-CLI `/rlp-desk recover <slug> --to verify` to write the manual recovery artifacts deterministically (currently a hand-rolled jq pipeline).

---

## 6. Files to modify (summary across PR-A/B/C)

| PR | File | Change | Risk |
|---|---|---|---|
| A | `src/node/runner/campaign-main-loop.mjs` | Phase-verify recovery branch (after `:1256`); guard at `:1575`; `_validateOperatorRecoveryArtifacts` helper | **MED** (control-flow change in main loop) |
| A | `src/scripts/lib_ralph_desk.zsh` | `_validate_operator_recovery_artifacts` helper | LOW |
| A | `src/scripts/run_ralph_desk.zsh` | Phase-verify recovery branch wrapping the iteration-body sites at `:3053` (rm guard), `:3084` (update_status guard), `:3087` (worker dispatch skip → verifier dispatch jump). No `start_iteration` function exists — iteration body starts at the top of the main while loop after the cleanup block. | **MED** |
| A | `tests/node/test-relaunch-phase-verify-hygiene.test.mjs` | NEW — 5 ACs | LOW |
| A | `tests/test-bug10-zsh-relaunch-hygiene.sh` | NEW | LOW |
| B | `src/node/shared/bug-report.mjs` | NEW module — writer + redaction; `pattern_match` reserved-empty | LOW |
| B | `src/node/runner/campaign-main-loop.mjs` | Call `writeBugReport` from `_emitBlockedSentinel` (post existing JSON write) | LOW |
| B | `src/scripts/lib_ralph_desk.zsh` | `_write_bug_report` helper | MED |
| B | `src/scripts/run_ralph_desk.zsh` | Wire `_write_bug_report` after `write_blocked_sentinel` sites | MED |
| B | `src/commands/rlp-desk.md` | Add `## report <slug>` + help-block entry | LOW |
| B | `docs/rlp-desk/bug-report-schema.md` | NEW | LOW |
| B | `tests/node/test-bug-report-writer.test.mjs` | NEW | LOW |
| B | `tests/test-bug-report-zsh-emit.sh` | NEW | LOW |
| B | `tests/node/us006-campaign-main-loop.test.mjs` | +2 integration ACs | LOW |
| C | `docs/bug-patterns.json` | NEW seed | LOW |
| C | `src/node/shared/bug-report.mjs` | Jaccard implementation (≤80 LOC); replaces reserved-empty logic | LOW |
| C | `src/governance.md` | Additive §1g | LOW (additive) |
| C | `tests/node/test-bug-report-pattern-match.test.mjs` | NEW | LOW |

**PR-A**: 3 modified + 2 new = 5 files.
**PR-B**: 4 modified + 4 new = 8 files.
**PR-C**: 2 modified + 2 new = 4 files.

Each PR's review surface bounded; merge-conflict surface with `native-agent-revert` is empty (PRs sequenced AFTER it lands).

---

## 7. Pre-mortem (deliberate mode — 3 scenarios; updated for v1)

### S1 — Pane-tail leaks a secret into a committed bug-report (PR-B risk)

(unchanged from v0; mitigation in PR-B test AC-W2; `meta.redacted_line_count` audit field; schema doc recommends `.gitignore` snippet but does not auto-modify user repo)

### S2 — Bug #10 fix accidentally honors a stale `phase=verify` from a CRASHED leader (PR-A risk)

The 5-validation gate (exists × 2, us_id match, iteration match, `iter_signal_quality=='specific'`, mtimes-newer-than-worker-prompt) blocks the most likely race. PR-A also adds a `_logRecovery` audit line for every relaunch outcome (honored / ignored + reason) so operators can confirm in `/rlp-desk logs <slug>`.

**Residual risk**: a clever filesystem race can pass all five checks. Backlog item: `/rlp-desk recover <slug> --to verify` opt-in flag (P2). Until then, the validator's strictness (any miss → fall through to current behavior) makes the failure mode "no improvement" not "regression".

### S3 — `pattern_match` false-positive trains operators to dismiss real bugs (PR-C risk)

In PR-B, `pattern_match` is empty/reserved — no risk. In PR-C, threshold 0.7 + Jaccard determinism + data-only output. Operator sees `score: 0.83 — review before assuming match`. Auto-suggest deferred to P2.

**Architect-flagged risk added (S4)**: PR-A's `state._skipNextWorkerDispatch` is a one-shot mutation on a shared object. **Mitigation**: explicitly cleared inside the guard branch (Edit 2 above); PR-A includes a unit test that runs 2 consecutive iterations and asserts the worker IS dispatched on iter-2.

---

## 8. Expanded test plan (deliberate mode)

### PR-A unit (Node) — `tests/node/test-relaunch-phase-verify-hygiene.test.mjs`

- AC-R1: status.phase=verify + valid artifacts → verifier-only entry (no worker dispatch).
- AC-R2: status.phase=verify + missing `done-claim.json` → fall through to worker, log warning.
- AC-R3: status.phase=verify + `us_id` mismatch → fall through, warning.
- AC-R4: status.phase=verify + `iter-signal.json` older than worker-prompt.md → fall through, warning.
- AC-R5: status.phase=verify + `iter_signal_quality != 'specific'` → fall through, warning.
- AC-R6 (Architect S4): `_skipNextWorkerDispatch` cleared after one use; iter-2 worker dispatched normally.

### PR-B unit (Node) — `tests/node/test-bug-report-writer.test.mjs`

- AC-W1: schema fields all present + types match `docs/rlp-desk/bug-report-schema.md`.
- AC-W2: redaction — 12 secret-shape fixtures all replaced by `<REDACTED>`; `meta.redacted_line_count` reflects count.
- AC-W3: pane-tail truncates at 200 lines; preserves last lines.
- AC-W5: idempotent — second call with same `(slug, iso)` is a no-op.
- (AC-W4 relocated to PR-C — Jaccard pattern match.)

### PR-B integration (Node) — `tests/node/us006-campaign-main-loop.test.mjs` extension

- AC-I1: BLOCKED via `flywheel_inconclusive` → bug-report file written; JSON parses; `reason_category == 'mission_abort'`.
- AC-I2: BLOCKED via `worker_exited` → bug-report `pattern_match` field exists with `{candidate_bug_ids: [], score: null, source: "deferred-to-PR-C"}`.

### PR-C unit (Node) — `tests/node/test-bug-report-pattern-match.test.mjs`

- AC-W4: pattern_match against seeded `docs/bug-patterns.json` — synthetic block matching Bug #6 signature returns `score >= 0.7` + correct `candidate_bug_ids`.
- AC-W4b: synthetic block with no matches → `candidate_bug_ids: []`, `score < 0.7`.

### Integration (zsh)

- `tests/test-bug10-zsh-relaunch-hygiene.sh` (PR-A).
- `tests/test-bug-report-zsh-emit.sh` (PR-B). Sc-1 + Sc-2 from v0.

### Self-Verification scenarios (CLAUDE.md gate)

**PR-A** (touches `run_ralph_desk.zsh` → CLAUDE.md mandates 3 SV scenarios):

- LOW: 5-AC unit suite green; existing zsh + Node regression green.
- MEDIUM: real campaign brought to BLOCKED via stub failure; operator runs the documented recovery flow (jq patches `phase=verify`, writes manual artifacts); relaunch → verifier-only path runs (no `iter-002.worker-prompt.md` created); verdict accepted.
- CRITICAL: same as MEDIUM but also assert the `_skipNextWorkerDispatch` flag does not survive into iter-3; `/rlp-desk logs` shows `Resuming verify phase` audit line.

**PR-B** (touches `run_ralph_desk.zsh` again → 3 SV scenarios):

- LOW: redaction unit fixture passes.
- MEDIUM: real campaign with stub worker fails → `bug-reports/<slug>-<iso>.{json,md}` appears; markdown render contains all required sections; `/rlp-desk report <slug>` prints same markdown.
- CRITICAL: redaction smoke — pane log pre-injected with `Bearer X` and `OpenAI-API-Key: sk-...`; bug-report JSON does not contain those substrings; `meta.redacted_line_count >= 2`.

**PR-C** (governance + patterns; no runtime code path → CLAUDE.md gate ride-along scenarios):

- LOW: Jaccard unit suite green.
- MEDIUM: synthetic block matching Bug #6 → bug-report `pattern_match.candidate_bug_ids` includes `Bug-6`.
- CRITICAL: ralplan + codex review of governance §1g additions reaches 0 issues.

---

## 9. Verification end-to-end (per PR)

(Each PR verified independently before next PR starts.)

1. `node --test 'tests/node/*.test.mjs'` all green; new PR-specific tests visible.
2. zsh integration test for that PR green.
3. Bug #7 regression suite (`test-bug7-post-sentinel-race.sh`, `test-bug7-poll-partial-write.sh`) unchanged green.
4. CLAUDE.md SV gate × 3 for that PR — all PASS.
5. **Local sync verification (P1-2 corrected from v1)** — depends on which file types changed:
   - **Node files only** (PR-C): `node scripts/postinstall.js` + banner-aware diff `src/` ⇆ `~/.claude/ralph-desk/` per CLAUDE.md.
   - **zsh wrappers changed** (PR-A and PR-B both touch `src/scripts/{run,lib}_ralph_desk.zsh`): `node scripts/postinstall.js` does NOT install the legacy zsh wrappers (CLAUDE.md `Local File Sync` §: "synced ONLY via `bash install.sh` curl path"). Required additional steps:
     - `bash install.sh` from a clean shell to drive the curl-path installer.
     - Verify zsh wrappers landed: `ls -la ~/.claude/ralph-desk/install.sh ~/.claude/ralph-desk/scripts/{init,run,lib}_ralph_desk.zsh`. Each must be banner-headed (`# DO NOT EDIT ...` line 2 after the shebang) and `chmod 0o444`.
     - Banner-aware diff: `diff <(cat src/scripts/run_ralph_desk.zsh) <(tail -n +3 ~/.claude/ralph-desk/scripts/run_ralph_desk.zsh)` (skip shebang + banner).
     - Document which install channel was exercised in the SV scenario notes so future audits can replay.
6. Manual sandbox campaign trigger (PR-A: deliberate BLOCKED + recovery; PR-B: BLOCKED + read bug-report markdown; PR-C: pattern_match populated).

---

## 10. ADR (preview — final once Critic approves)

- **Decision**: Adopt Option A (sequenced PR-A→PR-B→PR-C) for v0.16.x; defer heartbeat-warning, external tracker, and operator recovery CLI to backlog.
- **Drivers**: D1 operator-minutes, D2 cluster-recognition, D3 zero `--mode tmux` regression + zero `native-agent-revert` collision.
- **Alternatives considered**: B (one mega-PR) rejected per Architect for merge collision + SV scope balloon; C (heartbeat) orthogonal — backlog; D (GitHub Issues) violates principle 3; E (doc only) does not move D1/D2.
- **Why chosen**: PR-A fixes the highest per-event cost (recovery loss). PR-B captures-by-default with redaction. PR-C operationalizes patterns and formalizes governance §1g. Each PR has bounded review surface and clean revert.
- **Consequences**: BLOCKED writes additional artifacts (`bug-reports/<slug>-<iso>.{json,md}`); operator recovery is honored; `bug-patterns.json` becomes a living artifact; governance gains §1g formal contract.
- **Follow-ups**: Backlog file lists P2+ items. Heartbeat warning revisited after we measure operator minutes-saved on first 3 BLOCKED post-PR-A land.

---

## 11. Round-by-round resolution log

| Round | Reviewer | Verdict | Findings closed |
|---|---|---|---|
| 0 | — | Planner v0 | initial draft |
| 1 | Architect (Claude) | ITERATE | (1) split into PRs (2) cite file:line (3) pattern_match → backlog/PR-C (4) native-revert dependency (5) governance §1g rationale |
| 2 | Codex Critic | ITERATE — 0 P0, 2 P1 | P1-1 zsh sites corrected to `:3053/:3084/:3087` (no `start_iteration` function); P1-2 sync gap closed (zsh = `bash install.sh` channel + banner+chmod verify). BACKLOG: P2-1/P2-2/P3-1 captured below. |
| 3 | Codex Critic | **APPROVE** — 0 P0, 0 P1 | Round 2 P1-1/P1-2 confirmed closed by ground-truth checks (zsh sites at `:3053/:3084/:3087` + CLAUDE.md `bash install.sh` channel). New P2 (lib_ralph_desk.zsh diff) → backlog. |

**Loop terminated**: Codex Critic returned APPROVE at Round 3. P0+P1 findings = 0. Per user stop rule, ralplan exits. P2/P3 captured in `bug-report-overhaul-backlog.md`.
