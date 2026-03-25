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
   - Apply INVEST criteria: each US must be Independent, Negotiable, Valuable, Estimable, Small, Testable.
   - Each AC MUST use Given/When/Then format with **domain language only** (no class names, API paths, DB tables):
     ```
     Given [precondition in domain language]
     When [action in domain language]
     Then [expected outcome with quantitative criteria]
     ```
   - Include at least 1 negative test per US ("must NOT happen").
   - Include boundary cases per US (empty, max, zero, concurrent).
   - **Task Type** per US: `code` | `visual` | `content` | `integration` | `infra`
   - **Risk Level** per US (governance §1c): `LOW` | `MEDIUM` | `HIGH` | `CRITICAL`
4. **Iteration Unit** — what one worker does per iteration. Explicitly ask:
   - "One US per iteration (bounded, incremental verification)?"
   - "All stories at once (faster, single verification)?"
   - Default recommendation: one US per iteration for 3+ stories.
5. **Verification Commands** — build, test, lint commands
6. **Completion / Blocked Criteria**
7. **Worker / Verifier Model** — haiku, sonnet, opus. Suggest defaults (worker: sonnet, verifier: opus), ask if OK.
8. **Engine & Model** — For each role (Worker, Verifier):
   - Engine: claude (default) or codex
   - If claude: suggest model (haiku/sonnet/opus) based on task complexity
   - If codex: suggest model (default: gpt-5.4) and reasoning effort (low/medium/high)
   - AI should recommend: "For this task complexity, I suggest Worker: sonnet, Verifier: opus"
   - If codex selected: "For codex Worker, I suggest gpt-5.4 with high reasoning"
9. **Verify Mode** — per-us (default) or batch. Ask: "Verify after each user story (per-us, recommended) or only after all stories are done (batch)?" Default recommendation: per-us for 2+ stories.
10. **Verify Consensus** — Ask: "Use cross-engine consensus verification? (Both claude and codex verify independently, both must pass.) Requires codex CLI." Default: no.
11. **Consensus Scope** — If consensus enabled, ask: "Consensus on every verify (all, default) or only on final verify (final-only)?" Default: all.
12. **Max Iterations** — suggest based on story count, ask if OK.

After all items are confirmed:

1. **Ambiguity Gate (IL-2)** — score each AC per governance §1a IL-2 (6 dimensions, 0-12 points).
   If ANY AC scores below 6: **REJECT** — refine that AC before proceeding.
   If all ACs score 6-9: **WARN** — proceed with logged warning, show low-scoring dimensions.
   If all ACs score 10-12: **PASS** — clean.
   Present the score table to the user before proceeding.
2. Present the full contract summary.
3. **Self-Verification** — Ask: "Enable self-verification? Worker records step-by-step evidence, Verifier cross-validates process. Recommended for MEDIUM+ risk." Default: yes for HIGH/CRITICAL, no for LOW/MEDIUM.
4. On approval, offer to run `init`.

Do NOT create files during brainstorm.
Do NOT auto-decide iteration unit — the user MUST explicitly choose.

---

## `init <slug> [objective]`

Run: `~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>"`
If brainstorm was done, auto-fill PRD and test-spec with the results.

**After init completes, STOP. Do NOT auto-run the loop.**

Tell the user:
1. The scaffold has been created — list the generated files
2. Ask them to review/edit the PRD and test-spec if needed
3. Show the run command with available options:
```
/rlp-desk run <slug> [options]

Options:
  --mode agent|tmux
  --worker-engine claude|codex
  --verifier-engine claude|codex
  --verify-mode per-us|batch
  --verify-consensus
  --consensus-scope all|final-only
```
4. Wait for the user to explicitly invoke `/rlp-desk run`

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
- `--worker-codex-model MODEL` (default: `gpt-5.4`) — codex model for Worker
- `--worker-codex-reasoning low|medium|high` (default: `high`) — reasoning for Worker
- `--verifier-codex-model MODEL` (default: `gpt-5.4`) — codex model for Verifier
- `--verifier-codex-reasoning low|medium|high` (default: `high`) — reasoning for Verifier
- `--verify-mode per-us|batch` (default: `per-us`) — verification strategy
  - `per-us`: verify after each US, then final full verify of all AC
  - `batch`: verify only after all US done (legacy behavior)
