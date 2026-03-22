# RLP Desk Self-Verification Methodology

## Overview

RLP Desk uses a structured self-verification system that validates every feature before user testing. This methodology follows the [Claude Agent Skills Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices#workflows-and-feedback-loops) feedback loop pattern: run → validate → fix → repeat.

## Principles

1. **Feedback Loop**: Run test → validate logs → fix errors → repeat until ALL pass
2. **Evaluation-driven**: Tests defined BEFORE claiming completion
3. **Verifiable outputs**: [PLAN]/[EXEC]/[VALIDATE] structured debug logs
4. **Iterative refinement**: observe → fix → re-test ALL (not just the failing one)
5. **No shortcuts**: Either it works or it doesn't ship. No "experimental" labels.
6. **User approval required**: Self-verification passes → report → user tests → user approves → deploy

## Three-Phase Debug Logging

Every test run with `DEBUG=1` produces structured logs:

```bash
grep '\[PLAN\]' debug.log     # What SHOULD happen (expected flow)
grep '\[EXEC\]' debug.log     # What ACTUALLY happened (every decision point)
grep '\[VALIDATE\]' debug.log # Was it CORRECT? (auto-validation)
```

### [PLAN] — Expected Execution Plan
Logged at startup. Captures configuration and expected flow:
```
[PLAN] slug=perus us_count=3 us_list=US-001,US-002,US-003
[PLAN] worker_engine=claude worker_model=sonnet
[PLAN] verify_mode=per-us consensus=0 max_iter=10
[PLAN] expected_flow=worker->verify(US-001)->worker->verify(US-002)->...->verify(ALL)->COMPLETE
```

### [EXEC] — Execution Events
Logged at every decision point during execution:
```
[EXEC] iter=1 phase=worker engine=claude model=sonnet dispatched=true
[EXEC] iter=1 worker_submit_check=OK attempts=1
[EXEC] iter=1 poll_signal_received=true
[EXEC] iter=1 phase=worker_signal status=verify us_id=US-001
[EXEC] iter=1 phase=verifier engine=claude model=opus scope=US-001 dispatched=true
[EXEC] iter=1 phase=verdict engine=claude verdict=pass us_id=US-001 issues=0
[EXEC] iter=1 verified_us_update=US-001 verified_us_total=US-001
```

Consensus-specific:
```
[EXEC] iter=1 phase=consensus_claude verdict=pass model=opus
[EXEC] iter=1 phase=consensus_codex verdict=pass model=gpt-5.4 reasoning=high
[EXEC] iter=1 phase=consensus round=1 claude=pass codex=pass combined_action=pass
```

### [VALIDATE] — Automatic Validation
Logged at cleanup. Compares plan vs execution:
```
[VALIDATE] verify_mode=per-us configured=true
[VALIDATE] per_us_coverage=PASS verified=3/3 us=US-001,US-002,US-003
[VALIDATE] dispatches worker=4 verifier=4
[VALIDATE] fix_loops=0
[VALIDATE] circuit_breakers_triggered=0
[VALIDATE] result=COMPLETE iterations=4 elapsed=760s verified_us=US-001,US-002,US-003
```

## Visible Pane Self-Verification

Self-verification runs in **visible tmux panes** so the user can observe all roles in real-time.

### Pane Layout

```
+------------------+------------------+------------------+
| Session pane     | Leader pane      | Worker pane      |
| Claude Code      | run_ralph_desk   |                  |
| (conversation)   | shell loop logs  +------------------+
| AI reports here  | visible output   | Verifier pane    |
+------------------+------------------+------------------+
```

### How it works:
1. AI creates a **Leader pane** to the right of the session pane via `tmux split-window -h`
2. The `run_ralph_desk.zsh` script runs **in foreground** in the Leader pane (not background)
3. The runner script splits its pane further right into Worker/Verifier panes
4. User can observe all three: Leader loop output, Worker execution, Verifier execution
5. AI monitors `debug.log` from the session pane (left) and reports results
6. After completion, AI reads [PLAN]/[EXEC]/[VALIDATE] from debug.log

### Execution:
```bash
# AI creates Leader pane
LEADER=$(tmux split-window -h -d -P -F '#{pane_id}' -c "$ROOT")

# AI sends run command to Leader pane (foreground, not background)
tmux send-keys -t "$LEADER" "LOOP_NAME=<slug> ROOT=<path> DEBUG=1 [options] zsh ~/.claude/ralph-desk/run_ralph_desk.zsh" Enter

# Runner automatically splits Leader pane → Worker + Verifier
# User watches all panes in real-time
# AI polls debug.log from session pane
```

### Pane safety rules:
- **NEVER** kill the session pane (where Claude Code runs)
- Store session pane ID at start, exclude from all kill operations
- Leader pane is created by AI, cleaned up by AI after each test
- Worker/Verifier panes are created/cleaned by the runner script
- Always verify pane ID before `tmux kill-pane`

## Test Suite

### Core Tests (must ALL pass)

| ID | Feature | Options | Pass Criteria |
|----|---------|---------|---------------|
| A | per-US verify | `--verify-mode per-us` | `per_us_coverage=PASS`, all US verified + final ALL |
| B | batch verify | `--verify-mode batch` | 1 verify, `us_id=ALL`, COMPLETE |
| D | codex worker | `--worker-engine codex` | `engine=codex` in EXEC, COMPLETE |
| E | consensus | `--verify-consensus` | `claude=pass codex=pass`, COMPLETE |
| F | per-role codex | `--worker-codex-reasoning medium` | `worker_codex_reasoning=medium` in status.json |

### Extended Tests (feature-specific)

| ID | Feature | Options | Pass Criteria |
|----|---------|---------|---------------|
| G | consensus-scope final-only | `--consensus-scope final-only` | consensus only on ALL verify |
| H | codex verifier | `--verifier-engine codex` | verifier uses codex |
| I | per-engine verdict JSON | consensus test | `consensus.claude.verdict` in verdict JSON |

## Process

### 1. Setup
```bash
# Create test project in /tmp (never in the rlp-desk repo)
mkdir /tmp/rlp-test-<name> && cd /tmp/rlp-test-<name> && git init
~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>"
# Write PRD + test-spec
```

### 2. Execute (visible pane)
```bash
# AI creates right pane and runs:
LOOP_NAME=<slug> ROOT=/tmp/rlp-test-<name> DEBUG=1 [options] \
  zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
```

### 3. Evaluate
```bash
grep '\[PLAN\]' debug.log     # Expected
grep '\[EXEC\]' debug.log     # Actual
grep '\[VALIDATE\]' debug.log # Correct?
```

### 4. Decision
- ALL VALIDATE = PASS → report to user for manual testing
- ANY VALIDATE = FAIL → fix code → re-run ALL tests from scratch
- Never commit until ALL tests pass AND user approves

## Recovery Patterns

### Instruction Delivery Failure
- Direct `tmux send-keys -l` + Enter (not safe_send_keys)
- Submit check loop: 15 attempts × 2s, checking for activity indicators
- Adaptive retry at attempt 8: C-u clear + re-type instruction
- If all attempts fail: log `worker_submit_check=FAILED`

### Dead Worker/Verifier
- Kill-and-replace pattern (from omc-teams): `kill-pane` + `split-window`
- Never use `respawn-pane`
- Fresh pane gets fresh claude/codex session
- Dead pane ID discarded, new ID tracked

### Permission Prompt Blocking
- Auto-detect "Do you want to" in pane capture
- Auto-approve with Enter
- Detected in: `safe_send_keys`, `wait_for_pane_ready`, `poll_for_signal`

### Timeout with Active Worker
- Check `pane_current_command` — if `node`/`claude`/`codex`, worker is alive
- Re-poll same iteration (don't increment)
- Only count as monitor_failure if process is truly dead (`zsh`)

## Rules

- ALL tests must pass in ONE clean run before reporting to user
- Fix bugs immediately, don't defer to "next iteration"
- Re-run ALL tests after ANY fix, not just the failing one
- Panes must be cleaned up after completion (except during inspection)
- Debug log must have [PLAN], [EXEC], [VALIDATE] for every test
- Current session pane is SACRED — never kill it
- commit/push/merge/publish requires explicit user approval
