---
description: "Fresh-context RLP Desk — brainstorm, init, run, status, logs, clean"
argument-hint: "<brainstorm|init|run|status|logs|clean> <slug> [options]"
---

# RLP Desk for Claude Code

**YOU are the leader.** You orchestrate fresh-context workers/verifiers via Agent().

The user invoked: `/rlp-desk $ARGUMENTS`

Parse the first word of `$ARGUMENTS` as the subcommand.

---

## `brainstorm <description>`

Planning phase BEFORE init. Interactively define the contract **with the user**.

You MUST ask the user about each item below. Do NOT decide for them.
Present your suggestion, then wait for the user's confirmation or change.

Ask about these items one by one (or in small groups):
1. **Slug** — short identifier (e.g., `auth-refactor`). Suggest one, ask if OK.
2. **Objective** — what the loop achieves
3. **User Stories** — discrete units with testable acceptance criteria. Propose a breakdown, ask the user to confirm/modify.
4. **Iteration Unit** — what one worker does per iteration. Explicitly ask:
   - "One US per iteration (bounded, incremental verification)?"
   - "All stories at once (faster, single verification)?"
   - Default recommendation: one US per iteration for 3+ stories.
5. **Verification Commands** — build, test, lint commands
6. **Completion / Blocked Criteria**
7. **Worker / Verifier Model** — haiku, sonnet, opus. Suggest defaults (worker: sonnet, verifier: opus), ask if OK.
8. **Engine** — claude (default) or codex for Worker/Verifier. Ask: "Use claude (default) or codex for Worker/Verifier?" If codex: ask for model (default: gpt-5.4) and reasoning effort (default: high).
9. **Max Iterations** — suggest based on story count, ask if OK.

After all items are confirmed, present the full contract summary.
On approval, offer to run `init`.
Do NOT create files during brainstorm.
Do NOT auto-decide iteration unit — the user MUST explicitly choose.

---

## `init <slug> [objective]`

Run: `~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>"`
If brainstorm was done, auto-fill PRD and test-spec with the results.

---

## `run <slug> [options]`

**YOU are the leader. Do NOT delegate leadership.**

Options (parse from `$ARGUMENTS`):
- `--mode agent|tmux` (default: `agent`) — execution mode
- `--max-iter N` (default: 100)
- `--worker-model MODEL` (default: sonnet)
- `--verifier-model MODEL` (default: opus)
- `--worker-engine claude|codex` (default: `claude`) — engine for Worker
- `--verifier-engine claude|codex` (default: `claude`) — engine for Verifier
- `--codex-model MODEL` (default: `gpt-5.4`) — model passed to codex CLI
- `--codex-reasoning low|medium|high` (default: `high`) — reasoning effort for codex
- `--debug` — enable debug logging (tmux mode only, writes to logs/<slug>/debug.log)

### Mode Selection

Parse the `--mode` flag. If absent or `agent`, use the Agent() path below. If `tmux`, use the Tmux path.

#### Tmux Mode (`--mode tmux`)

When `--mode tmux` is specified:

1. **Validate scaffold** — same as Agent() mode: check `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` etc.
2. **Check sentinels** — same as Agent() mode.
3. **Check prerequisites** — verify `tmux` and `jq` are installed. If not, report what is missing and stop.
4. **Locate runner script** — find `run_ralph_desk.zsh` at `~/.claude/ralph-desk/run_ralph_desk.zsh`. If not found, tell the user to reinstall (`npm install` or `install.sh`).
5. **Launch** — shell out to the runner script with env vars derived from flags:
```bash
LOOP_NAME="<slug>" \
ROOT="$PWD" \
MAX_ITER=<--max-iter value> \
WORKER_MODEL=<--worker-model value> \
VERIFIER_MODEL=<--verifier-model value> \
WORKER_ENGINE=<--worker-engine value, default: claude> \
VERIFIER_ENGINE=<--verifier-engine value, default: claude> \
CODEX_MODEL=<--codex-model value, default: gpt-5.4> \
CODEX_REASONING=<--codex-reasoning value, default: high> \
DEBUG=<1 if --debug, else 0> \
  zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
```
6. **If the script exits with error (exit code 1)** — report the error to the user and STOP. Do NOT attempt to work around it. Do NOT create tmux sessions yourself. Do NOT re-launch the script in a different way. Just tell the user what went wrong and suggest using Agent mode instead.
7. **If successful** — tell the user the tmux session has been started. The shell script takes over as the deterministic Leader. No Agent() calls are made in tmux mode.