- `--verify-consensus` — enable cross-engine consensus verification (both claude and codex verify independently; both must pass)
- `--consensus-scope all|final-only` — when consensus runs (default: `all`)
  - `all`: consensus runs on every verify (current behavior)
  - `final-only`: consensus only on final ALL verify
- `--debug` — enable debug logging (writes to logs/<slug>/debug.log)
- `--with-self-verification` — enable campaign-level self-verification analysis. After COMPLETE, Leader analyzes all iteration records (done-claims + verdicts) and generates a campaign self-verification summary with patterns and recommendations for next planning cycle. (Note: execution_steps and reasoning are ALWAYS recorded per governance §1f — this flag adds post-campaign analysis.)

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
WORKER_CODEX_MODEL=<--worker-codex-model value, default: gpt-5.4> \
WORKER_CODEX_REASONING=<--worker-codex-reasoning value, default: high> \
VERIFIER_CODEX_MODEL=<--verifier-codex-model value, default: gpt-5.4> \
VERIFIER_CODEX_REASONING=<--verifier-codex-reasoning value, default: high> \
VERIFY_MODE=<--verify-mode value, default: per-us> \
VERIFY_CONSENSUS=<1 if --verify-consensus, else 0> \
CONSENSUS_SCOPE=<--consensus-scope value, default: all> \
DEBUG=<1 if --debug, else 0> \
  zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
```
6. **If the script exits with error (exit code 1)** — report the error to the user and STOP. Do NOT attempt to work around it. Do NOT create tmux sessions yourself. Do NOT re-launch the script in a different way. Just tell the user what went wrong and suggest using Agent mode instead.
7. **If successful** — tell the user the tmux session has been started. The shell script takes over as the deterministic Leader. No Agent() calls are made in tmux mode.

**IMPORTANT RULES:**
- Tmux mode requires the user to already be inside a tmux session. If the runner script rejects because $TMUX is not set, do NOT try to create a tmux session yourself. Tell the user: "Start tmux first, then retry."
- Do NOT run the script in background (`&`, `run_in_background`). The script must run in foreground so panes remain visible to the user. The user needs to see Worker/Verifier panes in real-time.
- Do NOT kill panes after completion. Panes stay alive for inspection. User cleans up with `/rlp-desk clean <slug> --kill-session`.

#### Agent Mode (`--mode agent` or default)

### Preparation
1. Validate scaffold: `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` etc.
2. Check sentinels (complete/blocked). Found → tell user `/rlp-desk clean <slug>`.
3. Clean previous `done-claim.json`, `verify-verdict.json`.
4. **Always**: write baseline log entry to `.claude/ralph-desk/logs/<slug>/baseline.log`: `[timestamp] iter=0 phase=start slug=<slug> worker_model=<model> verifier_model=<model>`. Baseline.log captures 1 line per iteration for lightweight post-mortem (always-on, no flag needed).
5. If `--debug`: also create/clear `logs/<slug>/debug.log`. Define a helper: to "debug_log" means append a timestamped line to this file via `Bash("echo \"[$(date '+%Y-%m-%d %H:%M:%S')] $msg\" >> .claude/ralph-desk/logs/<slug>/debug.log")`. When `--debug` is active, debug.log contains all baseline.log fields plus detailed phase logs.

### Leader Loop

**CRITICAL: DO NOT STOP between iterations.** You MUST continue the loop automatically until a sentinel is written (COMPLETE or BLOCKED) or max_iter is reached. Do NOT pause to ask the user. Do NOT wait for confirmation. The loop is fully autonomous — just report each iteration result briefly and immediately proceed to the next iteration.

If `--debug`, at loop start debug_log: `[PLAN] slug=<slug> max_iter=<N> worker_engine=<engine> worker_model=<model> verifier_engine=<engine> verifier_model=<model> verify_mode=<mode> consensus=<0|1> consensus_scope=<scope>`

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
- If `--debug`: debug_log `[EXEC] iter=N phase=read_memory stop_status=<status> contract="<summary>"`

**③ Decide model** (§4 of governance.md)
- Previous iteration failed → upgrade model
- Simple task → downgrade
- User specified → use that
- If `--debug`: debug_log `[EXEC] iter=N phase=model_select worker_model=<model> reason=<reason>`

**④ Build worker prompt (Prompt Assembly Protocol)**
1. Capture `WORKING_DIR` once: use `$PWD` from when `/rlp-desk run` was invoked. Store for all prompt construction.
2. Read `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` — use its content **verbatim**. Do NOT rewrite, paraphrase, or regenerate paths. The prompt file contains correct absolute paths from init.
3. Prepend meta comment: `## WORKING_DIR: {absolute path}` — Worker must use this as its working directory.
4. Append iteration number + memory contract.
5. Write to `.claude/ralph-desk/logs/<slug>/iter-NNN.worker-prompt.md` (audit trail).
- Note: Worker ALWAYS records execution_steps in done-claim.json per governance §1f. No flag needed.
- **Rewriting paths from absolute to relative WILL break worktree campaigns. Only additions (WORKING_DIR header, iteration context) are allowed.**

