# Architect Review: v0.6 Refactoring Plan (RALPLAN Consensus)

**Verdict: ITERATE** — The plan is directionally sound but has two concrete issues that must be resolved before execution.

---

## Summary

The Planner's Option C (extract `lib_ralph_desk.zsh` as a shared business-logic module) is architecturally correct and the rejection of TeamCreate is well-reasoned. However, the plan underestimates two zsh-specific risks in the extraction and contains a gap in the final-verify-split proposal. I recommend proceeding with Option C after addressing the issues below.

---

## Analysis

### 1. Steelman Antithesis: The Strongest Case Against Option C

**The best argument against Option C is not that TeamCreate is better — it is that the extraction creates a maintenance burden for zero immediate user value.**

Consider: Agent() mode (rlp-desk.md) is an LLM template, not a shell script. It does not call `get_next_model()`, `check_model_upgrade()`, `write_worker_trigger()`, or any zsh function. The Agent mode Leader is Claude Code itself, interpreting markdown instructions. There is no code to share between the two modes because one mode is shell and the other is natural language.

The Planner claims "~1,900 lines are business logic" shareable between modes. But examining the actual functions:

- `write_worker_trigger()` (lines 1162-1297): Constructs shell trigger scripts with heredocs embedding `$CLAUDE_BIN`, `$CODEX_BIN`, heartbeat PIDs — entirely tmux-specific.
- `write_verifier_trigger()` (lines 1299-1389): Same pattern — generates shell trigger scripts for tmux panes.
- `poll_for_signal()` (lines 1955-2104): Polls tmux panes, monitors heartbeats, nudges idle panes, auto-approves permission prompts via `tmux send-keys` — 100% tmux plumbing.
- `run_single_verifier()` (lines 2276-2372): Manages tmux pane lifecycle (kill, split, reset), then launches into pane — tmux-specific.
- `run_consensus_verification()` (lines 2393-2539): Calls `run_single_verifier()` — inherits tmux dependency.
- `cleanup()` (lines 1807-1948): Kills tmux panes, generates campaign report — tmux lifecycle.
- `main()` (lines 2561-3126): The entire main loop — creates tmux sessions, polls panes, manages pane lifecycle.

The genuinely **mode-independent** functions are a smaller set than claimed:

| Function | Lines | Truly Shareable? |
|----------|-------|-----------------|
| `log()` / `log_debug()` / `log_error()` | 152-165 | Yes |
| `parse_model_flag()` | 173-192 | Yes |
| `get_model_string()` | 219-229 | Yes |
| `get_next_model()` | 440-469 | Yes |
| `check_model_upgrade()` | 475-527 | Yes |
| `atomic_write()` | 531-536 | Yes |
| `validate_scaffold()` | 635-669 | Yes |
| `update_status()` | 1391-1432 | Yes |
| `write_result_log()` | 1435-1471 | Yes |
| `archive_iter_artifacts()` | 1474-1484 | Yes |
| `write_cost_log()` | 1487-1524 | Yes |
| `write_campaign_jsonl()` | 1527-1558 | Yes |
| `generate_campaign_report()` | 1561-1706 | Yes |
| `generate_sv_report()` | 1708-1779 | Yes |
| `compute_prd_hash()` | 2111-2121 | Yes |
| `count_prd_us()` | 2123-2133 | Yes |
| `split_prd_by_us()` | 2135-2158 | Yes |
| `split_test_spec_by_us()` | 2160-2193 | Yes |
| `check_prd_update()` | 2195-2232 | Yes |
| `compute_context_hash()` | 2234-2250 | Yes |
| `check_stale_context()` | 2252-2274 | Yes |
| `inject_per_us_prd()` | 1144-1157 | Yes |

This is roughly 700-800 lines of genuinely shareable logic, not 1,900. The rest is deeply intertwined with tmux pane management. The "~1,100 lines of business logic" claim needs recalibration.

