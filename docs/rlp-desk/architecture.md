# Architecture

## Design Philosophy

RLP Desk is built on a single conviction: **context is a liability, not an asset**.

In long-running LLM sessions, accumulated context causes drift, hallucination, and forgotten decisions. RLP Desk eliminates this by treating each iteration as a fresh start, with the filesystem as the sole source of truth.

### Why Fresh Context Matters

Traditional approaches:
```
Session start → Task 1 → Task 2 → ... → Task N
                  ↑ context accumulates, quality degrades
```

RLP Desk approach:
```
Leader ──Agent()──▶ Worker 1 (fresh) ──▶ writes to filesystem
       ──Agent()──▶ Worker 2 (fresh) ──▶ reads filesystem, continues
       ──Agent()──▶ Worker 3 (fresh) ──▶ reads filesystem, continues
```

Each worker reads the same filesystem state that any human could inspect. No hidden context. No accumulated confusion.

## The Agent() Approach

Claude Code's `Agent()` tool spawns a subprocess — a completely new context window with no knowledge of the parent conversation. RLP Desk exploits this property:

```python
# Each call = new process = fresh context = no prior conversation
Agent(
    subagent_type="executor",   # Worker or Verifier
    model="sonnet",             # Model selection per iteration
    prompt=full_prompt_text,    # Everything the agent needs
    mode="bypassPermissions"    # Autonomous execution
)
```

The Agent returns synchronously. No polling, no signal files, no tmux. The Leader simply reads the filesystem after each Agent completes.

### Two Execution Modes

RLP Desk supports two modes for running the Leader loop. Both honor the same governance protocol (section 7). Choose based on your use case.

| Mode | Leader | Model Routing | Session Required | Best For |
|------|--------|---------------|------------------|----------|
| **Agent() — "Smart mode"** (default) | LLM (current session) | Dynamic — Leader reasons about which model to use each iteration | Active Claude Code session | Interactive development, complex routing decisions |
| **Tmux — "Lean mode"** | Shell script (`run_ralph_desk.zsh`) | Static — set via `WORKER_MODEL`/`VERIFIER_MODEL` env vars | None (runs detached) | Long campaigns, CI, observability, zero-token orchestration |

### Verification Policy Layer

Both modes enforce the same verification policy (governance §1a-§1f):

```
                    ┌─────────────────────────────────┐
                    │     Governance (§1a-§1f)         │
                    │  Iron Laws · Evidence Gate       │
                    │  Risk Classification · Layers    │
                    │  Checkpoints · Traceability      │
                    └──────────┬──────────────────────┘
                               │ enforced by
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
         Worker Template  Verifier Template  Leader Loop
         (Test-First,     (12-step process,  (Contract review,
          12 Shortcuts,    5 reasoning       Checkpoints,
          execution_steps) categories)       Escalation)
```

Key design decisions:
- **execution_steps** (Worker) and **reasoning** (Verifier) are always-on (§1f), not gated by flags
- **`--with-self-verification`** adds post-campaign analysis only — does not change loop behavior
- **Risk-proportional layers**: LOW gets L1+L3, CRITICAL gets L1+L2+L3+L4+mutation

**Agent() mode** is synchronous and simple: each `Agent()` call blocks until the subprocess finishes, then the Leader reads the filesystem. No polling, no signal files, no tmux.

**Tmux mode** trades dynamic routing for visibility and independence. The shell Leader writes prompts to files, sends short trigger commands via `tmux send-keys`, and polls structured JSON signal files (`iter-signal.json`, `verify-verdict.json`) for control flow. It uses proven tmux patterns — write-then-notify, pane ID stability, copy-mode guards, heartbeat monitoring — for reliable, race-free orchestration.

The tmux script is a second implementation of the governance protocol. Traceability is maintained via governance.md section 7 step-number comments throughout the script.

#### Tmux Architecture

```
[tmux session: rlp-desk-<slug>-<timestamp>]
+-------------------------------------+
| Leader pane (shell loop)            |
| - writes prompts to files           |
| - sends short triggers via send-keys|
| - polls iter-signal.json via jq     |
| - monitors heartbeat files          |
| - writes sentinels                  |
+------------------+------------------+
| Worker pane      | Verifier pane    |
| bash trigger.sh  | bash trigger.sh  |
| -> claude -p ... | -> claude -p ... |
| heartbeat writer | heartbeat writer |
| (fresh context)  | (fresh context)  |
+------------------+------------------+
```

## Three-Role Architecture

### Leader (Your Session)

The Leader is the currently running Claude Code session. It:

- Reads campaign memory to understand current state
- Decides which model to use for the next iteration
- Builds prompts by combining base prompts with iteration-specific context
- Dispatches Workers and Verifiers via `Agent()`
- Writes sentinel files (COMPLETE/BLOCKED) based on results
- Tracks circuit breaker conditions

The Leader **never writes code**. It orchestrates.

### Worker (Fresh Context)

Each Worker:

- Receives a complete prompt with everything it needs (PRD, memory, context, task)
- Executes exactly **one bounded action** (e.g., implement one user story)
- Updates the filesystem:
  - `context/<slug>-latest.md` — current frontier
  - `memos/<slug>-memory.md` — campaign memory for the next worker
  - `memos/<slug>-done-claim.json` — if claiming all work is complete
- Exits

The Worker has no memory of previous iterations. It relies entirely on what prior Workers wrote to the filesystem.

### Verifier (Fresh Context)

The Verifier exists because **Worker claims are not trustworthy**. A Worker may claim "all tests pass" without actually running them.

Each Verifier:

- Reads the PRD, test spec, and the Worker's done-claim
- Runs verification commands **from scratch** (build, test, lint)
- Checks each acceptance criterion against fresh evidence
- Writes a verdict: pass, fail, or blocked
- **Never modifies code**

## Filesystem as Memory

```
.claude/ralph-desk/
├── plans/          # Contracts (PRD, test spec) — written once, rarely modified
├── prompts/        # Base prompts — templates for Worker/Verifier
├── context/        # Current frontier — Worker updates each iteration
├── memos/          # Runtime state — memory, claims, verdicts, sentinels
└── logs/           # Audit trail — every prompt sent, every status change
```

### State Lifecycle

```
plans/prd-*.md          Written at init, stable reference
plans/test-spec-*.md    Written at init, stable reference
context/*-latest.md     Updated by Worker each iteration
memos/*-memory.md       Rewritten by Worker each iteration
memos/*-done-claim.json Created by Worker, cleaned by Leader
memos/*-verify-verdict  Created by Verifier, cleaned by Leader
memos/*-complete.md     Written once by Leader (terminal)
memos/*-blocked.md      Written once by Leader (terminal)
```

## Model Routing Strategy

Not every task needs the most powerful model. RLP Desk routes based on complexity:

```
Simple fix (typo, config)  →  haiku   (fast, cheap)
Standard implementation    →  sonnet  (balanced)
Architecture / debugging   →  opus    (thorough)
```

The Leader adapts dynamically:
- Previous iteration failed → upgrade model
- Simple repetitive task → downgrade model
- User explicitly specified → respect the choice