**④½ Contract review** (agent mode only)
- Before dispatching Worker, spawn a lightweight review: "Is this iteration contract sufficient to achieve the US's AC? Any missing steps?"
- If `--debug`: debug_log `[EXEC] iter=N phase=contract_review result=<ok|issues>`
- In tmux mode: skip (shell leader cannot reason). Log: `[EXEC] iter=N phase=contract_review skipped=tmux_mode`

**⑤ Execute Worker**
- If `--debug`: debug_log `[EXEC] iter=N phase=worker engine=<engine> model=<model> dispatched=true`

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
Bash("codex exec --model <worker_codex_model> --reasoning-effort <worker_codex_reasoning> <full worker prompt text>")
```
- Codex runs as a subprocess via Bash(), not Agent().
- Each Bash() call = fresh context for codex.

- If `--debug`: debug_log `[EXEC] iter=N phase=worker_done engine=<engine>`

**⑥ Read memory.md again** (Worker updated it)
- `stop=continue` → go to ⑧
- `stop=verify` → go to ⑦
- `stop=blocked` → write BLOCKED sentinel, stop
- Also read `iter-signal.json` for `us_id` field (which US was just completed)
- If `--debug`: debug_log `[EXEC] iter=N phase=worker_signal status=<stop_status> us_id=<us_id>`

**CRITICAL: Immediately proceed to ⑦. Do NOT pause, do NOT ask the user, do NOT wait for confirmation. The loop is autonomous.**

**⑦ Execute Verifier**

**Per-US mode** (default, `--verify-mode per-us`):
- Read `us_id` from `iter-signal.json` (e.g., "US-001" or "ALL")
- Build verifier prompt scoped to `us_id`:
  - If `us_id` is a specific story: "Verify ONLY the acceptance criteria for {us_id}"
  - If `us_id` is "ALL": "Verify ALL acceptance criteria (final full verify)"
- Write to `iter-NNN.verifier-prompt.md`
- Track verified US in `status.json` field `verified_us` (array)
- After verifier passes a specific US:
  - Add that US to `verified_us` in status.json
  - If more US remain → Worker does next US → verify → ...
  - If all US individually passed → signal final full verify (us_id=ALL)
  - After final full verify passes → COMPLETE

**Batch mode** (`--verify-mode batch`):
- Legacy behavior: verify only when Worker signals all work is done
- Verifier checks all AC at once

**⑦a Dispatch Verifier**
- Note: Verifier ALWAYS records reasoning in verify-verdict.json per governance §1f. No flag needed.
- **Prompt Assembly Protocol (same as ④)**: Read verifier prompt file verbatim. Prepend `## WORKING_DIR: {absolute path}`. Do NOT rewrite paths.
- If `--debug`: debug_log `[EXEC] iter=N phase=verifier engine=<engine> model=<model> scope=<us_id> dispatched=true`

If `--verifier-engine claude` (default):
```
Agent(
  description="rlp-desk verifier iter-NNN (us_id)",
  subagent_type="executor",
  model=<verifier_model>,
  mode="bypassPermissions",
  prompt=<full verifier prompt text with US scope>
)
```

If `--verifier-engine codex`:
```
Bash("codex exec --model <verifier_codex_model> --reasoning-effort <verifier_codex_reasoning> <full verifier prompt text>")
```

**⑦b Consensus Verification** (when `--verify-consensus` is enabled):
After the primary verifier runs, run a second verifier with the OTHER engine:
- If primary engine is claude → run codex verifier
- If primary engine is codex → run claude verifier
- Both produce `verify-verdict.json` (Leader renames to `verify-verdict-claude.json` and `verify-verdict-codex.json`)
- **Both pass** → proceed (next US or COMPLETE)
- **Either fails** → combine issues from both verdicts into a single fix contract → Worker retry
- Max 3 consensus rounds per US. After 3 rounds → BLOCKED.

