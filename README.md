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
npm install -g rlp-desk
```

Or without npm:

```bash
curl -sSL https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main/install.sh | bash
```

### 2. Brainstorm

In your project directory, start a Claude Code session:

```
/rlp-desk brainstorm "implement a Python calculator with tests"
```

This interactively defines the contract: slug, objective, user stories, verification commands, and iteration settings.

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
| Standard verification | `sonnet` |
| Security/critical logic verification | `opus` |

## Commands

```
/rlp-desk brainstorm <description>     Plan before init (interactive)
/rlp-desk init  <slug> [objective]     Create project scaffold
/rlp-desk run   <slug> [--opts]        Run the loop (this session = leader)
/rlp-desk status <slug>                Show loop status
/rlp-desk logs  <slug> [N]             Show iteration logs
/rlp-desk clean <slug>                 Reset for re-run
```

### Run Options

| Flag | Default | Description |
|------|---------|-------------|
| `--max-iter N` | 100 | Maximum iterations before timeout |
| `--worker-model MODEL` | sonnet | Worker model (haiku/sonnet/opus) |
| `--verifier-model MODEL` | sonnet | Verifier model (haiku/sonnet/opus) |

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

- [Architecture](docs/architecture.md) — Design philosophy and the Agent() approach
- [Getting Started](docs/getting-started.md) — Step-by-step tutorial with the calculator example
- [Protocol Reference](docs/protocol-reference.md) — Full protocol specification

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

[MIT](LICENSE)