**IMPORTANT:** Tmux mode requires the user to already be inside a tmux session. If the runner script rejects because $TMUX is not set, do NOT try to create a tmux session yourself. Tell the user: "Start tmux first, then retry."

#### Agent Mode (`--mode agent` or default)

### Preparation
1. Validate scaffold: `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` etc.
2. Check sentinels (complete/blocked). Found → tell user `/rlp-desk clean <slug>`.
3. Clean previous `done-claim.json`, `verify-verdict.json`.

### Leader Loop

**CRITICAL: DO NOT STOP between iterations.** You MUST continue the loop automatically until a sentinel is written (COMPLETE or BLOCKED) or max_iter is reached. Do NOT pause to ask the user. Do NOT wait for confirmation. The loop is fully autonomous — just report each iteration result briefly and immediately proceed to the next iteration.

For each iteration (1 to max_iter):

**① Check sentinels**
```bash
test -f .claude/ralph-desk/memos/<slug>-complete.md  # → done
test -f .claude/ralph-desk/memos/<slug>-blocked.md   # → stop
```

**①½ Prep-stage cleanup**
```bash
rm -f .claude/ralph-desk/memos/<slug>-done-claim.json
rm -f .claude/ralph-desk/memos/<slug>-verify-verdict.json
```

**② Read memory.md** → Stop Status, Next Iteration Contract
- Also read **Completed Stories** → verified work so far
- Also read **Key Decisions** → settled architectural choices

**③ Decide model** (§4 of governance.md)
- Previous iteration failed → upgrade model
- Simple task → downgrade
- User specified → use that

**④ Build worker prompt**
- Read `.claude/ralph-desk/prompts/<slug>.worker.prompt.md`
- Combine with iteration number + memory contract
- Write to `.claude/ralph-desk/logs/<slug>/iter-NNN.worker-prompt.md` (audit trail)

**⑤ Execute Worker**

If `--worker-engine claude` (default):
```
Agent(
  description="rlp-desk worker iter-NNN",
  subagent_type="executor",
  model=<worker_model>,
  mode="bypassPermissions",
  prompt=<full worker prompt text>
)
```
- Agent returns synchronously. No polling needed.
- Each Agent() = fresh context. Guaranteed.

If `--worker-engine codex`:
```
Bash("codex exec --model <codex_model> --reasoning-effort <codex_reasoning> <full worker prompt text>")
```
- Codex runs as a subprocess via Bash(), not Agent().
- Each Bash() call = fresh context for codex.

**⑥ Read memory.md again** (Worker updated it)
- `stop=continue` → go to ⑧
- `stop=verify` → go to ⑦
- `stop=blocked` → write BLOCKED sentinel, stop

**⑦ Execute Verifier**
- Build verifier prompt, write to `iter-NNN.verifier-prompt.md`

If `--verifier-engine claude` (default):
```
Agent(
  description="rlp-desk verifier iter-NNN",
  subagent_type="executor",
  model=<verifier_model>,
  mode="bypassPermissions",
  prompt=<full verifier prompt text>
)
```

