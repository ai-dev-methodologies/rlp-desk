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

### Iteration Signal (`<slug>-iter-signal.json`)

Written by the Worker at the end of every iteration. Provides a structured JSON signal for the Leader to detect iteration completion without parsing markdown.

```json
{
  "iteration": 3,
  "status": "continue|verify|blocked",
  "us_id": "US-001",
  "summary": "Completed US-001, other stories remain",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `iteration` | number | Current iteration number |
| `status` | string | One of: `continue`, `verify`, `blocked` |
| `us_id` | string\|null | US being verified: `"US-001"`, `"ALL"` (final full verify), or null (batch mode) |
| `summary` | string | Brief description of what was accomplished |
| `timestamp` | string | ISO 8601 UTC timestamp |

**Status values:**
- `continue` -- Current action done but more work remains. Leader proceeds to next iteration.
- `verify` -- Current US complete (per-US mode) or all work complete (batch mode). Leader dispatches Verifier scoped to `us_id`.
- `blocked` -- Autonomous blocker encountered. Leader writes BLOCKED sentinel.

**Usage by mode:**
- **Tmux mode:** The shell Leader polls for this file's existence after dispatching the Worker. Once it appears, the Leader reads the `status` field via `jq` to decide the next step. This is the primary control-flow mechanism in tmux mode.
- **Agent() mode:** The Leader MAY read this file as a structured alternative to parsing `memory.md`'s Stop Status section. Agent() mode primarily uses memory.md, so iter-signal.json is supplementary.

**Worker obligation:** The Worker MUST write this file at the end of every iteration, regardless of execution mode. This ensures both Agent() and tmux modes can use the same Worker prompt templates.

### Done Claim (`<slug>-done-claim.json`)

Written by the Worker when claiming work is complete. **Must include `execution_steps`** (governance §1f — always-on, not optional):

```json
{
  "us_id": "US-001",
  "claims": ["AC1: add(10,5)=15", "AC2: subtract(10,5)=5"],
  "execution_steps": [
    {"step": "write_test", "ac_id": "AC1", "command": null, "exit_code": null, "summary": "wrote tests/test_add.py"},
    {"step": "verify_red", "ac_id": "AC1", "command": "pytest tests/", "exit_code": 1, "summary": "RED: test fails"},
    {"step": "implement", "ac_id": "AC1", "command": null, "exit_code": null, "summary": "created add()"},
    {"step": "verify_green", "ac_id": "AC1", "command": "pytest tests/", "exit_code": 0, "summary": "GREEN: 3 passed"},
    {"step": "verify_e2e", "ac_id": "AC1", "command": "python -c '...'", "exit_code": 0, "summary": "E2E matches"},
    {"step": "commit", "ac_id": "AC1", "command": "git commit", "exit_code": 0, "summary": "committed abc1234"}
  ]
}
```

`execution_steps` must be a JSON array of objects. Step types from §1f vocabulary: `write_test`, `verify_red`, `implement`, `verify_green`, `refactor`, `verify_e2e`, `commit`, `verify`.

### Verify Verdict (`<slug>-verify-verdict.json`)

Written by the Verifier after independent verification. **Must include `reasoning`** (governance §1f — always-on, not optional).

**Tmux mode polling:** In tmux mode, after dispatching the Verifier, the shell Leader polls for the existence of `verify-verdict.json` (same pattern as `iter-signal.json`). Once it appears, the Leader reads the `verdict` and `recommended_state_transition` fields via `jq` to decide whether to write a COMPLETE sentinel, continue iterating, or write a BLOCKED sentinel.

**Schema:**

```json
{
  "verdict": "pass|fail|request_info",
  "us_id": "US-001",
  "verified_at_utc": "2025-01-15T10:35:00Z",
  "summary": "All criteria verified with fresh evidence",
  "criteria_results": [
    {
      "criterion": "US-001 AC1: calc.py exists",
      "met": true,
      "evidence": "test -f calc.py → exit 0"
    }
  ],
  "reasoning": [
    {"check": "IL-1 Evidence Gate", "decision": "pass", "basis": "ran pytest fresh, exit 0"},
    {"check": "Layer Enforcement", "decision": "pass", "basis": "L1+L3 required and executed"},
    {"check": "Test Sufficiency", "decision": "pass", "basis": "9 tests / 3 AC = 3.0 ratio"},
    {"check": "Anti-Gaming", "decision": "pass", "basis": "no tautological tests, no mocking"},
    {"check": "Worker Process Audit", "decision": "pass", "basis": "verify_red present with exit≠0"}
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
- `pass`: all criteria met — Leader may write COMPLETE sentinel (or add US to `verified_us` in per-US mode)
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
| Persistent diverse failures | 3 consecutive **fail** verdicts on 3 unique acceptance criterion IDs | Upgrade to opus, retry once; still failing → BLOCKED |
| Timeout | Iteration count reaches `max_iter` | Write TIMEOUT status, report to user |

### Stale Context Detection

The Leader computes a hash (or diff) of `context-latest.md` before and after each Worker runs. If the content doesn't change for 3 consecutive iterations, the Worker is stuck and the loop is blocked.

### Error Escalation

```
Same acceptance criterion fails iteration N (sonnet) → retry with opus in iteration N+1
Same acceptance criterion still fails iteration N+1 (opus) → BLOCKED
```

"Same error" is defined as: **the same acceptance criterion ID appears in the `issues` list of two consecutive Verifier `fail` verdicts.** A `request_info` verdict does not break or contribute to this chain — only `fail` verdicts are counted.

### Consecutive Failures Counter

The Leader maintains `consecutive_failures` in `status.json`. This counter:
- Increments by 1 after each Verifier `fail` verdict
- Resets to 0 after any Verifier `pass` verdict
- **Unchanged** by `request_info` verdicts (neither increments nor resets)
- Triggers the 3-consecutive-diverse-failures CB when it reaches 3 and the 3 most recent `fail` verdicts each have a unique criterion ID

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
  "worker_engine": "claude",
  "verifier_engine": "claude",
  "verify_mode": "per-us",
  "verify_consensus": 0,
  "last_result": "continue|verify|pass|fail|blocked",
  "consecutive_failures": 0,
  "verified_us": ["US-001", "US-002"],
  "consensus_round": 0,
  "claude_verdict": "",
  "codex_verdict": "",
  "updated_at_utc": "2025-01-15T10:30:00Z"
}
```

- `consecutive_failures`: number of consecutive Verifier `fail` verdicts since the last `pass`. Reset to 0 on any `pass`. Unchanged by `request_info`. Used by the Circuit Breaker (see above).
- `last_failing_criteria`: (optional) array of criterion IDs from recent `fail` verdicts, used by Leader to detect same-criterion and diverse-failure CB patterns. Leaders may add additional tracking fields as needed.
- `verified_us`: array of US IDs that have individually passed verification (per-US mode only). Empty in batch mode.
- `verify_mode`: `per-us` or `batch`. Controls the verification strategy.
- `verify_consensus`: `0` or `1`. Whether cross-engine consensus verification is enabled.
- `consensus_round`: current consensus round for the active US (resets per US). Only present when `verify_consensus=1`.
- `claude_verdict`: latest claude verifier verdict. Only present when `verify_consensus=1`.
- `codex_verdict`: latest codex verifier verdict. Only present when `verify_consensus=1`.

## Project Plans Files

The `plans/` directory holds documents that define the project's acceptance criteria and verification approach:

| File | Required | Description |
|------|----------|-------------|
| `plans/prd-<slug>.md` | Yes | Product Requirements Document — user stories, acceptance criteria, non-goals |
| `plans/test-spec-<slug>.md` | Yes | Test specification — verification commands, criteria-to-test mapping |
| `plans/quality-spec-<slug>.md` | Optional | Additional quality constraints (coding standards, performance budgets, security requirements). Not generated by `init` — create manually when needed. |

The `quality-spec` file is not generated by `init`. Create it manually when a project requires additional quality constraints beyond the acceptance criteria in the PRD.

## Slash Command Reference

| Command | Arguments | Description |
|---------|-----------|-------------|
| `brainstorm` | `<description>` | Interactive planning before init |
| `init` | `<slug> [objective]` | Create project scaffold |
| `run` | `<slug> [--max-iter N] [--worker-model M] [--verifier-model M] [--mode agent\|tmux] [--worker-engine claude\|codex] [--verifier-engine claude\|codex] [--codex-model MODEL] [--codex-reasoning low\|medium\|high] [--verify-mode per-us\|batch] [--verify-consensus]` | Run the leader loop |
| `status` | `<slug>` | Display current loop status |
| `logs` | `<slug> [N]` | Show iteration logs |
| `clean` | `<slug> [--kill-session]` | Remove runtime artifacts for re-run |

### `--mode` Flag

The `run` command accepts `--mode agent|tmux` (default: `agent`).

- **`--mode agent`** (default): The current Claude Code session acts as the Leader, dispatching Workers and Verifiers via `Agent()`. Synchronous, no tmux required.
- **`--mode tmux`**: Validates the scaffold, checks prerequisites (`tmux`, `jq`), then launches `run_ralph_desk.zsh` as the Leader. The LLM session exits after launching the script. The shell script runs independently in a tmux session.

### Engine Options

The `run` command accepts engine flags to control which CLI executes Worker and Verifier prompts. **Claude is the default engine.**

| Flag | Default | Description |
|------|---------|-------------|
| `--worker-engine claude\|codex` | `claude` | Engine for Worker |
| `--verifier-engine claude\|codex` | `claude` | Engine for Verifier |
| `--codex-model MODEL` | `gpt-5.5` | Model passed to the `codex` CLI (when engine=codex) |
| `--codex-reasoning low\|medium\|high` | `high` | Reasoning effort for the `codex` CLI |

**Claude engine** (default): uses `Agent()` in agent mode, `claude -p` with `--dangerously-skip-permissions` in tmux mode.

**Codex engine** (opt-in): uses `Bash("codex ...")` in agent mode, interactive `codex` TUI in tmux mode. The `codex` binary must be installed separately (`npm install -g @openai/codex`) and is only required when an engine is set to `codex`.

Engine flags are passed to tmux mode via environment variables: `WORKER_ENGINE`, `VERIFIER_ENGINE`, `CODEX_MODEL`, `CODEX_REASONING`.

### Verify Mode Options

The `run` command accepts `--verify-mode` to control the verification strategy. **Per-US is the default.**

| Flag | Default | Description |
|------|---------|-------------|
| `--verify-mode per-us\|batch` | `per-us` | Verification strategy |
| `--verify-consensus` | off | Cross-engine consensus verification |

**Per-US mode** (default): After each user story is completed, the Verifier checks only that story's acceptance criteria. After all stories individually pass, a final full verify checks all AC. The Leader tracks `verified_us` in `status.json`.

**Batch mode**: Legacy behavior. Worker completes all stories, then a single verification checks all AC at once.

**Consensus verification** (`--verify-consensus`): After the primary verifier runs, a second verifier runs with the alternate engine (claude or codex). Both must pass. If either fails, combined issues form a fix contract. Max 3 consensus rounds per US before BLOCKED. Requires both `claude` and `codex` CLIs.

Verify mode flags are passed to tmux mode via environment variables: `VERIFY_MODE`, `VERIFY_CONSENSUS`.

### Iteration Signal (`us_id` field)

When using per-US verification, the Worker includes a `us_id` field in `iter-signal.json`:

```json
{
  "iteration": 3,
  "status": "verify",
  "us_id": "US-001",
  "summary": "Completed US-001",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

| Value | Meaning |
|-------|---------|
| `"US-001"` (specific) | Verify only this story's AC |
| `"ALL"` | Final full verify — check all AC |
| absent/null | Legacy batch mode — check all AC |

The Verifier's verdict JSON also includes a `us_id` field to confirm which scope was verified.

### Consensus Verdict Fields

When `--verify-consensus` is enabled, `status.json` includes additional fields:

```json
{
  "consensus_round": 1,
  "claude_verdict": "pass",
  "codex_verdict": "pass"
}
```

Individual engine verdicts are saved as `verify-verdict-claude.json` and `verify-verdict-codex.json` in the logs directory.

### `--kill-session` Flag

The `clean` command accepts `--kill-session` to kill any tmux sessions matching the slug pattern (`rlp-desk-<slug>-*`) in addition to removing runtime files.

## Tmux Mode Specifics

This section documents the tmux-specific patterns used by `run_ralph_desk.zsh`. These apply only when running with `--mode tmux`.

### Write-Then-Notify

The single most important pattern. **Never** send data (prompts, large strings) through `tmux send-keys` directly.

1. Write the prompt to a file: `logs/<slug>/iter-NNN.worker-prompt.md`
2. Write a trigger script to a file: `logs/<slug>/iter-NNN.worker-trigger.sh`
3. Send only a short command via `send-keys`: `bash /path/to/trigger.sh`

The trigger script reads the prompt file and invokes `claude -p "$(cat /path/to/prompt.md)" --model <model> --dangerously-skip-permissions`.

### Signal File Polling

In tmux mode, the shell Leader cannot call `Agent()` synchronously. Instead, it polls for signal files:

| Signal | Written By | Polled By Leader | Purpose |
|--------|-----------|------------------|---------|
| `<slug>-iter-signal.json` | Worker | After dispatching Worker | Detect Worker iteration completion |
| `<slug>-verify-verdict.json` | Verifier | After dispatching Verifier | Detect Verifier completion |

The Leader reads these files with `jq` to extract status/verdict fields for control-flow decisions.

### Heartbeat Monitoring

Each trigger script writes a heartbeat file (`worker-heartbeat.json` or `verifier-heartbeat.json`) in a background loop. The Leader periodically checks the heartbeat's timestamp to detect stale processes (no update within `HEARTBEAT_STALE_THRESHOLD` seconds).

### Idle Pane Nudging

If a pane produces no output for `IDLE_NUDGE_THRESHOLD` seconds, the Leader sends a nudge (an Enter keystroke) to prompt activity. After `MAX_NUDGES` attempts without progress, the Leader treats the pane as stuck.

### Exponential Backoff Restarts

If a Worker or Verifier process crashes, the Leader restarts it with exponential backoff: 5s, 10s, 20s, 60s. After `MAX_RESTARTS` consecutive failures, the Leader writes a BLOCKED sentinel.

### Per-Iteration Timeout

Each iteration has a configurable timeout (`ITER_TIMEOUT`, default 600s). If a Worker does not produce an `iter-signal.json` within this period, the Leader kills the process and records the timeout.

### Static Model Routing

Unlike Agent() mode where the LLM Leader dynamically selects models, tmux mode uses static model routing via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKER_MODEL` | `sonnet` | Model for Worker invocations |
| `VERIFIER_MODEL` | `opus` | Model for Verifier invocations |

### Session Config

Session metadata is stored in `logs/<slug>/session-config.json`:

```json
{
  "session_name": "rlp-desk-<slug>-20260318-143000",
  "leader_pane": "%0",
  "worker_pane": "%1",
  "verifier_pane": "%2",
  "created_at": "2026-03-18T14:30:00Z"
}
```

This file is used by the `status` and `clean` commands to find and interact with the running tmux session.

## Blocked Sentinel JSON Schema (P1-D, governance §1f)

When a campaign hits BLOCKED, the leader writes BOTH a markdown sentinel
(`memos/<slug>-blocked.md`) and a JSON sidecar
(`memos/<slug>-blocked.json`) so wrappers can `jq .reason_category` instead
of regex'ing free text.

### JSON sidecar schema

```json
{
  "schema_version": "2.0",
  "slug": "<slug>",
  "us_id": "<us_id or ALL>",
  "blocked_at_iter": 4,
  "blocked_at_utc": "2026-04-25T12:34:56Z",
  "reason_category": "metric_failure | cross_us_dep | context_limit | infra_failure | repeat_axis | mission_abort",
  "reason_detail": "<full reason text>",
  "failure_category": "spec | implementation | integration | flaky | null",
  "recoverable": true,
  "suggested_action": "next_mission_chain | restart | retry_after_fix | terminal_alert"
}
```

### Wrapper contract (binding)

- **`reason_category` is PRIMARY** — wrappers MUST branch on this field for
  recovery decisions.
- **`failure_category` is SECONDARY, diagnostic only** — do NOT branch on
  it; logging/triage only.

### Category → recovery action defaults

| reason_category | recoverable | suggested_action      | meaning                                |
|-----------------|-------------|-----------------------|----------------------------------------|
| metric_failure  | true        | retry_after_fix       | AC missed; fix PRD/code, retry         |
| cross_us_dep    | true        | retry_after_fix       | AC depends on a future US              |
| infra_failure   | true        | restart               | CLI/network/spawn issue                |
| context_limit   | false       | next_mission_chain    | mission stale; chain next axis         |
| repeat_axis     | false       | next_mission_chain    | model ceiling reached on this axis     |
| mission_abort   | false       | terminal_alert        | flywheel guard exhausted               |

### Cross-US token list

A `verifier-blocked` outcome is classified as `cross_us_dep` when its
`reason_detail` matches ANY of:

- English: `depends on US-`, `blocking US-`, `awaits US-`, `post-iter US-`,
  `requires US-N`, `cross-US`
- Korean: `US-N 산출물`, `신규 US-`, `post-iter`

Otherwise it is `metric_failure`.

### Write Order Contract (atomicity invariant)

1. JSON sidecar is written FIRST (`fs.writeFile` / `atomic_write`).
2. Markdown sentinel is written SECOND.
3. **Invariant**: `markdown exists ⇒ JSON exists` (writer enforces order).
4. Wrappers SHOULD watch the markdown sentinel, then read the JSON sidecar.
   If JSON is not yet visible (rare race window), retry up to 5 × 50ms
   before failing the read.

`atomic_write` (zsh) and `fs.writeFile` (Node) provide per-file rename
atomicity; cross-file ordering is enforced by the explicit two-call
sequence in both implementations
(`src/scripts/lib_ralph_desk.zsh` `write_blocked_sentinel`,
`src/node/runner/campaign-main-loop.mjs` `writeSentinel`).

### `next_mission_candidate` (flywheel signal, P0-A)

The flywheel signal JSON (`memos/<slug>-flywheel-signal.json`) MAY include
an optional `next_mission_candidate` field:

- `null` (default) — no specific next mission suggested.
- `"<slug>"` — flywheel recommends the consumer wrapper chain this slug
  next.

The leader propagates the field into `status.json`
(`status.next_mission_candidate`). Wrappers poll either source. See
`docs/multi-mission-orchestration.md` for the consumer-side polling
pattern.
