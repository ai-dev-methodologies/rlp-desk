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
- **User Stories** — discrete, testable units of work
- **Iteration Unit** — one story per iteration (incremental) or all at once (fast)
- **Verification Commands** — how to check the work
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

### Circuit Breakers

| Condition | Action |
|-----------|--------|
| Context unchanged for 3 iterations | BLOCKED |
| Same error repeated twice | Upgrade model, retry once, then BLOCKED |
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

## Execution Modes

RLP Desk supports two execution modes. Both honor the same governance protocol.

### Environment Compatibility

| Environment | Agent Mode | Tmux Mode |
|-------------|-----------|-----------|
| Claude Code (any terminal) | **Works** | Requires tmux |
| Inside tmux session | **Works** | **Works** — panes split in current window |
| Outside tmux session | **Works** | **Rejected** — "start tmux first" |

### Agent Mode (default) — "Smart Mode"

```
/rlp-desk run calculator
```

The current Claude Code session acts as the Leader, dispatching Workers and Verifiers via `Agent()`. The Leader is an LLM that dynamically routes models and reasons about context.

- Works anywhere — no tmux required
- Dynamic model routing — Leader upgrades models on failure
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

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

[MIT](LICENSE)
