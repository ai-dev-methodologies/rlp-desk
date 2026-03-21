# RLP Desk Self-Verification Methodology

## Principles (from Claude Agent Skills Best Practices)

1. **Feedback Loop**: Run test → validate → fix → repeat until all pass
2. **Evaluation-driven**: Create evaluations BEFORE claiming completion
3. **Verifiable outputs**: [PLAN]/[EXEC]/[VALIDATE] structured logs
4. **Iterative refinement**: observe → fix → re-test, never skip

## Process

### 1. Setup
- Create test projects in `/tmp/rlp-test-<name>/`
- Write PRD + test-spec for each test case
- Run with `DEBUG=1` for structured logging

### 2. Execute
- Launch test via tmux mode
- Wait for completion (poll status.json)
- Read debug.log

### 3. Evaluate
```bash
grep '\[PLAN\]' debug.log     # What should happen
grep '\[EXEC\]' debug.log     # What happened
grep '\[VALIDATE\]' debug.log # Was it correct?
```

### 4. Decision
- All VALIDATE = PASS → proceed to next test
- Any VALIDATE = FAIL → fix code → re-run ALL tests from scratch
- Never commit until ALL tests pass in ONE clean run

## Test Suite

| ID | Test | Options | Pass Criteria |
|----|------|---------|---------------|
| A | per-US verify (3 US) | `--verify-mode per-us` | verified_us=3/3, COMPLETE |
| B | batch verify | `--verify-mode batch` | 1 verify, us_id=ALL, COMPLETE |
| D | codex worker | `--worker-engine codex` | engine=codex in EXEC, COMPLETE |
| E | consensus | `--verify-consensus` | claude=pass, codex=pass, COMPLETE |

## Rules
- ALL 4 tests must pass in one clean run before committing
- No "experimental" labels — either it works or it doesn't ship
- Fix bugs immediately, don't defer
- Re-run ALL tests after ANY fix, not just the failing one
- Panes must be cleaned up after completion
- Debug log must have [PLAN], [EXEC], [VALIDATE] for every test
