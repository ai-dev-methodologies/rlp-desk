# Protocol Reference

Complete specification of the RLP Desk leader loop protocol, signal contracts, circuit breakers, and model routing.

## Leader Loop Protocol

```
for iteration in 1..max_iter:

  ① Check sentinels
     - <slug>-complete.md exists → stop (success)
     - <slug>-blocked.md exists → stop (failure)

  ①½ Prep-stage cleanup (before each iteration)
     - Delete <slug>-done-claim.json if exists  [leader-measured]
     - Delete <slug>-verify-verdict.json if exists  [leader-measured]
     (Ensures stale runtime files from a previous run cannot mislead the loop)

  ② Read memory.md
     - Parse "Stop Status" section → continue/verify/blocked
     - Parse "Next Iteration Contract" → task for this iteration
       • Also read "Completed Stories" → track what has been verified
       • Also read "Key Decisions" → architectural choices already settled

  ③ Select model
     - Apply model routing rules (see below)
     - Check circuit breaker conditions

  ④ Build Worker prompt
     - Read base prompt from prompts/<slug>.worker.prompt.md
     - Append iteration number + contract from memory
     - Write audit copy to logs/<slug>/iter-NNN.worker-prompt.md

  ⑤ Execute Worker
     Agent(subagent_type="executor", model=selected, prompt=prompt)
     - Synchronous return — wait for completion
     - Each Agent() = fresh context (new subprocess)

  ⑥ Read memory.md again (Worker updated it)
     - stop=continue → go to ⑧
     - stop=verify   → go to ⑦
     - stop=blocked  → write BLOCKED sentinel, stop

  ⑦ Execute Verifier
     - Build verifier prompt → write to logs/<slug>/iter-NNN.verifier-prompt.md
     - Agent(subagent_type="executor", model=selected, prompt=prompt)
     - Read verify-verdict.json:
       • verdict=pass + recommended=complete → write COMPLETE sentinel, stop
       • verdict=fail + recommended=continue → go to ⑧
       • verdict=blocked → write BLOCKED sentinel, stop

  ⑧ Write iter-NNN.result.md (see Result Log below)
     Update status.json, report to user, next iteration
```

## Signal Contracts

### Campaign Memory (`<slug>-memory.md`)

Written by the Worker at the end of each iteration. Must contain:

```markdown
# <slug> - Campaign Memory

## Stop Status
continue | verify | blocked

## Objective
<original objective>

## Current State
Iteration N - <description>

## Completed Stories
- US-001: Calculator add/subtract implemented [interface: `add(a, b) -> float`]
- US-002: pytest suite — 8 tests passing

## Next Iteration Contract
**Story**: US-003 — Edge case handling
**Task**: Handle divide-by-zero in calc.py.
1. Raise ValueError with message "division by zero"
2. Add test_divide_by_zero to test_calc.py

**Criteria**:
- `pytest` exits 0
- `grep "ValueError" calc.py` matches

## Key Decisions
- Iteration 2: Chose ValueError over ZeroDivisionError — matches project error style.
- Iteration 3: Skipped type hints — out of scope per PRD Non-Goals.

## Patterns Discovered
## Learnings
## Evidence Chain
```

The Leader reads:
- **Stop Status** and **Next Iteration Contract** to decide what happens next.
- **Completed Stories** to track verified work without re-reading full history.
- **Key Decisions** to carry forward settled architectural choices.

All sections use plain Markdown. No YAML.

### Done Claim (`<slug>-done-claim.json`)

Written by the Worker when claiming all work is complete:

```json
{
  "iteration": 3,
  "claimed_at_utc": "2025-01-15T10:30:00Z",
  "summary": "All user stories implemented and tests passing",
  "stories_completed": ["US-001", "US-002"],
  "evidence": {
    "test_output": "8 passed in 0.05s",
    "files_created": ["calc.py", "test_calc.py"]
  }
}
```

### Verify Verdict (`<slug>-verify-verdict.json`)

Written by the Verifier after independent verification:

