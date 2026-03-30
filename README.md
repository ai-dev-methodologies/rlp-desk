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

```bash
# Recommended (cross-engine + final consensus):
/rlp-desk run <slug> --mode tmux --worker-model spark:high --consensus final-only --debug

# Claude-only:
/rlp-desk run <slug> --debug
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

### Live PRD Update

The Leader computes a hash for `prd-<slug>.md` at startup and again at each iteration using `md5`.

When the hash changes, it:

- Logs `prd_changed=true` with `prd_hash`, previous/new US counts, and `new_us`
- Splits the PRD into per-US files (`prd-<slug>-US-<id>.md`)
- Splits the test-spec into per-US files (`test-spec-<slug>-US-<id>.md`)
- Updates the in-memory PRD US list used for per-US dispatch
- Adds `NOTE: PRD was updated since last iteration. New/changed US may exist.` to the Worker prompt

If the PRD hash is unchanged, `prd_changed=false` is logged and no re-split is triggered.

If the PRD file is missing, the process degrades gracefully and continues without failing the campaign loop.

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

### Verification Strategy (v0.5)

**Core principle: Worker and Verifier use different AI engines whenever possible.**

- Per-US: lightweight verification after each user story (catches issues early)
- Final: top-tier consensus gate before COMPLETE (quality guarantee)
- Progressive upgrade: auto-upgrade models on consecutive failure (2-attempt windows)
- Verifier minimum: claude sonnet (haiku cannot verify)

#### 1. Claude-only (codex not installed)

Verifier is always +1 tier above Worker. Same-engine shares blind spots — install codex for improved detection.

| Risk | Worker | Per-US Verifier | Worker upgrade path | Verifier upgrade path |
|------|--------|-----------------|--------------------|-----------------------|
| LOW | haiku | sonnet | sonnet → opus | sonnet → opus |
| MEDIUM | sonnet | sonnet | opus | sonnet → opus |
| HIGH | sonnet | opus | opus | opus (ceiling) |
| CRITICAL | opus | opus ⚠ | (ceiling) | (ceiling) |

Final: **opus solo** ⚠ same-engine warning displayed

#### 2. Cross-engine: GPT Pro (spark + 5.4)

Spark is speed-optimized for coding. Use as Worker for LOW-HIGH; 5.4 for CRITICAL.

| Risk | Worker (codex) | Per-US Verifier (claude) | Worker upgrade path | Verifier upgrade path |
|------|---------------|--------------------------|--------------------|-----------------------|
| LOW | spark medium | sonnet | spark high → xhigh | sonnet → opus |
| MEDIUM | spark high | sonnet | spark xhigh → 5.4 medium | sonnet → opus |
| HIGH | spark xhigh | opus | 5.4 high → 5.4 xhigh | opus (ceiling) |
| CRITICAL | 5.4 high | opus | 5.4 xhigh | opus (ceiling) |

Final: **opus + 5.4 high** (both must PASS)

#### 3. Cross-engine: Non-Pro (5.4 only)

| Risk | Worker (codex) | Per-US Verifier (claude) | Worker upgrade path | Verifier upgrade path |
|------|---------------|--------------------------|--------------------|-----------------------|
| LOW | 5.4 low | sonnet | 5.4 medium → high | sonnet → opus |
| MEDIUM | 5.4 medium | sonnet | 5.4 high → xhigh | sonnet → opus |
| HIGH | 5.4 high | opus | 5.4 xhigh | opus (ceiling) |
| CRITICAL | 5.4 xhigh | opus | (ceiling) | opus (ceiling) |

Final: **opus + 5.4 high** (both must PASS)

#### Final Verify

| Environment | Engine 1 | Engine 2 | Rule |
|-------------|----------|----------|------|
| Claude-only | opus | — | Solo ⚠ |
| Cross-engine | opus | 5.4 high | Both must PASS → COMPLETE |

#### Progressive Upgrade (Worker Only)

Worker auto-upgrades on consecutive same-US failure. Verifier is fixed at campaign start. CB default: 6.

```
fail 1-2: keep current model (2-attempt window)
fail 3-4: upgrade 1 step (e.g., haiku → sonnet)
fail 5-6: upgrade 2 steps (e.g., haiku → opus)
fail 7+:  ceiling reached → BLOCKED
```

See `src/model-upgrade-table.md` for full upgrade paths per engine and complexity level.

#### Sequential Final Verify

When all US pass individually, the final ALL verify runs **sequentially per-US** instead of one big check. This prevents verifier timeout on large PRDs. After all per-US checks pass, the project's test suite runs once as a cross-US integration check.

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

| Option | Default | Description |
|--------|---------|-------------|
| `--mode agent\|tmux` | agent | agent=LLM Leader, tmux=shell Leader |
| `--worker-model MODEL` | haiku | Worker model. `name`=claude, `name:reasoning`=codex |
| `--lock-worker-model` | off | Disable auto model upgrade on failure |
| `--verifier-model MODEL` | sonnet | per-US verification model (lighter) |
| `--final-verifier-model MODEL` | opus | final ALL verification model (stricter) |
| `--consensus off\|all\|final-only` | off | Cross-engine consensus scope |
| `--consensus-model MODEL` | gpt-5.4:medium | per-US cross-verifier (lighter) |
| `--final-consensus-model MODEL` | gpt-5.4:high | final cross-verifier (stricter) |
| `--verify-mode per-us\|batch` | per-us | per-us: verify each US → final ALL |
| `--cb-threshold N` | 6 | Consecutive failures → BLOCKED |
| `--max-iter N` | 100 | Max iterations → TIMEOUT |
| `--iter-timeout N` | 600 | Per-iteration timeout seconds (tmux only) |
| `--debug` | off | Debug logging |
| `--with-self-verification` | off | Post-campaign SV report |

#### Per-US vs Final Verification

RLP Desk runs two distinct verification passes:

- **Per-US** (`--verifier-model`, default: sonnet) — runs after each user story completes. Lightweight and fast, catches issues early before later stories build on broken foundations.
- **Final ALL** (`--final-verifier-model`, default: opus) — runs once after all user stories pass individually. Stricter and more thorough, catches cross-US integration issues and anything per-US missed.

When `--consensus` is enabled, a second cross-engine verifier runs alongside each pass: `--consensus-model` for per-US and `--final-consensus-model` for the final ALL gate. Both engines must pass.

### Init Presets

After `brainstorm`, `init` detects your environment and presents run command presets:

- **Codex detected (GPT Pro / spark)** → recommends cross-engine mode (`--worker-model spark:high --consensus final-only`)
- **Codex detected (large PRD, AC > 15)** → offers gpt-5.4 preset (`--worker-model gpt-5.4:high --consensus final-only`)
- **Claude-only** → defaults to `--debug` with haiku worker and opus final verifier
- **Basic** → minimal flags for quick iteration

The brainstorm phase evaluates complexity (US count, file scope, logic, dependencies, code impact) and recommends a starting model. You can override any recommendation.

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

```bash
/rlp-desk run calculator
```

Uses Claude Code's `Agent()` tool (agent mode) or `claude -p` CLI (tmux mode). Supports dynamic model routing (haiku/sonnet/opus).

### Codex (opt-in)

```bash
# Install codex CLI first
npm install -g @openai/codex

