# Ralph Desk Governance v2

Fresh-context independent verification protocol.
The Leader orchestrates, while Worker/Verifier run in isolated fresh contexts every iteration.

---

## 1. Core Principles

- **Fresh context per iteration**: Worker/Verifier start fresh every time. No prior conversation.
- **Filesystem = memory**: State exists only on the filesystem (PRD, memory, context, memos).
- **Worker claim ≠ complete**: A Worker's DONE is merely a claim. The Verifier must independently verify before it's confirmed.
- **Verifier is independent**: The Verifier judges based on evidence alone, without knowledge of the Worker's reasoning process.
- **Sentinels are Leader-owned**: Only the Leader writes COMPLETE/BLOCKED sentinels.
- **Supported engines**: claude (default; models: haiku, sonnet, opus) and codex (opt-in via `--worker-engine codex` / `--verifier-engine codex`).

## 2. Roles

### Leader (current session)
- Operates the loop, selects models, controls flow
- Dispatches Worker/Verifier via Agent()
- Reads memory to assess state, writes sentinels
- **Does NOT write or execute code**

### Worker (fresh context)
- Performs one bounded action per iteration
- Updates context and memory (so the next fresh worker can continue)
- Writes done-claim.json when claiming completion

### Verifier (fresh context)
- Independently verifies Worker's done claim
- Identifies scope via `git diff --name-only` — reads changed files and related imports only
- Runs commands directly to collect fresh evidence
- Campaign Memory is for orientation only — not the source of truth
- Writes verdict (`pass` | `fail` | `request_info`) — if uncertain, use `request_info` with specific questions; Leader decides
- Delegates deterministic checks (type hints, linting, security) to tools defined in test-spec
- Focuses on AC verification, semantic review, and smoke tests
- **Must NEVER modify code or write sentinel files**

## 3. State Flow

```
RUNNING → DONE_CLAIMED → VERIFYING → COMPLETE | CONTINUE | BLOCKED
```

## 4. Model Routing

### Claude (default engine)

| Role | Default Model | Override Criteria |
|------|---------------|-------------------|
| Worker (simple) | haiku | Single file, clear change |
| Worker (standard) | sonnet | Most tasks (default) |
| Worker (complex) | opus | Architecture changes, multi-file, prior iteration failure |
| Verifier | opus | Independent verification requires thoroughness |
| Verifier (lightweight) | sonnet | Simple, well-defined checks only |

The Leader decides each iteration. Decision criteria:
- Previous iteration failed → upgrade model
- Simple repetitive task → downgrade model
- User explicitly specified → use as given

### Codex (opt-in engine)

| Option | Default | Description |
|--------|---------|-------------|
| `--codex-model` | `gpt-5.4` | Model passed to the `codex` CLI |
| `--codex-reasoning` | `high` | Reasoning effort: `low`, `medium`, or `high` |

Model routing is static when using codex: the same model and reasoning effort apply to both Worker and Verifier. There is no dynamic upgrade path. Claude is the default engine; codex is explicitly opt-in.

## 5a. Execution: Agent() Approach (default) — "Smart Mode"

All environments (Claude Code, OpenCode) use the same Agent tool.

```
# Worker (claude engine, default)
Agent(
  subagent_type="executor",
  model="sonnet",
  prompt=worker_prompt,
  mode="bypassPermissions"
)

# Verifier (claude engine, default)
Agent(
  subagent_type="executor",
  model="sonnet",
  prompt=verifier_prompt,
  mode="bypassPermissions"
)
```

If `--worker-engine codex` or `--verifier-engine codex` (opt-in):
```
# Worker or Verifier (codex engine)
Bash("codex -m <codex_model> -c model_reasoning_effort=<codex_reasoning> --dangerously-bypass-approvals-and-sandbox <prompt>")
```
- Codex runs as a subprocess via `Bash()`, not `Agent()` — the Agent tool is Claude-specific.
- Each `Bash()` call = fresh context for codex.
- Claude is the default engine. Codex is explicitly opt-in.

Characteristics:
- Each call = fresh context (new subprocess)
- Synchronous return. No polling or signal files needed.
- After Agent completes, read memory.md to assess state.
- No tmux required.
- Monitor in real-time via ctrl+o (Claude Code UI).
- Prompts are still logged to logs/ for audit trail.
- Leader is an LLM — can dynamically route models, reason about context, and adapt.

## 5b. Execution: Tmux Runner (alternative) — "Lean Mode"

For long campaigns, observability, headless/CI execution, or when zero-token orchestration is preferred.

```bash
# Launched via slash command:
/rlp-desk run <slug> --mode tmux

# Or directly:
LOOP_NAME=<slug> ROOT=$(pwd) ~/.claude/ralph-desk/run_ralph_desk.zsh
```

The tmux runner (`run_ralph_desk.zsh`) creates a tmux session with three panes:
- **Leader pane** — deterministic shell loop (no LLM)
- **Worker pane** — receives `claude -p` invocations via trigger scripts
- **Verifier pane** — receives `claude -p` invocations via trigger scripts

