# RLP Desk Development & Verification Log

## Feature Status

| # | Feature | Status | Notes |
|---|---------|--------|-------|
| 1 | Codex engine support | ✅ Implemented | Worker/Verifier can use codex CLI |
| 2 | Per-US verification | ✅ Working | Leader-driven US sequencing, 3/3 verified + final ALL |
| 3 | Consensus verification | ✅ Implemented | Not yet tested end-to-end |
| 4 | Structured debug logging | ✅ Working | [PLAN]/[EXEC]/[VALIDATE] system |
| 5 | Instruction delivery fix | ✅ Working | Direct send-keys + submit check loop |
| 6 | Batch mode isolation | ✅ Fixed | BATCH MODE OVERRIDE injected, Worker signals us_id=ALL |
| 7 | Duplicate execution | ✅ Fixed | Atomic lockfile (set -C noclobber) prevents 2nd instance |
| 8 | Codex worker | ✅ Working | codex TUI launches, gpt-5.5 high, instruction delivered, Worker completes |
| 9 | Codex→Claude verify | ✅ Working | codex Worker → claude Verifier → pass → COMPLETE |
| 10 | Consensus verify | ⚠️ Partial | claude verifier works, codex verifier instruction delivery fails in same pane |
| 11 | timeout_active bug | ❌ Bug | timeout+active causes new iteration instead of continuing same poll |
| 12 | Permission prompt | ⚠️ Known | Claude --dangerously-skip-permissions sometimes still asks for file overwrite |

## Test Results

### Test A: per-US verify (attempt 1) — FAIL
- **Date**: 2026-03-21
- **Config**: verify_mode=per-us, worker=sonnet, verifier=opus
- **Expected**: worker→verify(US-001)→worker→verify(US-002)→worker→verify(US-003)→verify(ALL)→COMPLETE
- **Actual**: Worker did all 3 US in 1 iteration, signaled us_id=ALL, Verifier passed, COMPLETE
- **VALIDATE output**: `per_us_coverage=FAIL verified=0`
- **Root cause**: Worker prompt template doesn't enforce per-US signaling. Worker sees all US in PRD and does everything.
- **Decision**: Strengthen worker prompt template — when verify_mode=per-us, inject explicit per-US scope lock in the iteration contract. Leader must tell Worker which specific US to work on, not let Worker decide.

## Decisions Made

| # | Decision | Reason |
|---|----------|--------|
| 1 | Worker prompt must include explicit US assignment per iteration | Worker ignores "one at a time" when it can see all US in PRD |
| 2 | Leader must track which US is next and inject it into contract | Per-US mode requires Leader-driven US sequencing, not Worker-driven |
| 3 | Fix in run_ralph_desk.zsh write_worker_trigger() | Leader builds contract with specific US assignment based on VERIFIED_US tracking |
| 4 | Duplicate script execution bug needs investigation | EXEC logs show two runs — likely Bash backgrounding issue |