# Run with codex worker (spark requires GPT Pro)
/rlp-desk run calculator --worker-model spark:high

# Customize model and reasoning effort
/rlp-desk run calculator --worker-model gpt-5.4:high

# Cross-engine: codex worker, claude verifier (recommended)
/rlp-desk run calculator --worker-model spark:high --consensus final-only --debug
```

The engine is inferred automatically from the `--worker-model` value: a plain model name (e.g. `haiku`) routes to Claude, while `name:reasoning` format (e.g. `spark:high`) routes to Codex. The `codex` binary is only required when a codex model is specified.

| Engine | Agent Mode | Tmux Mode | Dynamic Routing |
|--------|-----------|-----------|-----------------|
| claude | `Agent()` tool | `claude -p` TUI | Yes (haiku/sonnet/opus) |
| codex  | `Bash("codex ...")` | `codex` TUI | No (static model) |

## Verification Modes

### Per-US Verification (default)

Each user story is verified independently, then a final full verification runs:

```
Worker: US-001 → Verifier(per-US): US-001 only → pass
Worker: US-002 → Verifier(per-US): US-002 only → pass
...
Final Verify: opus + 5.4 high → both pass → COMPLETE
```

Per-US catches issues early before later stories build on broken foundations.

### Batch Verification

```
/rlp-desk run calculator --verify-mode batch
```

Worker completes all stories, then a single verification checks all AC at once. Final verify still applies.

## Project Structure

After `init`, your project gets this scaffold:

```
your-project/
├── .claude/
│   ├── settings.local.json          # rlp-desk permissions (auto-added by init)
│   └── ralph-desk/
│       ├── prompts/
│       │   ├── <slug>.worker.prompt.md
│       │   └── <slug>.verifier.prompt.md
│       ├── context/
│       │   └── <slug>-latest.md
│       ├── memos/
│       │   └── <slug>-memory.md
│       ├── plans/
│       │   ├── prd-<slug>.md
│       │   └── test-spec-<slug>.md
│       └── logs/<slug>/
│           └── status.json
```

### Local Settings

`init` automatically adds the following permissions to `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Read(.claude/ralph-desk/**)",
      "Edit(.claude/ralph-desk/**)",
      "Write(.claude/ralph-desk/**)"
    ]
  }
}
```

**Why:** Claude Code treats `.claude/` files as sensitive and prompts for confirmation on each access, even with `--dangerously-skip-permissions`. Without these permissions, Worker and Verifier agents are blocked by interactive prompts during automated loop execution.

**Note:** `settings.local.json` is local to your machine and is not committed to git. If the file already exists, permissions are merged without overwriting your existing settings.

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