By default, `claude` CLI calls use `--dangerously-skip-permissions`:
```bash
# claude engine (default)
claude -p "$(cat /path/to/prompt.md)" \
  --model sonnet \
  --dangerously-skip-permissions
```

When `WORKER_ENGINE=codex` or `VERIFIER_ENGINE=codex`, the `codex` CLI is used instead:
```bash
# codex engine (opt-in)
codex -m gpt-5.4 \
  -c model_reasoning_effort="high" \
  --dangerously-bypass-approvals-and-sandbox \
  "$(cat /path/to/prompt.md)"
```
The codex CLI is only required when an engine is set to `codex`. Claude remains the default engine throughout.

**Security implication:** Both `--dangerously-skip-permissions` (claude) and `--dangerously-bypass-approvals-and-sandbox` (codex) allow the CLI to execute code without user confirmation. The tmux runner requires this because there is no interactive user to approve each action. Only run tmux mode in trusted environments with trusted prompts.

Characteristics:
- Leader is a shell script, not an LLM — zero tokens consumed for orchestration.
- Leader reads ONLY `iter-signal.json` and `verify-verdict.json` for control flow (structured JSON via `jq`). No markdown parsing.
- Model routing is static via environment variables (`WORKER_MODEL`, `VERIFIER_MODEL`). This is an explicit trade-off vs Agent() mode's dynamic routing.
- **Write-then-notify:** All prompts and payloads are written to files first. Only short trigger commands (`bash /path/to/trigger.sh`) are sent via `tmux send-keys`.
- **Pane IDs (`%N` format):** Captured at pane creation, stored in `session-config.json`. Never uses positional indices.
- **Copy-mode guard:** Checks `#{pane_in_mode}` before every `send-keys` to avoid sending into scrollback.
- **Heartbeat monitoring:** Trigger scripts write heartbeat files; Leader checks freshness.
- **Atomic file writes:** All file writes use `{path}.tmp.{pid}` + `mv` for crash safety.
- Can run detached (`tmux detach`) for overnight/CI campaigns.
- User can watch Worker/Verifier execution in real-time via tmux panes.
- Traceability: governance section 7 step numbers appear as comments throughout the shell script.

## 6. File Structure

### User-level (central)
```
~/.claude/ralph-desk/
├── init_ralph_desk.zsh        # Scaffold generator (automation)
├── governance.md              # This document
└── templates/                 # Prompt templates
```

### Project-local
```
.claude/ralph-desk/
├── prompts/
│   ├── <slug>.worker.prompt.md      # Worker base prompt
│   └── <slug>.verifier.prompt.md    # Verifier base prompt
├── context/
│   └── <slug>-latest.md             # Current frontier (Worker updates)
├── memos/
│   ├── <slug>-memory.md             # Campaign memory (Worker updates)
│   ├── <slug>-done-claim.json       # Worker's completion claim (runtime)
│   ├── <slug>-iter-signal.json      # Worker's iteration signal (runtime)
│   ├── <slug>-verify-verdict.json   # Verifier's verdict (runtime)
│   ├── <slug>-complete.md           # SENTINEL (Leader only)
│   └── <slug>-blocked.md            # SENTINEL (Leader only)
├── plans/
│   ├── prd-<slug>.md                # PRD (shared contract)
│   └── test-spec-<slug>.md          # Verification criteria
└── logs/<slug>/
    ├── iter-NNN.worker-prompt.md    # Audit trail prompt copy
    ├── iter-NNN.verifier-prompt.md  # Audit trail prompt copy
    ├── iter-NNN.result.md           # Iteration result (leader-measured + git-measured)
    └── status.json                  # Leader's loop state
```

## 7. Leader Loop Protocol

```
for iteration in 1..max_iter:

  ① Check sentinels
     - complete.md exists → stop
     - blocked.md exists → stop

  ①½ Prep-stage cleanup
     - Delete done-claim.json if exists
     - Delete verify-verdict.json if exists

  ② Read memory.md → check Stop Status, Next Iteration Contract
     - Also parse Completed Stories (verified work so far)
     - Also parse Key Decisions (settled architectural choices)

  ③ Select model
     - Default or situational decision (see §4)
     - Context unchanged for 3 consecutive iterations → BLOCKED

  ④ Build Worker prompt
     - Base prompt + iteration number + contract from memory
     - Log to logs/<slug>/iter-NNN.worker-prompt.md

  ⑤ Execute Worker: Agent(subagent_type="executor", model=selected, prompt=prompt)
     - Synchronous return, wait for completion

  ⑥ Read memory.md again → check Worker's updated state
     - "continue" → go to ⑧
     - "verify"   → go to ⑦ (also read iter-signal.json for us_id)
     - "blocked"  → write BLOCKED sentinel, stop
     Note: In tmux mode, the Leader polls `<slug>-iter-signal.json` instead of
     parsing memory.md. In Agent() mode, the Leader MAY read iter-signal.json
     as a structured alternative to parsing the Stop Status from memory.md.

  ⑦ Execute Verifier (see §7a for per-US and §7b for consensus details)
     - Build prompt (scoped to us_id if per-us mode) → log
     - Agent(subagent_type="executor", model=selected, prompt=prompt)
     - If --verify-consensus: run second verifier with alternate engine (see §7b)
     - Read verify-verdict.json:
       • pass + specific US → add to verified_us, Worker does next US
       • pass + us_id=ALL or complete → write COMPLETE sentinel, stop
       • fail + continue → go to ⑧
       • blocked → write BLOCKED sentinel, stop

  ⑧ Write iter-NNN.result.md to logs/<slug>/ (result status + git diff --stat)
     Update status.json, report to user, continue to next iteration
```

