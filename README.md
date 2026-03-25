# RLP Desk

> Fresh-context iterative loops for Claude Code — autonomous task completion with independent verification.

RLP Desk brings [Geoffrey Huntley's Ralph Loop](https://ghuntley.com/ralph/) philosophy to Claude Code. Inspired by [OpenAI Codex's long-horizon tasks](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex/) and [design-desk](https://github.com/derrickchoi-openai/design-desk), it orchestrates fresh-context workers and verifiers through Claude Code's `Agent()` tool.

**Key insight**: Each iteration starts fresh. No accumulated context drift. The filesystem is the only memory.

```
[Your Session = LEADER]
        │
  Agent()├──▶ [Worker (fresh context)]
        │     └── reads PRD + memory → implements → updates memory
        │
  Agent()└──▶ [Verifier (fresh context)]
              └── reads done-claim → runs checks → writes verdict
```

## Quick Start

### 1. Install

```bash
npm install -g @ai-dev-methodologies/rlp-desk
```

Or without npm:

```bash
curl -sSL https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main/install.sh | bash
```

### 2. Brainstorm (recommended)

**Always start with brainstorm.** It interactively walks you through the project contract:

```
/rlp-desk brainstorm "implement a Python calculator with tests"
```

You'll be asked to confirm each item:
- **Slug** — project identifier
- **User Stories** — discrete, testable units with Given/When/Then acceptance criteria
- **Task Type & Risk Level** — code/visual/content/integration/infra × LOW/MEDIUM/HIGH/CRITICAL
- **Iteration Unit** — one story per iteration (incremental) or all at once (fast)
- **Verification Commands** — how to check the work
- **Ambiguity Gate** — AC quality scoring (IL-2, 0-12 scale, blocks init if < 6)
- **Models** — which Claude model for Worker/Verifier

### 3. Run

```
/rlp-desk run calculator
```

The leader loop runs autonomously — spawning workers, verifying results, and tracking progress until completion or a circuit breaker triggers.

## Why?

### The Context Problem

LLM conversations accumulate context. Long sessions drift, hallucinate, and forget earlier decisions. The Ralph Loop solves this by treating **context as a disposable resource**:

- Each worker gets a **fresh context** — no prior conversation, no accumulated confusion
- **Filesystem = memory** — PRDs, campaign memory, and context files are the only state
- **Independent verification** — a separate fresh-context verifier checks the worker's claims against real evidence

### Lineage

| Concept | Source |
|---------|--------|
| Fresh context per iteration | [Ralph Loop](https://ghuntley.com/ralph/) ([guide](https://www.aihero.dev/getting-started-with-ralph), [tips](https://www.aihero.dev/tips-for-ai-coding-with-ralph-wiggum)) |
| Long-horizon autonomous tasks | [OpenAI Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex/) |
| Desk-based orchestration | [design-desk](https://github.com/derrickchoi-openai/design-desk) |
| Agent() subprocess model | Claude Code native |

## How It Works

### Three Roles

| Role | Runs In | Responsibility |
|------|---------|----------------|
| **Leader** | Your current session | Orchestrates the loop, reads memory, selects models, writes sentinels |
| **Worker** | Fresh `Agent()` context | Executes one bounded action per iteration, updates memory |
| **Verifier** | Fresh `Agent()` context | Independently verifies worker claims with fresh evidence |

### The Loop

```
for iteration in 1..max_iter:

  1. Check sentinels (complete? blocked?)
  2. Read campaign memory → get next iteration contract
  3. Select model (haiku/sonnet/opus based on complexity)
  4. Build worker prompt → dispatch via Agent()
  5. Worker executes one bounded action, updates memory
  6. If worker claims done → dispatch Verifier via Agent()
  7. Verifier runs fresh checks → pass/fail/blocked
  8. Update status, report to user, continue or stop
```

### Verification Policy (v0.3.0)

RLP Desk enforces a comprehensive verification policy defined in `governance.md`:

**Iron Laws (§1a)** — 4 absolute rules that cannot be violated:
- **IL-1**: No completion claims without fresh verification evidence
- **IL-2**: No init without AC quality score ≥ 6 (Ambiguity Gate)
- **IL-3**: No pass with TODO in any required verification layer
- **IL-4**: No pass without test count ≥ AC count × 3

**Evidence Gate (§1b)** — 5-step protocol: IDENTIFY → RUN → READ → VERIFY → ONLY THEN claim

**Risk Classification (§1c)** — Proportional verification layers per risk level:

| Risk | Required Layers |
|------|----------------|
| LOW | L1 (Unit) + L3 (E2E) |
| MEDIUM | L1 + L2 (Integration) + L3 |
| HIGH | L1 + L2 + L3 + L4 (Deploy) |
| CRITICAL | L1 + L2 + L3 + L4 + mutation testing |

**Execution Traceability (§1f)** — Always-on, not flag-gated:
- Worker records `execution_steps` in done-claim.json (what was done, in what order, with evidence)
- Verifier records `reasoning` in verify-verdict.json (why each judgment was made)

### Circuit Breakers

| Condition | Action |
|-----------|--------|
| Context unchanged for 3 iterations | BLOCKED |
| Same error repeated twice | Upgrade model, retry once, then BLOCKED |
| 3 consecutive failures | Architecture Escalation (§7¾) → report to user |
| Max iterations reached | TIMEOUT |

### Model Routing

| Scenario | Model |
|----------|-------|
| Simple, single-file changes | `haiku` |
| Standard work (default) | `sonnet` |
| Architecture changes, multi-file, prior failure | `opus` |
| Verification (default) | `opus` |
| Lightweight verification | `sonnet` |

## Commands

```
/rlp-desk brainstorm <description>     Plan before init (interactive)
/rlp-desk init  <slug> [objective]     Create project scaffold
/rlp-desk run   <slug> [--opts]        Run the loop (this session = leader)
/rlp-desk status <slug>                Show loop status
/rlp-desk logs  <slug> [N]             Show iteration logs
/rlp-desk clean <slug> [--kill-session]  Reset for re-run
```

### Run Options

| Flag | Default | Description |
|------|---------|-------------|
| `--max-iter N` | 100 | Maximum iterations before timeout |
| `--worker-model MODEL` | sonnet | Worker model (haiku/sonnet/opus) |
| `--verifier-model MODEL` | opus | Verifier model (haiku/sonnet/opus) |
| `--mode agent\|tmux` | agent | Execution mode (see below) |
| `--worker-engine claude\|codex` | claude | Engine for Worker (claude uses Agent(), codex uses Bash CLI) |
| `--verifier-engine claude\|codex` | claude | Engine for Verifier |
| `--codex-model MODEL` | gpt-5.4 | Model passed to the Codex CLI (when engine=codex) |
| `--codex-reasoning low\|medium\|high` | high | Reasoning effort for Codex |
| `--verify-mode per-us\|batch` | per-us | Verification strategy (see below) |
| `--verify-consensus` | off | Cross-engine consensus verification (see below) |
| `--debug` | off | Debug logging to `logs/<slug>/debug.log` |
| `--with-self-verification` | off | Campaign-level post-loop analysis report |

## Execution Modes

RLP Desk supports two execution modes. Both honor the same governance protocol.

### Environment Compatibility

| Environment | Agent Mode | Tmux Mode |
|-------------|-----------|-----------|
| Claude Code (any terminal) | **Works** | Requires tmux |
| Inside tmux session | **Works** | **Works** — panes split in current window |
| Outside tmux session | **Works** | **Rejected** — "start tmux first" |

### Choosing Your Mode

| Need | Use |
|------|-----|
| Reliable autonomous loop (no interruption) | `--mode tmux` |
| Interactive development, quick tasks | `--mode agent` (default) |
| Long campaigns, CI, overnight runs | `--mode tmux` |

### Agent Mode (default) — "Smart Mode"

```
/rlp-desk run calculator
```

The current Claude Code session acts as the Leader, dispatching Workers and Verifiers via `Agent()`. The Leader is an LLM that dynamically routes models and reasons about context.

- Works anywhere — no tmux required
- Dynamic model routing — Leader upgrades models on failure

**Known limitation:** Agent mode runs inside Claude Code's turn-based request-response model. If the LLM outputs text without a tool call, the turn terminates and the loop pauses until the user sends "continue." This is a platform constraint — the protocol mitigates it but cannot guarantee 100% uninterrupted execution. For guaranteed autonomous loops, use tmux mode.
- Fix Loop — extracts verifier issues and feeds them back to the next worker
- Best for interactive development

### Tmux Mode — "Lean Mode"

```
/rlp-desk run calculator --mode tmux
```

**Requires running inside a tmux session.** A shell script takes over as Leader, splitting your current window into three panes. Workers run interactive `claude` sessions — you can watch them work in real-time.

```
+---------------------+---------------------+
| Your pane (Leader)  | Worker pane         |
| shell loop running  | claude TUI running  |
| polls signal files  | you see it working  |
|                     +---------------------+
|                     | Verifier pane       |
|                     | claude TUI running  |
|                     | (only when needed)  |
+---------------------+---------------------+
```

- Real-time visibility — watch Worker/Verifier execute live
- Zero-token orchestration — shell loop, not LLM
- Automatic cleanup — panes removed on completion
- Best for long campaigns and observability

Prerequisites: `tmux` and `jq` must be installed.

To clean up tmux artifacts:

```
/rlp-desk clean calculator --kill-session
```

## Engine Support

RLP Desk supports two execution engines for Worker and Verifier. **Claude is the default.** Codex is opt-in.

### Claude (default)

```
/rlp-desk run calculator
/rlp-desk run calculator --worker-engine claude --verifier-engine claude
```

Uses Claude Code's `Agent()` tool (agent mode) or `claude -p` CLI (tmux mode). Supports dynamic model routing (haiku/sonnet/opus).

### Codex (opt-in)

```bash
# Install codex CLI first
npm install -g @openai/codex

# Run with codex worker
/rlp-desk run calculator --worker-engine codex

# Customize model and reasoning effort
/rlp-desk run calculator --worker-engine codex --codex-model gpt-5.4 --codex-reasoning high

# Mix engines: codex worker, claude verifier
/rlp-desk run calculator --worker-engine codex --verifier-engine claude
```

Uses the `codex` CLI via `Bash()` (agent mode) or as an interactive TUI (tmux mode). The `codex` binary is only required when an engine is set to `codex`.

| Engine | Agent Mode | Tmux Mode | Dynamic Routing |
|--------|-----------|-----------|-----------------|
| claude | `Agent()` tool | `claude -p` TUI | Yes (haiku/sonnet/opus) |
| codex  | `Bash("codex ...")` | `codex` TUI | No (static model) |

## Verification Modes

RLP Desk supports two verification strategies. **Per-US is the default.**

### Per-US Verification (default)

```
/rlp-desk run calculator
/rlp-desk run calculator --verify-mode per-us
```

Each user story is verified independently after completion, then a final full verification runs after all stories pass:

```
Worker: US-001 → Verifier: US-001 AC only → pass
Worker: US-002 → Verifier: US-002 AC only → pass
Worker: US-003 → Verifier: US-003 AC only → pass
Final full verify: ALL AC → pass → COMPLETE
```

Benefits:
- Catch issues early, before later stories build on broken foundations
- Smaller verification scope = faster, more accurate checks
- Failed verification retries only the specific US

### Batch Verification

```
/rlp-desk run calculator --verify-mode batch
```

Legacy behavior: Worker completes all stories, then a single verification checks all acceptance criteria at once.

### Cross-Engine Consensus Verification

```
/rlp-desk run calculator --verify-consensus
```

When enabled, **both claude and codex verify independently**. Both must pass for verification to succeed.

```
Worker completes US → Claude verifies → Codex verifies
  Both pass → proceed
  Either fails → combined fix contract → Worker retry
  3 rounds without consensus → BLOCKED
```

Consensus can be combined with per-US mode for maximum rigor:

```
/rlp-desk run calculator --verify-mode per-us --verify-consensus
```

Prerequisites: Both `claude` and `codex` CLIs must be installed.

## Project Structure

After `init`, your project gets this scaffold:

```
your-project/
└── .claude/ralph-desk/
    ├── prompts/
    │   ├── <slug>.worker.prompt.md
    │   └── <slug>.verifier.prompt.md
    ├── context/
    │   └── <slug>-latest.md
    ├── memos/
    │   └── <slug>-memory.md
    ├── plans/
    │   ├── prd-<slug>.md
    │   └── test-spec-<slug>.md
    └── logs/<slug>/
        └── status.json
```

## Example: Calculator

See [`examples/calculator/`](examples/calculator/) for a complete example that implements a Python calculator module with tests using the RLP Desk loop.

The example demonstrates:
- A PRD with two user stories (calculator functions + pytest tests)
- Test specification with verification commands
- Worker and verifier prompts configured for the task

To try it yourself:

```
mkdir my-calc && cd my-calc
/rlp-desk brainstorm "Python calculator with add, subtract, multiply, divide + pytest tests"
/rlp-desk run loop-test
```

## Documentation

- [Architecture](docs/architecture.md) — Design philosophy, Agent() and tmux execution modes
- [Getting Started](docs/getting-started.md) — Step-by-step tutorial with the calculator example
- [Protocol Reference](docs/protocol-reference.md) — Full protocol specification
- [Future Plans](docs/TODO-verification-next.md) — P3 items and upcoming features

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

[MIT](LICENSE)