**⑦c Read verdict(s)**
- Read `verify-verdict.json` (or both `-claude.json` and `-codex.json` if consensus):
  - `pass` + `complete` → write COMPLETE sentinel, report done!
  - `pass` + specific US → add to `verified_us`, Worker does next US
  - `fail` + `continue` → **run Fix Loop** (governance.md §7½):
    1. Read `issues` array, sort by severity (`critical` → `major` → `minor`)
    2. Build structured fix contract with traceability rule
    3. Include `fix_hint` values labeled `(suggestion, non-authoritative)` if present
    4. Include impacted tests from test-spec (so Worker can run them before and after the fix)
    5. Increment `consecutive_failures` in `status.json`
    6. If `consecutive_failures >= 3` for same US → **Architecture Escalation** (governance §7¾): stop fixing, report to user
    7. Go to ⑧ with fix contract as next Worker contract
  - `request_info` → Leader reads Verifier's questions, decides outcome (or relays to Worker in next contract) → go to ⑧
  - `blocked` → write BLOCKED sentinel, stop
- If `--debug`: debug_log `[EXEC] iter=N phase=verdict engine=<engine> verdict=<pass|fail|request_info> us_id=<us_id>`
- If `--debug`: debug_log `[EXEC] iter=N phase=layer_check L1=<status> L2=<status> L3=<status> L4=<status>`
- If `--debug`: debug_log `[EXEC] iter=N phase=sufficiency test_count=<N> ac_count=<N> ratio=<N> verdict=<pass|fail>`
- If `--debug`: debug_log `[EXEC] iter=N phase=checkpoint level=<1|2> evidence=<summary>`
- If `--debug` and consensus: debug_log `[EXEC] iter=N phase=consensus claude=<verdict> codex=<verdict> round=<N>`

**CRITICAL: Immediately proceed to ⑧. Do NOT pause, do NOT ask the user. Continue the loop.**

**⑧ Write result log and report to user, continue loop**
- Write `logs/<slug>/iter-NNN.result.md`:
  - Result status `[leader-measured]`
  - Files changed via `git diff --stat HEAD~1 HEAD` `[git-measured]`
  - Verifier verdict `[leader-measured]`
- Write `status.json`
- Report: iteration N, phase, model used, result
- **Always**: append to baseline.log: `[timestamp] iter=N verdict=<pass|fail|continue> us=<us_id> model=<worker_model>`
- If `--debug`: debug_log `[EXEC] iter=N phase=result status=<result> consecutive_failures=<N> verified_us=<list>`

At loop end (COMPLETE, BLOCKED, or TIMEOUT):
- If `--debug`: debug_log `[VALIDATE] result=<COMPLETE|BLOCKED|TIMEOUT> iterations=<N> verified_us=<list>`

**⑨ Campaign Self-Verification** (when `--with-self-verification` is enabled):

After the loop ends, the Leader performs post-campaign analysis:

1. **Collect data**: Read all archived `iter-NNN.result.md`, done-claim.json (with execution_steps), and verify-verdict.json (with reasoning) from `logs/<slug>/`
2. **Write cumulative data**: `logs/<slug>/self-verification-data.json` — normalized iteration records
3. **Generate versioned report**: `logs/<slug>/self-verification-report-NNN.md` (NNN = auto-increment from existing reports)
4. **Report to user**: Display the full report content

Report template (9 sections):