## 7a. Per-US Verification

By default (`--verify-mode per-us`), each user story is verified independently before proceeding to the next:

```
Worker completes US-001 → signal verify (us_id: "US-001")
  → Verifier checks ONLY US-001 AC → pass
  → Worker completes US-002 → signal verify (us_id: "US-002")
  → Verifier checks ONLY US-002 AC → pass
  → ...
  → All US individually pass → signal verify (us_id: "ALL")
  → Verifier runs FINAL FULL VERIFY (all AC) → pass → COMPLETE
```

**Key rules:**
- Worker signals `verify` after each US with `us_id` set in `iter-signal.json`
- Verifier checks only the scoped US acceptance criteria (or all if us_id=ALL)
- Leader tracks `verified_us` array in `status.json`
- If a per-US verify fails, the Worker retries that specific US (fix loop)
- Final full verify ensures nothing was broken by later changes

**Batch mode** (`--verify-mode batch`) preserves legacy behavior: Worker signals `verify` only after all work is done, and the Verifier checks all AC at once.

## 7b. Cross-Engine Consensus Verification

When `--verify-consensus` is enabled, after the primary verifier runs, a second verifier runs with the alternate engine:

```
Worker completes US → signal verify
  → Claude Verifier runs (checks AC)
  → Codex Verifier runs (checks AC)
  → Both pass → proceed (next US or COMPLETE)
  → Either fails → combined issues → fix contract → Worker retry
  → Max 3 consensus rounds per US → BLOCKED if still disagreeing
```

**Key rules:**
- Both claude and codex CLI must be installed
- Verifiers run sequentially in the same Verifier pane (tmux) or as sequential calls (Agent mode)
- Verdicts are saved as `verify-verdict-claude.json` and `verify-verdict-codex.json`
- Combined fix contracts include issues from both engines
- `status.json` includes `consensus_round`, `claude_verdict`, and `codex_verdict` fields
- Consensus can be combined with per-US verification (each US gets consensus-verified)

## 7½. Fix Loop Protocol

When the Verifier returns `fail`, the Leader runs the Fix Loop before issuing the next Worker contract:

1. **Read issues** from `verify-verdict.json` — sort by severity (`critical` → `major` → `minor`)
2. **Build fix contract** — include each issue as a numbered task with criterion reference
   - `fix_hint` (if present) is passed as `(suggestion, non-authoritative)` — Worker may ignore
3. **Traceability rule**: "Only changes that resolve a listed issue are allowed — every change must be justified by the issue it addresses"
4. **Update status.json** — increment `consecutive_failures`; reset to 0 on any `pass`

The `consecutive_failures` counter is maintained by the Leader in `status.json`.

**Fix contract format:**
```
Fix issues from Verifier verdict (iter-NNN):

1. [critical] US-002 AC3: <description> — fix_hint: (suggestion, non-authoritative) <hint>
2. [major] US-001 AC1: <description>

Traceability: only changes that resolve a listed issue are allowed.
Every change must be justified by the issue it addresses.
```

## 8. Circuit Breaker

| Condition | Verdict |
|-----------|---------|
| context-latest.md unchanged for 3 consecutive iterations | BLOCKED |
| Same acceptance criterion fails 2 consecutive iterations | Upgrade model, retry once; if still failing → BLOCKED |
| 3 consecutive **fail** verdicts on 3 unique criterion IDs | Upgrade to opus, retry once; if still failing → BLOCKED |
| max_iter reached | TIMEOUT (report to user) |

The Leader tracks `consecutive_failures` in `status.json`:
- Increments on `fail`, resets on `pass`, **unchanged by `request_info`**.
- "Same error" = same acceptance criterion ID in two consecutive **fail** verdicts (`request_info` does not break or contribute to this chain).
- "Diverse failures" = 3 most recent `fail` verdicts each have a unique criterion ID.

## 9. Change Policy

- Changes to the shared workflow → modify this document
- Project-specific objectives/criteria → modify project-local files
- Init script changes → modify init_ralph_desk.zsh
