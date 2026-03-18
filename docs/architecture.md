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

### Why Agent() Over Other Approaches

| Approach | Problem |
|----------|---------|
| Single long session | Context drift, token limits |
| tmux + polling | Complex, brittle, race conditions |
| Signal files + sleep loops | Fragile timing, wasted compute |
| **Agent() subprocess** | **Clean, synchronous, guaranteed fresh context** |

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