```json
{
  "verdict": "pass|fail|request_info",
  "verified_at_utc": "2025-01-15T10:35:00Z",
  "summary": "All criteria verified with fresh evidence",
  "criteria_results": [
    {
      "criterion": "US-001 AC1: calc.py exists",
      "met": true,
      "evidence": "test -f calc.py → exit 0"
    }
  ],
  "missing_evidence": [],
  "issues": [
    {
      "criterion": "US-002 AC1",
      "description": "Test file missing",
      "severity": "critical|major|minor",
      "fix_hint": "(suggestion, non-authoritative) Add test_calc.py"
    }
  ],
  "recommended_state_transition": "complete|continue|blocked",
  "next_iteration_contract": "Fix failing test for divide by zero",
  "evidence_paths": ["test_calc.py::test_divide_by_zero"]
}
```

**Verdict values:**
- `pass`: all criteria met — Leader may write COMPLETE sentinel
- `fail`: one or more criteria not met — Leader reads issues, builds next contract
- `request_info`: Verifier cannot determine pass/fail without more information — summary contains specific questions; Leader decides outcome and may relay questions to Worker

**Issues severity:**
- `critical`: blocking — must be fixed before COMPLETE
- `major`: significant gap in acceptance criteria
- `minor`: cosmetic or non-blocking concern

**Verifier scope:**
- Identify changed files via `git diff --name-only` — read those files and their direct imports only
- Campaign Memory (`<slug>-memory.md`) is for orientation only — not the source of truth for verification
- Delegate deterministic checks (type hints, linting, security) to tools defined in test-spec
- Focus on: AC verification, semantic review, smoke tests
- Do NOT use `fail` when uncertain — use `request_info` with specific questions instead

### Fix Loop Protocol

When the Verifier returns `fail`, the Leader executes the Fix Loop before dispatching the next Worker:

#### Flow

```
Verifier fail
  → Leader reads verify-verdict.json issues
  → Sort issues by severity: critical → major → minor
  → Build structured fix contract (see format below)
  → Increment consecutive_failures in status.json
  → Dispatch Worker with fix contract as Next Iteration Contract
```

#### Fix Contract Format

```markdown
## Next Iteration Contract
**Mode**: fix
**Verifier verdict reference**: iter-NNN

**Issues to fix** (severity-sorted):
1. [critical] US-002 AC3: <description>
   - fix_hint: (suggestion, non-authoritative) <hint text>
2. [major] US-001 AC1: <description>
3. [minor] US-003 AC2: <description>

**Traceability rule**: Only changes that resolve a listed issue are allowed (traceability enforcement).
Every change must be justified by the issue it addresses.
```

#### Rules

- `fix_hint` is optional. When present it is labeled `(suggestion, non-authoritative)` — the Worker may choose a different approach.
- **traceability**: the Worker must not introduce changes beyond what is needed to resolve the listed issues.
- The Leader increments `consecutive_failures` in `status.json` after each `fail` verdict, and resets it to 0 after any `pass`.
- The Leader (not the Worker) owns the `consecutive_failures` counter.

### Sentinels

Leader-only files that terminate the loop:

| File | Meaning | Written When |
|------|---------|--------------|
| `<slug>-complete.md` | Loop succeeded | Verifier passes all criteria |
| `<slug>-blocked.md` | Loop cannot continue | Autonomous blocker or circuit breaker |

**Only the Leader writes sentinels.** Workers and Verifiers never touch them.

## Context File (`<slug>-latest.md`)

Updated by the Worker each iteration to reflect the current frontier:

```markdown
# <slug> - Latest Context

## Current Frontier
### Completed
- US-001: calculator functions implemented
### In Progress
- US-002: pytest tests
### Next
- Run verification

## Key Decisions
- Using ValueError for divide-by-zero (not ZeroDivisionError)

## Known Issues
## Files Changed This Iteration
- calc.py (created)
## Verification Status
- python3 -m pytest → not yet run
```

## Circuit Breakers