**But here is why the antithesis ultimately fails:** Even if Agent() mode cannot directly `source` these functions (it is an LLM, not a shell), extracting them still has value:
1. **Testing**: The `extract_fn()` test pattern (used across all 35 test files) extracts functions from `run_ralph_desk.zsh` by awk-ing function boundaries. A dedicated `lib_ralph_desk.zsh` would make tests cleaner — `source lib_ralph_desk.zsh` instead of fragile awk extraction.
2. **Readability**: 3,184 lines in one file is objectively hard to navigate.
3. **Future extensibility**: If a third orchestration mode appears (e.g., Docker, SSH), the shared lib is ready.

**Synthesis**: Option C is correct, but the extraction scope should be the ~800 lines of genuinely mode-independent logic, not the inflated ~1,900 line estimate. The tmux-entangled functions stay in `run_ralph_desk.zsh`.

### 2. Tradeoff Tension: "Simplify" vs. "Preserve"

The plan says it preserves both Agent() and tmux modes while "simplifying" via extraction. But there is a fundamental tension:

**Agent() mode is an LLM interpreting markdown. Tmux mode is a shell script.** They do not share code. They share *concepts* (the governance protocol). The governance.md document IS the shared abstraction — it already serves as the "lib" for Agent mode.

Extracting shell functions into `lib_ralph_desk.zsh` simplifies tmux mode's file organization, but does nothing to reduce the conceptual duplication between the modes. Every governance rule appears in three places:
1. `governance.md` (the canonical spec)
2. `rlp-desk.md` (Agent mode instructions, lines 296-555)
3. `run_ralph_desk.zsh` (tmux mode implementation)

The lib extraction does not reduce this triple-statement problem. If the user later changes the circuit breaker threshold logic, they must still update all three files.

**This is not a blocking issue** — it is a tension to acknowledge in documentation. The plan should explicitly state: "lib extraction reduces file-level complexity but does not reduce specification duplication. governance.md remains the single source of truth; both modes implement it independently."

### 3. Architecture Soundness: zsh-specific `source` Pitfalls

The plan calls the extraction "purely mechanical (move functions, add source statement)." This is dangerously optimistic for zsh. Two concrete risks:

**Risk A: Global variable scoping across `source` boundaries.**

`run_ralph_desk.zsh` uses three `typeset -A` associative arrays at file scope (line 118-120):
```
typeset -A LAST_PANE_CONTENT
typeset -A PANE_IDLE_SINCE
typeset -A WORKER_RESTARTS
```

These are tmux-specific and would stay in `run_ralph_desk.zsh`. But 30+ other global variables (lines 47-143) — `SLUG`, `WORKER_MODEL`, `ITERATION`, `VERIFIED_US`, `CONSECUTIVE_FAILURES`, etc. — are read and mutated by functions throughout the file. After extraction:

- `lib_ralph_desk.zsh` functions (e.g., `check_model_upgrade()` at line 475) mutate globals like `_SAME_US_FAIL_COUNT`, `_LAST_FAILED_US`, `_MODEL_UPGRADED`, `WORKER_MODEL`, `WORKER_CODEX_MODEL`, `WORKER_CODEX_REASONING`.
- These globals are defined in `run_ralph_desk.zsh` before `source lib_ralph_desk.zsh`.
- In zsh, `source` shares the caller's scope — globals survive across source boundaries. **This works.**
- But `typeset` inside a function creates a **local** variable in zsh (unlike bash where `declare` in a function is local but at top-level is global). If any extracted function uses `typeset` internally, it creates a local shadow, not a global mutation. This is already the case in the current code so it is not a new problem, but the extractor must verify no `typeset` statements are accidentally introduced during the move.

**Risk B: `local` vs. global mutation in extracted functions.**