```
# Campaign Self-Verification Report: <slug>
Report Version: NNN | Generated: timestamp | Campaign: slug — objective
Schema Version: governance hash | Data Quality: N% iterations complete

## 1. Automated Validation Summary
Table: Iter | US | Worker Verdict | Verifier Verdict | Outcome

## 2. Failure Deep Dive (per failed iteration)
Per failure: Worker steps → Verifier reasoning → Root cause → Resolution

## 3. Worker Process Quality (§1f audit)
Table: Iter | US | Steps | verify_red? | RED exit≠0? | verify_green? | Test-First? | E2E? | AC linked?
Aggregate: TDD compliance %, RED confirmation %, E2E evidence %, step completeness %
Audit: each step object must have "step" field with value from §1f vocabulary (write_test, verify_red, implement, verify_green, refactor, verify_e2e, commit, verify) + ac_id + command + exit_code

## 4. Verifier Judgment Quality (§1f audit)
Table: Iter | US | Checks | All Basis? | Independent? | IL-1? | Layer? | Sufficiency? | Anti-Gaming? | Worker Audit?
Aggregate: Reasoning completeness %, Independent verification %, §1f category coverage %
Audit: verify all 5 mandatory check categories (IL-1, Layer Enforcement, Test Sufficiency, Anti-Gaming, Worker Process Audit) are present

## 5. AC Lifecycle
Table: US | AC | First Claimed (iter) | First Verified (iter) | Reopen Count | Final Status

## 6. Test-Spec Adherence
Spec completeness (layers/commands/mappings present)
Spec execution fidelity (exact checks run and cited)

## 7. Patterns: Strengths & Weaknesses
Strengths: what worked well
Weaknesses: systemic issues

## 8. Recommendations for Next Cycle
### Brainstorm (missing scenarios/constraints) — citing iter/AC
### PRD (ambiguous or oversized ACs) — citing iter/AC
### Test-Spec (missing layers, weak mappings) — citing iter/AC

## 9. Blind Spots
What this report CANNOT prove from available data

## Data Provenance Rule
Report content MUST be derivable from: done-claim.json (execution_steps), verify-verdict.json (reasoning),
PRD, and test-spec. Information from source code inspection that is not in these files must be excluded
or explicitly marked as "[source-inspection]" with justification.
```

### Circuit Breaker
- context-latest.md unchanged 3 iterations → BLOCKED
- Same acceptance criterion fails 2 consecutive iterations → upgrade model, retry once, then BLOCKED
- 3 consecutive **fail** verdicts on 3 unique criterion IDs → upgrade to opus, retry once, then BLOCKED
- max_iter reached → TIMEOUT, report to user

Track `consecutive_failures` in `status.json` (increment on `fail`, reset on `pass`, unchanged by `request_info`). Only **fail** verdicts count for CB chains — `request_info` does not break or contribute.

Track `verified_us` (array of US IDs that passed verification) in `status.json` when using `--verify-mode per-us`.

When `--verify-consensus` is enabled, also track in `status.json`:
- `consensus_round`: current consensus round for this US (resets per US)
- `claude_verdict`: latest claude verifier verdict for this US
- `codex_verdict`: latest codex verifier verdict for this US

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
- `.claude/ralph-desk/memos/<slug>-escalation.md`
Note: `logs/<slug>/self-verification-data.json` and `self-verification-report-NNN.md` are intentionally preserved across clean for historical comparison.

If `--kill-session` is passed, also kill any tmux session matching `rlp-desk-<slug>-*`:
```bash
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^rlp-desk-<slug>-" | while read s; do tmux kill-session -t "$s"; done
```

## No args or `help`
```
/rlp-desk brainstorm <description>          Plan before init (interactive)
/rlp-desk init  <slug> [objective]          Create project scaffold
/rlp-desk run   <slug> [options]            Run loop (agent=LLM leader, tmux=shell leader)
/rlp-desk status <slug>                     Show loop status
/rlp-desk logs  <slug> [N]                  Show iteration log
/rlp-desk clean <slug> [--kill-session]     Reset for re-run (--kill-session kills tmux)

Run options:
  --mode agent|tmux          Execution mode (default: agent)
  --max-iter N               Max iterations (default: 100)
  --worker-model MODEL       Worker model (default: sonnet)
  --verifier-model MODEL     Verifier model (default: opus)
  --worker-engine claude|codex   Worker engine (default: claude)
  --verifier-engine claude|codex Verifier engine (default: claude)
  --worker-codex-model MODEL          Worker codex model (default: gpt-5.4)
  --worker-codex-reasoning LEVEL      Worker codex reasoning (default: high)
  --verifier-codex-model MODEL        Verifier codex model (default: gpt-5.4)
  --verifier-codex-reasoning LEVEL    Verifier codex reasoning (default: high)
  --verify-mode per-us|batch Verification strategy (default: per-us)
  --verify-consensus         Cross-engine consensus verification
  --consensus-scope SCOPE    When consensus runs: all|final-only (default: all)
  --debug                    Debug logging (logs/<slug>/debug.log)
  --with-self-verification   Campaign self-verification analysis (post-loop report)
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