| Condition | Detection | Action |
|-----------|-----------|--------|
| Stale context | `context-latest.md` hash unchanged for 3 consecutive iterations | Write BLOCKED sentinel |
| Repeated criterion failure | Same acceptance criterion fails in 2 consecutive Verifier verdicts | Upgrade model, retry once; still failing → BLOCKED |
| Persistent diverse failures | 3 consecutive failures on different acceptance criteria | Upgrade to opus, retry once; still failing → BLOCKED |
| Timeout | Iteration count reaches `max_iter` | Write TIMEOUT status, report to user |

### Stale Context Detection

The Leader computes a hash (or diff) of `context-latest.md` before and after each Worker runs. If the content doesn't change for 3 consecutive iterations, the Worker is stuck and the loop is blocked.

### Error Escalation

```
Same acceptance criterion fails iteration N (sonnet) → retry with opus in iteration N+1
Same acceptance criterion still fails iteration N+1 (opus) → BLOCKED
```

"Same error" is defined as: **the same acceptance criterion ID appears in the `issues` list of two consecutive Verifier verdicts.**

### Consecutive Failures Counter

The Leader maintains `consecutive_failures` in `status.json`. This counter:
- Increments by 1 after each Verifier `fail` verdict
- Resets to 0 after any Verifier `pass` verdict
- Triggers the 3-consecutive-different-errors CB when it reaches 3 and the failing criteria differ each time

## Model Routing

### Selection Matrix

| Scenario | Model | Rationale |
|----------|-------|-----------|
| Single file, clear change | `haiku` | Fast, sufficient |
| Standard implementation | `sonnet` | Balanced (default) |
| Multi-file, architecture | `opus` | Needs broad understanding |
| Previous iteration failed | upgrade | Harder model may succeed |
| Verification (default) | `opus` | Independent verification requires thoroughness |
| Verification (lightweight) | `sonnet` | Simple, well-defined checks only |

### Dynamic Adaptation

The Leader reassesses the model every iteration:

1. Read memory for previous iteration outcome
2. If failed → upgrade one level (haiku → sonnet → opus)
3. If simple/repetitive → consider downgrade
4. User override via `--worker-model` / `--verifier-model` takes precedence

## Result Log (`iter-NNN.result.md`)

Written by the Leader after each iteration completes (step ⑧). Stored in `logs/<slug>/`.

```markdown
# Iteration NNN Result

## Result Status
pass | fail | continue  [leader-measured]

## Files Changed
(output of `git diff --stat HEAD~1 HEAD`)  [git-measured]

## Summary
<1–2 sentence summary of what the Worker did this iteration>

## Verifier Verdict
pass | fail | blocked | (not run)  [leader-measured]
```

- `[leader-measured]`: value determined by the Leader reading memory/verdict files.
- `[git-measured]`: value determined by running `git diff --stat` — not from Worker's claim.

## Status File (`status.json`)

Updated by the Leader after each iteration:

```json
{
  "slug": "loop-test",
  "iteration": 2,
  "max_iter": 100,
  "phase": "worker|verifier|complete|blocked|timeout",
  "worker_model": "sonnet",
  "verifier_model": "opus",
  "last_result": "continue|verify|pass|fail|blocked",
  "consecutive_failures": 0,
  "updated_at_utc": "2025-01-15T10:30:00Z"
}
```

- `consecutive_failures`: number of consecutive Verifier `fail` verdicts since the last `pass`. Reset to 0 on any `pass`. Used by the Circuit Breaker (see above).

## Slash Command Reference

| Command | Arguments | Description |
|---------|-----------|-------------|
| `brainstorm` | `<description>` | Interactive planning before init |
| `init` | `<slug> [objective]` | Create project scaffold |
| `run` | `<slug> [--max-iter N] [--worker-model M] [--verifier-model M]` | Run the leader loop |
| `status` | `<slug>` | Display current loop status |
| `logs` | `<slug> [N]` | Show iteration logs |
| `clean` | `<slug>` | Remove runtime artifacts for re-run |