`check_model_upgrade()` (line 475-527) directly mutates globals: `_SAME_US_FAIL_COUNT`, `_LAST_FAILED_US`, `_MODEL_UPGRADED`, `_ORIGINAL_WORKER_MODEL`, `WORKER_MODEL`, `WORKER_CODEX_MODEL`, `WORKER_CODEX_REASONING`. After moving to `lib_ralph_desk.zsh`, these mutations will still work because zsh functions see the calling scope's globals. **But**: if someone later wraps the `source` call inside a function (e.g., `load_lib()`), the scoping changes — `typeset -A` in the sourced file would become local to `load_lib()`. The source statement must remain at the file's top level.

**Mitigation**: Add a comment in `run_ralph_desk.zsh` line 1 area: `# IMPORTANT: source lib_ralph_desk.zsh at file scope, NOT inside a function.`

### 4. Risk the Planner Missed: Test Breakage Pattern

All 35 test files use the `extract_fn()` pattern (confirmed at `tests/test_engine_refactor.sh:12-14`, `tests/test_us009_api_retry_guard.sh:11-31`, `tests/test_us004_progressive_upgrade.sh:17-20`):

```bash
RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" { p=1 } p { print } p && /^}/ { p=0 }' "$RUN"
}
```

After extraction, functions that move to `lib_ralph_desk.zsh` will no longer be found by `extract_fn()` because `$RUN` still points to `run_ralph_desk.zsh`. The plan says "171 tests continue working with updated paths" — this requires either:

**Option 1**: Update `$RUN` in each test to `$LIB` for functions in the lib (changes to 35 files).
**Option 2**: Have `run_ralph_desk.zsh` physically `source` the lib, so extracting from the combined output works. But `extract_fn()` runs awk on a **file**, not on the runtime-sourced combination.
**Option 3**: Add a `LIB="${LIB:-src/scripts/lib_ralph_desk.zsh}"` variable in each test and update `extract_fn()` to search both files.

The Planner did not specify which approach. This is a concrete implementation detail that affects all test files and must be decided before execution. Option 3 is recommended — it is backward-compatible and minimal.

### 5. Final Verify Split: Sequential Per-US

The proposal to split the final ALL verify into sequential per-US checks is sound in principle — it reuses the proven per-US mechanism and avoids the monolithic timeout problem. However:

**Gap: Cross-US integration is the entire point of the final verify.**

The governance spec (`governance.md` lines 184-187) explicitly states:
> Checkpoint 2: Release Readiness (us_id=ALL) — Scope: all AC + L2 integration (if applicable) + L3 E2E Simulation + L4 deploy (if applicable)

The final ALL verify exists to catch **cross-US regressions** — e.g., US-003's changes broke US-001's tests. Sequential per-US re-verification catches per-US regressions but may miss **system-level integration** issues that only manifest when all changes interact.

**Mitigation**: The sequential per-US checks should be followed by a lightweight integration check: run the full test suite once (not per-US scoped). If the full suite passes, COMPLETE. If it fails, the failure is already scoped to specific tests that can be debugged. This is cheap (one test run) and preserves the cross-US safety net.

### 6. Merge Strategy: Squash Merge of 77 Commits

Squash merge is correct for this case:
- 77 commits include campaign iteration artifacts (iter01, iter02, ..., iter14), done-claim corrections, and verification handoffs — these are process noise, not meaningful history.
- The feature branch is `feature/v0.4.1-tmux-sv-report` — a single feature.
- Squash produces one clean commit on main with a clear message.

**One caution**: Verify that `git diff main...HEAD` shows only the intended changes before squashing. Campaign-generated test artifacts or temporary files should not be included.

---

## Root Cause

The plan's core weakness is not its direction (Option C is correct) but its estimation of extraction scope. The "1,900 lines of business logic" figure conflates tmux-entangled orchestration logic with genuinely mode-independent utility functions. This overestimate could lead to an extraction that either (a) tries to extract tmux-dependent code and breaks it, or (b) discovers mid-implementation that the extraction is smaller than planned and loses momentum.

---

## Recommendations