If `--verifier-engine codex`:
```
Bash("codex exec --model <codex_model> --reasoning-effort <codex_reasoning> <full verifier prompt text>")
```
- Read `verify-verdict.json`:
  - `pass` + `complete` → write COMPLETE sentinel, report done!
  - `fail` + `continue` → **run Fix Loop** (governance.md §7½):
    1. Read `issues` array, sort by severity (`critical` → `major` → `minor`)
    2. Build structured fix contract with traceability rule
    3. Include `fix_hint` values labeled `(suggestion, non-authoritative)` if present
    4. Increment `consecutive_failures` in `status.json`
    5. Go to ⑧ with fix contract as next Worker contract
  - `request_info` → Leader reads Verifier's questions, decides outcome (or relays to Worker in next contract) → go to ⑧
  - `blocked` → write BLOCKED sentinel, stop

**⑧ Write result log and report to user, continue loop**
- Write `logs/<slug>/iter-NNN.result.md`:
  - Result status `[leader-measured]`
  - Files changed via `git diff --stat HEAD~1 HEAD` `[git-measured]`
  - Verifier verdict `[leader-measured]`
- Write `status.json`
- Report: iteration N, phase, model used, result

### Circuit Breaker
- context-latest.md unchanged 3 iterations → BLOCKED
- Same acceptance criterion fails 2 consecutive iterations → upgrade model, retry once, then BLOCKED
- 3 consecutive **fail** verdicts on 3 unique criterion IDs → upgrade to opus, retry once, then BLOCKED
- max_iter reached → TIMEOUT, report to user

Track `consecutive_failures` in `status.json` (increment on `fail`, reset on `pass`, unchanged by `request_info`). Only **fail** verdicts count for CB chains — `request_info` does not break or contribute.

### Important Rules
- Each Agent() = new process = fresh context
- YOU track iteration count
- Write `status.json` after each iteration
- Worker claim ≠ complete. Only YOU write COMPLETE sentinel after verifier pass.

---

## `status <slug>`
Read `.claude/ralph-desk/logs/<slug>/status.json` and display.

## `logs <slug> [N]`
- No N: show latest `iter-*.worker-prompt.md` summary
- With N: read `iter-N.worker-prompt.md` and `iter-N.verifier-prompt.md`

## `clean <slug> [--kill-session]`
Remove:
- `.claude/ralph-desk/memos/<slug>-complete.md`
- `.claude/ralph-desk/memos/<slug>-blocked.md`
- `.claude/ralph-desk/memos/<slug>-done-claim.json`
- `.claude/ralph-desk/memos/<slug>-verify-verdict.json`
- `.claude/ralph-desk/memos/<slug>-iter-signal.json`
- `.claude/ralph-desk/logs/<slug>/circuit-breaker.json`
- `.claude/ralph-desk/logs/<slug>/session-config.json`
- `.claude/ralph-desk/logs/<slug>/worker-heartbeat.json`
- `.claude/ralph-desk/logs/<slug>/verifier-heartbeat.json`

If `--kill-session` is passed, also kill any tmux session matching `rlp-desk-<slug>-*`:
```bash
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^rlp-desk-<slug>-" | while read s; do tmux kill-session -t "$s"; done
```

## No args or `help`
```
/rlp-desk brainstorm <description>          Plan before init (interactive)
/rlp-desk init  <slug> [objective]          Create project scaffold
/rlp-desk run   <slug> [--mode agent|tmux]  Run loop (agent=LLM leader, tmux=shell leader)
/rlp-desk status <slug>                     Show loop status
/rlp-desk logs  <slug> [N]                  Show iteration log
/rlp-desk clean <slug> [--kill-session]     Reset for re-run (--kill-session kills tmux)
```

## Architecture

### Agent Mode (default: `--mode agent`)
```
[This session = LEADER (LLM)]
        │
  Agent()├──▶ [Worker: executor (fresh context)]
        │     └── reads desk files, implements, updates memory
        │
  Agent()└──▶ [Verifier: executor (fresh context)]
              └── reads done-claim, runs checks, writes verdict
```

### Tmux Mode (`--mode tmux`)
```
[tmux session: rlp-desk-<slug>-<timestamp>]
+-------------------------------------+
| Leader pane (shell loop)            |
| - writes prompts to files           |
| - sends short triggers via send-keys|
| - polls iter-signal.json            |
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