1. **Recalibrate extraction scope** — LOW effort, HIGH impact. The lib should contain ~800 lines of genuinely mode-independent functions (logging, model management, scaffold validation, reporting, PRD/context utilities), not the full 1,900 claimed. Functions that call `tmux` commands or reference pane IDs stay in `run_ralph_desk.zsh`.

2. **Decide test migration strategy** — LOW effort, HIGH impact. Before extraction, decide on Option 3 (dual-file `extract_fn`) and document it. This prevents 35 test files from breaking.

3. **Add a source-scope guard comment** — TRIVIAL effort, MEDIUM impact. `# IMPORTANT: source at file scope, NOT inside a function` at the top of both files. Prevents future scoping bugs.

4. **Add integration check to final verify split** — LOW effort, HIGH impact. After sequential per-US re-checks, run the full test suite once as a cross-US safety net.

5. **Proceed with Phase 0 (npm publish v0.5) first** — as planned. Ship what exists before refactoring.

---

## Consensus Addendum

### Antithesis (steelman)
The strongest argument against Option C: Agent() mode is an LLM interpreting markdown — it will never `source lib_ralph_desk.zsh`. The extraction creates a cleaner tmux codebase but does NOT create a "shared module used by both modes." The "hybrid" framing is misleading. What this actually is: a tmux-mode-internal refactoring that splits one 3,184-line file into two files. That is still valuable, but the value proposition should be stated honestly.

### Tradeoff tension
**File organization simplicity vs. specification duplication**: Extracting a lib simplifies the file structure but does nothing about the triple-statement problem (governance.md + rlp-desk.md + run_ralph_desk.zsh). Every governance change still requires updating three artifacts. The real "shared module" is governance.md itself — both modes implement it from the spec. Until the architecture evolves to make governance.md machine-executable (not just human-readable), this duplication persists regardless of how many .zsh files exist.

### Synthesis
Accept Option C but reframe it: "tmux-mode internal refactoring" rather than "hybrid shared module." This honest framing prevents scope creep (trying to make Agent mode consume the lib) and focuses the extraction on the right ~800 lines. The long-term path to true mode unification would be making governance.md a structured schema that both modes consume programmatically — but that is v0.7+ territory, not v0.6.

### Principle violations
- **Estimation accuracy**: The 1,900-line extraction claim does not survive code inspection. The real shareable set is ~800 lines. This is a planning accuracy issue, not a direction issue.
- **Test impact omission**: The plan claims "171 tests continue working with updated paths" but does not specify the mechanism. The `extract_fn()` pattern hardcodes `$RUN` pointing to one file; extraction breaks this.

---

## References

- `src/scripts/run_ralph_desk.zsh:118-120` — `typeset -A` associative arrays (tmux-specific global state)
- `src/scripts/run_ralph_desk.zsh:440-469` — `get_next_model()` (genuinely shareable business logic)
- `src/scripts/run_ralph_desk.zsh:475-527` — `check_model_upgrade()` (shareable but mutates 7 globals)
- `src/scripts/run_ralph_desk.zsh:1162-1297` — `write_worker_trigger()` (tmux-entangled, NOT shareable)
- `src/scripts/run_ralph_desk.zsh:1955-2104` — `poll_for_signal()` (100% tmux plumbing)
- `src/scripts/run_ralph_desk.zsh:2276-2372` — `run_single_verifier()` (tmux pane lifecycle)
- `src/scripts/run_ralph_desk.zsh:2561-3126` — `main()` (tmux session management + main loop)
- `src/governance.md:184-187` — Checkpoint 2 Release Readiness scope (cross-US integration)
- `src/governance.md:300-374` — Agent mode (§5a) and Tmux mode (§5b) architecture
- `src/commands/rlp-desk.md:296-460` — Agent mode Leader loop (LLM instructions, not shell code)
- `tests/test_engine_refactor.sh:6-14` — `extract_fn()` pattern with `$RUN` hardcoded
- `tests/test_us009_api_retry_guard.sh:4-31` — Same pattern with more complex harness
