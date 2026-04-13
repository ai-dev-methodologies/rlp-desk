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
2.5. **Codebase Exploration** — Before proposing user stories, examine the project:
   - Read the project's entry points, key modules, and test structure
   - Identify architectural patterns in use (frameworks, conventions, test setup)
   - Note constraints the Worker will encounter (dependencies, build system, existing code style)
   - Present findings: "I explored the codebase and found: [patterns], [constraints], [existing tests]. This informs the US breakdown below."
   - If the project is new/empty, skip this step and note "greenfield project."
3. **User Stories** — discrete units with testable acceptance criteria. Propose a breakdown, ask the user to confirm/modify.
   - Apply INVEST criteria: each US must be Independent, Negotiable, Valuable, Estimable, Small, Testable.
   - **Task Sizing (governance §1c)**: Size each US within the Worker's comfortable zone — smaller than what the Worker can handle, not at its ceiling. Max 3-4 ACs, max 2 files. If a US feels "just barely doable" for the target model, split it further.
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
7. **Worker / Verifier Model** — Evaluate PRD complexity using 5 factors (overall = highest factor), then recommend model.

   **Complexity Evaluation Table**:

   | Factor | LOW | MEDIUM | HIGH | CRITICAL |
   |--------|-----|--------|------|----------|
   | US count | 1-2 | 3-5 | 6-10 | 10+ |
   | File change scope | single | 2-5 files | 6+ files | cross-repo |
   | Logic complexity | simple | conditionals | algorithms | security |
   | External dependencies | none | 1-2 | 3+ | distributed |
   | Existing code impact | new only | modify | refactor | architecture |

   **Codex Detection** — check if codex CLI is installed (`command -v codex`).

   **Model mapping — Claude-only** (codex not installed):

   | Complexity | Worker | per-US Verifier | Final Verifier | Consensus |
   |------------|--------|-----------------|----------------|-----------|
   | LOW | haiku | sonnet | opus | off |
   | MEDIUM | sonnet | opus | opus | off |
   | HIGH | opus | opus | opus | off |
   | CRITICAL | opus | opus | opus + human | off |

   **Model mapping — Cross-engine** (codex installed, recommended):

   | Complexity | Worker | per-US Verifier | Final Verifier | Consensus |
   |------------|--------|-----------------|----------------|-----------|
   | LOW | gpt-5.4:medium | sonnet | opus | final-only |
   | MEDIUM | gpt-5.4:medium | opus | opus | final-only |
   | HIGH | gpt-5.4:high | opus | opus | all |
   | CRITICAL | gpt-5.4:high | opus | opus + human | all |

   **Worker model selection** (cross-engine):
   - **gpt-5.4:medium** — default recommendation (full context window, progressive upgrade handles harder US)
   - **spark:high** — only when US is small enough for spark's 100k context (single-file, AC count <= 4, simple logic). Do NOT use as primary recommendation — spark context window is too small for most tasks

   Present complexity score with evidence to the user, e.g.: "I rate this MEDIUM because: US count=4 (MEDIUM), file scope=2 (MEDIUM), logic=conditionals (MEDIUM), deps=none (LOW), impact=modify (MEDIUM). Highest=MEDIUM."

   **If codex IS installed** — say: "Codex is installed. I recommend cross-engine Worker for cost savings (Pro token pool separation) and cross-engine blind-spot coverage (claude Verifier catches issues codex Worker misses)."

   **If codex is NOT installed** — say: "Codex is not installed. Defaulting to claude-only Worker. Note: without a second engine, your Verifier shares the same perspective as the Worker — there is a risk of blind spots where both Worker and Verifier miss the same issue. To unlock cross-engine coverage: `npm install -g @openai/codex`"

8. **Batch Capacity Check** — when verify-mode is batch and PRD is large:
   - batch + spark + AC > 4 → warn "spark 100k context limit — switch to gpt-5.4 or split smaller"
   - batch + gpt-5.4 + AC > 15 → warn "too many ACs for single batch — consider wave split (3-4 US per wave)"
   - per-us → no warning (US-level processing, no limit concern)
9. **Verify Mode** — per-us (default) or batch. Ask: "Verify after each user story (per-us, recommended) or only after all stories are done (batch)?" Default recommendation: per-us for 2+ stories.
10. **Consensus** — Ask: "Use cross-engine consensus? off (single engine), final-only (cross-engine on final verify only), or all (cross-engine on every verify). Requires codex CLI." Default: off. Recommended: final-only when codex is installed.
11. **Max Iterations** — suggest based on story count, ask if OK.
12. **Operational Context** — Auto-detect: scan project root for `package.json` (scripts.dev/start), `Makefile`, `docker-compose.yml`, `manage.py`. If detected, ask:
   - "Does this project require a running server/service during development?" (y/n)
   - If yes: "Server start command?" (pre-fill from detected scripts, e.g., `npm run dev`)
   - "Server port?" (e.g., 7001)
   - "Health check URL?" (e.g., `http://localhost:7001/health`) — optional
   - Pass to init: `--server-cmd "CMD" --server-port PORT --server-health URL`
   - If no server needed: skip. Init generates prompts without operational context.

   **US generation guidance when server context is present:**
   - Each US that modifies server/application code SHOULD include an AC or note:
     "Given server is running, When code is modified, Then server is restarted and health check passes"
   - Do NOT assume the Worker model will restart servers on its own — spell it out in the AC or rely on the operational rules injected by init.

After all items are confirmed:

0. **SV Report Feedback** — If a prior campaign's self-verification report exists:
   a. Scan `~/.claude/ralph-desk/analytics/` for directories matching this project (by slug or project root)
   b. Read the latest `self-verification-report.md` from each matching directory
   c. Extract from §7 (Patterns) and §8 (Recommendations):
      - Which US types/sizes failed most frequently
      - Which AC quality dimensions scored lowest
      - Which model tiers underperformed for this project's complexity
      - Specific brainstorm/PRD/test-spec recommendations from prior campaigns
   d. Present findings to user: "Prior campaign analysis found: [patterns]. Recommendations: [suggestions]."
   e. If no prior reports exist, skip and note "No prior campaign data available."
   (governance §8½)
1. **Ambiguity Gate (IL-2)** — score each AC per governance §1a IL-2 (6 dimensions, 0-12 points).
   If ANY AC scores below 6: **REJECT** — refine that AC before proceeding.
   If all ACs score 6-9: **WARN** — proceed with logged warning, show low-scoring dimensions.
   If all ACs score 10-12: **PASS** — clean.
   Present the score table to the user before proceeding.
2. Present the full contract summary.
3. **Self-Verification** — Ask: "Enable self-verification? Worker records step-by-step evidence, Verifier cross-validates process. Recommended for MEDIUM+ risk." Default: yes for HIGH/CRITICAL, no for LOW/MEDIUM.
4. **Re-execution check**: After slug is confirmed, check if `.claude/ralph-desk/plans/prd-<slug>.md` already exists. If a PRD already exists for this slug, ask: "A PRD already exists for this slug. Improve the existing PRD or start fresh (delete and recreate)?"
   - "improve" → pass `--mode improve` to init
   - "start fresh" → pass `--mode fresh` to init
   - If no PRD exists: standard first-run (no --mode needed)
5. On approval, offer to run `init`.

Do NOT create files during brainstorm.
Do NOT auto-decide iteration unit — the user MUST explicitly choose.

---

## `init <slug> [objective]`

Run: `~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>" [--mode fresh|improve]`
If brainstorm was done, auto-fill:
- PRD and test-spec with the brainstorm results
- Campaign memory "Key Decisions" with architectural decisions from brainstorm
- Campaign memory "Patterns Discovered" with codebase exploration findings (from step 2.5)

**After init completes, STOP. Do NOT auto-run the loop.**

Tell the user:
1. The scaffold has been created — list the generated files
2. Ask them to review/edit the PRD and test-spec if needed
3. Present run options with explanations and ONE recommendation. The user MUST copy and paste the command themselves.

   Check if codex CLI is installed: run `command -v codex` in shell or check if the binary exists.

   **If codex IS installed** — show cross-engine presets first:

   ```
   Available run commands (copy the one you want):

   # ★ Recommended: cross-engine + final-consensus (full context + blind-spot coverage):
   /rlp-desk run <actual-slug> --mode tmux --worker-model gpt-5.4:medium --consensus final-only --debug

   # Small tasks only (single-file, AC <= 4, simple logic — spark 100k context limit):
   /rlp-desk run <actual-slug> --mode tmux --worker-model spark:high --consensus final-only --debug

   # Critical (full consensus on every verify):
   /rlp-desk run <actual-slug> --mode tmux --worker-model gpt-5.4:high --consensus all --debug

   # Claude-only:
   /rlp-desk run <actual-slug> --debug

   # Full options reference:
   #   --mode agent|tmux                      (default: agent)
   #   --worker-model MODEL                   haiku|sonnet|opus or gpt-5.4:high|spark:high (default: haiku)
   #   --lock-worker-model                    disable auto model upgrade
   #   --verifier-model MODEL                 per-US verifier (default: sonnet)
   #   --final-verifier-model MODEL           final ALL verifier (default: opus)
   #   --consensus off|all|final-only         cross-engine consensus (default: off)
   #   --consensus-model MODEL                per-US cross-verifier (default: gpt-5.4:medium)
   #   --final-consensus-model MODEL          final cross-verifier (default: gpt-5.4:high)
   #   --verify-mode per-us|batch             (default: per-us)
   #   --cb-threshold N                       (default: 6)
   #   --max-iter N                           (default: 100)
   #   --iter-timeout N                       tmux only (default: 600)
   #   --debug                                debug logging
   #   --with-self-verification               post-campaign SV report
   #   --flywheel off|on-fail                 direction review on fail (default: off)
   #   --flywheel-model MODEL                 flywheel reviewer model (default: opus)
   ```

   **If codex is NOT installed** — show claude-only presets + install recommendation:

   ```
   Available run commands (copy the one you want):

   # ★ Recommended: tmux mode + claude-only (real-time visibility):
   /rlp-desk run <actual-slug> --mode tmux --debug

   # Agent mode:
   /rlp-desk run <actual-slug> --debug

   # Install codex for cost savings + cross-engine blind-spot coverage:
   npm install -g @openai/codex

   # Full options reference:
   #   --mode agent|tmux                      (default: agent)
   #   --worker-model MODEL                   haiku|sonnet|opus (default: haiku)
   #   --lock-worker-model                    disable auto model upgrade
   #   --verifier-model MODEL                 per-US verifier (default: sonnet)
   #   --final-verifier-model MODEL           final ALL verifier (default: opus)
   #   --verify-mode per-us|batch             (default: per-us)
   #   --cb-threshold N                       (default: 6)
   #   --max-iter N                           (default: 100)
   #   --iter-timeout N                       tmux only (default: 600)
   #   --debug                                debug logging
   #   --with-self-verification               post-campaign SV report
   #   --flywheel off|on-fail                 direction review on fail (default: off)
   #   --flywheel-model MODEL                 flywheel reviewer model (default: opus)
   ```

   Replace `<actual-slug>` with the real slug from this init (e.g. `auth-refactor`).

**CRITICAL: Do NOT offer to run for the user. Do NOT ask "shall I run?" or offer to execute. The user MUST type the run command themselves. Just present the options, recommend one, and STOP.**

---

## `run <slug> [options]`

**YOU are the leader. Do NOT delegate leadership.**

Options (parse from `$ARGUMENTS`):
- `--mode agent|tmux` (default: `agent`) — execution mode
- `--worker-model MODEL` (default: `haiku`) — Worker model. Format: `model` = claude engine, `model:reasoning` = codex engine. Examples: `haiku`, `sonnet`, `opus`, `spark:high`, `gpt-5.4:high`. Parsed by `parse_model_flag()` which auto-splits engine/model/reasoning.
- `--lock-worker-model` — disable automatic model upgrade on failure (check_model_upgrade). Worker stays on the specified model regardless of consecutive failures.
- `--verifier-model MODEL` (default: `sonnet`) — per-US verification model. Campaign-fixed (no progressive upgrade). Lighter than final verifier.
- `--final-verifier-model MODEL` (default: `opus`) — final ALL verification model. Independent from per-US verifier. Used only for the final full-AC verify pass.
- `--consensus off|all|final-only` (default: `off`) — cross-engine consensus verification mode.
  - `off`: single-engine verification only
  - `all`: cross-engine consensus on every verify (per-US and final)
  - `final-only`: cross-engine consensus only on the final ALL verify
- `--consensus-model MODEL` (default: `gpt-5.4:medium`) — per-US cross-verifier model. Lighter weight for cost efficiency.
- `--final-consensus-model MODEL` (default: `gpt-5.4:high`) — final cross-verifier model. Stricter. Note: spark is not allowed here (100k output limit).
- `--verify-mode per-us|batch` (default: `per-us`) — verification strategy
  - `per-us`: verify after each US, then final full verify of all AC
  - `batch`: verify only after all US done (legacy behavior)
- `--cb-threshold N` — circuit breaker threshold: consecutive failures before BLOCKED (default: 6). When `--consensus` is not `off`, effective threshold is automatically doubled (e.g., default becomes 12).
- `--max-iter N` (default: 100)
- `--iter-timeout N` — per-iteration timeout in seconds (default: 600). Enforced in tmux mode only. Agent mode: not enforced (Agent() has no timeout API).
- `--debug` — enable debug logging (writes to ~/.claude/ralph-desk/analytics/<slug>/debug.log)
- `--with-self-verification` — enable campaign-level self-verification analysis. After COMPLETE, Leader analyzes all iteration records (done-claims + verdicts) and generates a campaign self-verification summary with patterns and recommendations for next planning cycle. (Note: execution_steps and reasoning are ALWAYS recorded per governance §1f — this flag adds post-campaign analysis.)

### Analytics Directory (`~/.claude/ralph-desk/analytics/<slug>/`)
When `--debug` or `--with-self-verification` is active, analytics data is written to a user-level directory for cross-project aggregation. Contents:
- `metadata.json` — campaign metadata: slug, project_root, campaign_status, start_time, end_time
- `debug.log` — debug output (versioned: `debug-v{N}.log` on re-execution)
- `campaign.jsonl` — per-iteration structured data (versioned: `campaign-v{N}.jsonl` on re-execution). Schema: iter, us_id, worker_model, worker_engine, verifier_model, verifier_engine, consensus_mode, claude_verdict, codex_verdict, duration_worker_s, duration_verifier_s, project_root, slug, timestamp
- `self-verification-data.json` — cumulative SV records (agent-mode only, when `--with-self-verification`)
- `self-verification-report-NNN.md` — versioned SV reports (when `--with-self-verification`)

Cross-project aggregation: scan `~/.claude/ralph-desk/analytics/` and read each slug's `metadata.json` to discover project_root, campaign_status, and timestamps. Slug directories use `<slug>--<root_hash>` format to prevent collision across projects.

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
LOCK_WORKER_MODEL=<1 if --lock-worker-model, else 0> \
VERIFIER_MODEL=<--verifier-model value, default: sonnet> \
FINAL_VERIFIER_MODEL=<--final-verifier-model value, default: opus> \
VERIFY_MODE=<--verify-mode value, default: per-us> \
CONSENSUS_MODE=<--consensus value, default: off> \
CONSENSUS_MODEL=<--consensus-model value, default: gpt-5.4:medium> \
FINAL_CONSENSUS_MODEL=<--final-consensus-model value, default: gpt-5.4:high> \
CB_THRESHOLD=<--cb-threshold value, default: 6> \
ITER_TIMEOUT=<--iter-timeout value, default: 600> \
DEBUG=<1 if --debug, else 0> \
WITH_SELF_VERIFICATION=<1 if --with-self-verification, else 0> \
  zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
```
6. **If the script exits with error (exit code 1)** — report the error to the user and STOP. Do NOT attempt to work around it. Do NOT create tmux sessions yourself. Do NOT re-launch the script in a different way. Just tell the user what went wrong and suggest using Agent mode instead.
7. **If successful** — tell the user the tmux session has been started. The shell script takes over as the deterministic Leader. No Agent() calls are made in tmux mode.

**IMPORTANT RULES:**
- Tmux mode requires the user to already be inside a tmux session. If the runner script rejects because $TMUX is not set, do NOT try to create a tmux session yourself. Tell the user: "Start tmux first, then retry."
- MUST launch the runner with `run_in_background: true` so `/rlp-desk` returns control immediately while preserving live tmux visibility.
- Run-in-background is used so the shell can keep the command visible and keep the pane layout stable for status checks and completion flow.
- Do NOT kill panes after completion. Panes stay alive for inspection. User cleans up with `/rlp-desk clean <slug> --kill-session`.
- `--with-self-verification` is accepted in tmux mode. After campaign completion, `run_ralph_desk.zsh` spawns `claude CLI` to generate the SV report from campaign artifacts (done-claims, verify-verdicts, campaign-report). SV reports are written to `~/.claude/ralph-desk/analytics/<slug>/`. Requires `claude` CLI available in PATH; if not found, an error is appended to the campaign report.

**tmux UX model (5 items):**
- The session returns immediately after launch (`run_in_background: true`) so the command returns control to the parent CLI.
- Worker/Verifier panes remain visible to the user during execution.
- Users check progress with the **status command**: `/rlp-desk status <slug>`.
- On completion, the command returns a completion notification before the loop ends.
- Agent mode remains unchanged, and no tmux-specific behavior is mixed into Agent mode.

#### Agent Mode (`--mode agent` or default)

### Preparation
1. Validate scaffold: `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` etc.
2. **Codex CLI pre-validation**: If `--consensus` is not `off` OR `--worker-model` uses codex format (contains `:`) OR `--verifier-model` / `--final-verifier-model` / `--consensus-model` / `--final-consensus-model` uses codex format, check that `codex` CLI exists in PATH. If codex CLI not found → STOP immediately, print install instructions (`npm install -g @openai/codex`), do not start the loop.
3. Check sentinels (complete/blocked). Found → tell user `/rlp-desk clean <slug>`.
4. Clean previous `done-claim.json`, `verify-verdict.json`.
5. **Always**: write baseline log entry to `.claude/ralph-desk/logs/<slug>/baseline.log`: `[timestamp] iter=0 phase=start slug=<slug> worker_model=<model> verifier_model=<model>`. Baseline.log captures 1 line per iteration for lightweight post-mortem (always-on, no flag needed).
6. If `--debug`: also create/clear `~/.claude/ralph-desk/analytics/<slug>/debug.log`. Define a helper: to "debug_log" means append a timestamped line to this file via `Bash("echo \"[$(date '+%Y-%m-%d %H:%M:%S')] $msg\" >> ~/.claude/ralph-desk/analytics/<slug>/debug.log")`. When `--debug` is active, debug.log contains all baseline.log fields plus detailed phase logs.
   - **4-category log system**: all debug_log entries use exactly one of: `[GOV]` (governance checks: IL enforcement, CB triggers, scope lock, verdict evaluation), `[DECIDE]` (leader decisions: model selection, fix contracts, escalation), `[OPTION]` (configuration snapshot at loop start: thresholds, modes, models), `[FLOW]` (execution progress: worker/verifier dispatch, signal reads, phase transitions)
   - **Re-execution versioning**: If `debug.log` already exists at `--debug` start, rename it to `debug-v{N}.log` (N = next available integer ≥ 1) before creating a fresh `debug.log`.
   - **baseline.log lifecycle**: baseline.log is deleted on re-execution (when `init --mode improve` or `init --mode fresh` is run).
7. Capture baseline commit: `Bash("git rev-parse HEAD 2>/dev/null || echo none")` → store as `BASELINE_COMMIT`. Include in the first `status.json` write as `baseline_commit` field.

### Leader Loop

**CRITICAL: DO NOT STOP between iterations.** You MUST continue the loop automatically until a sentinel is written (COMPLETE or BLOCKED) or max_iter is reached. Do NOT pause to ask the user. Do NOT wait for confirmation. The loop is fully autonomous.

**PLATFORM CONSTRAINT (Agent mode):** In Agent mode, the Leader is an LLM in Claude Code's turn-based model. A turn ENDS when the response contains no tool calls. This means:
- **NEVER output plain text without an accompanying tool call.** Text-only output = turn ends = loop stops.
- **Use `Bash("echo '...'")` for all status reports** instead of plain text. This keeps the tool-call chain alive.
- **After every step result, IMMEDIATELY start the next step's tool call in the SAME response.** For example, after reading the verdict (⑦c), report via Bash("echo") AND start ⑧'s tool calls in one response.
- If you output "Iter 1 complete, moving to iter 2" as plain text without a tool call, the turn terminates and the loop breaks. This is a platform constraint, not a compliance issue — no amount of "DO NOT STOP" text can override it.

If `--debug`, at loop start debug_log the following (3 [OPTION] entries):
- `[OPTION] slug=<slug> max_iter=<N> verify_mode=<mode> consensus_mode=<off|all|final-only>`
- `[OPTION] cb_threshold=<N> effective_cb_threshold=<N> lock_worker_model=<0|1>`
- `[OPTION] worker_model=<model> verifier_model=<model> final_verifier_model=<model> consensus_model=<model> final_consensus_model=<model>`

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
- If `--debug`: debug_log `[FLOW] iter=N phase=read_memory stop_status=<status> contract="<summary>"`

**③ Decide model** (§4 of governance.md)
- Previous iteration failed → upgrade model
- Simple task → downgrade
- User specified → use that
- If `--debug`: debug_log `[DECIDE] iter=N phase=model_select worker_model=<model> reason=<reason>`

**④ Build worker prompt (Prompt Assembly Protocol)**
1. Capture `WORKING_DIR` once: use `$PWD` from when `/rlp-desk run` was invoked. Store for all prompt construction.
2. Read `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` — use its content **verbatim**. Do NOT rewrite, paraphrase, or regenerate paths. The prompt file contains correct absolute paths from init.
2a. **Per-US PRD injection** (when targeting a specific `us_id`, not "ALL"):
   - Check if `.claude/ralph-desk/plans/prd-<slug>-{us_id}.md` exists (created by init split)
   - If yes: in the assembled prompt text, replace the full PRD reference (`prd-<slug>.md`) with the per-US file path (`prd-<slug>-{us_id}.md`) — so Worker reads only the relevant US section
   - If no per-US file: fall back to full PRD (`prd-<slug>.md`) with no change needed
   - Note: this absolute-path substitution is permitted — only absolute→relative rewrites are forbidden.
3. Prepend meta comment: `## WORKING_DIR: {absolute path}` — Worker must use this as its working directory.
4. Append iteration number + memory contract.
5. Write to `.claude/ralph-desk/logs/<slug>/iter-NNN.worker-prompt.md` (audit trail).
- Note: Worker ALWAYS records execution_steps in done-claim.json per governance §1f. No flag needed.
- **Rewriting paths from absolute to relative WILL break worktree campaigns. Only additions (WORKING_DIR header, iteration context) are allowed.**

**④½ Contract review** (agent mode only)
- Before dispatching Worker, spawn a lightweight review: "Is this iteration contract sufficient to achieve the US's AC? Any missing steps?"
- If `--debug`: debug_log `[GOV] iter=N phase=contract_review scope_lock=<us_id|null> ac_count=<N> result=<ok|issues>`
- In tmux mode: skip (shell leader cannot reason). Log: `[FLOW] iter=N phase=contract_review skipped=tmux_mode`

**⑤ Execute Worker**
- If `--debug`: debug_log `[FLOW] iter=N phase=worker engine=<engine> model=<model> dispatched=true`

Determine engine from `--worker-model` format: plain name (e.g., `haiku`) = claude engine, `model:reasoning` format (e.g., `spark:high`) = codex engine. Use `parse_model_flag()` to split.

If claude engine (default):
```
Agent(
  description="rlp-desk worker iter-NNN",
  model=<worker_model>,
  mode="bypassPermissions",
  prompt=<full worker prompt text>
)
```
- Agent returns synchronously. No polling needed.
- Each Agent() = fresh context. Guaranteed.

If codex engine:
```
Bash("codex exec --model <codex_model> --reasoning-effort <codex_reasoning> <full worker prompt text>")
```
- Codex runs as a subprocess via Bash(), not Agent().
- Each Bash() call = fresh context for codex.


**⑥ Read memory.md again** (Worker updated it)
- `stop=continue` → go to ⑧
- `stop=verify` → go to ⑦
- `stop=blocked` → write BLOCKED sentinel, stop
- Also read `iter-signal.json` for `us_id` field (which US was just completed)
- If `--debug`: debug_log `[FLOW] iter=N phase=worker_done_signal engine=<engine> status=<stop_status> us_id=<us_id>`

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
  - **Sequential final verify** (timeout prevention): Instead of one big ALL verify, loop through each US individually with scoped verifier. After all per-US pass, run the project's test suite as a cross-US integration check. Only COMPLETE if both per-US checks and integration check pass.
  - After sequential final verify passes → COMPLETE

**Batch mode** (`--verify-mode batch`):
- Legacy behavior: verify only when Worker signals all work is done
- Verifier checks all AC at once

**⑦a Dispatch Verifier**
- Note: Verifier ALWAYS records reasoning in verify-verdict.json per governance §1f. No flag needed.
- **Prompt Assembly Protocol (same as ④)**: Read verifier prompt file verbatim. Prepend `## WORKING_DIR: {absolute path}`. Do NOT rewrite paths.
- If `--debug`: debug_log `[FLOW] iter=N phase=verifier engine=<engine> model=<model> scope=<us_id> dispatched=true`

Determine which verifier model to use based on scope:
- If `us_id` is a specific story (per-US verify) → use `--verifier-model` (default: sonnet)
- If `us_id` is "ALL" (final verify) → use `--final-verifier-model` (default: opus)

Determine engine from the selected verifier model format (same as Worker): plain name = claude, `model:reasoning` = codex.

If claude engine (default):
```
Agent(
  description="rlp-desk verifier iter-NNN (us_id)",
  model=<selected_verifier_model>,
  mode="bypassPermissions",
  prompt=<full verifier prompt text with US scope>
)
```

If codex engine:
```
Bash("codex exec --model <codex_model> --reasoning-effort <codex_reasoning> <full verifier prompt text>")
```

**⑦b Consensus Verification** (when `--consensus` is `all`, or `final-only` and scope is ALL):
After the primary verifier runs, run a cross-engine second verifier:
- Determine cross-verifier model based on scope:
  - per-US verify → use `--consensus-model` (default: gpt-5.4:medium)
  - final ALL verify → use `--final-consensus-model` (default: gpt-5.4:high)
- If primary engine is claude → cross-verifier uses codex (the consensus model)
- If primary engine is codex → cross-verifier uses claude `opus` (fixed)
- Both produce `verify-verdict.json` (Leader renames to `verify-verdict-claude.json` and `verify-verdict-codex.json`)
- **Both pass** → proceed (next US or COMPLETE)
- **Either fails** → combine issues from both verdicts into a single fix contract → Worker retry
- Max 6 consensus rounds per US. After 6 rounds → BLOCKED.

**NO ENGINE PRIORITY (ABSOLUTE):** There is no primary or secondary engine. Claude and Codex have EQUAL weight. If one passes and the other fails, the verdict is FAIL — always. The Leader MUST NOT override, prioritize, or dismiss either engine's verdict. "Claude priority", "primary engine override", "infrastructure failure" (when a valid verdict file exists), or any similar rationalization = governance violation. Infrastructure failure means ONLY: CLI crash (exit ≠ 0), timeout, or verdict file not generated.

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
    6. If `consecutive_failures >= cb_threshold` for same US → **Architecture Escalation** (governance §7¾): stop fixing, report to user
       - If `--debug`: debug_log `[GOV] iter=N phase=CB_trigger consecutive_failures=<N> us_id=<us_id> action=architecture_escalation`
    7. Go to ⑧ with fix contract as next Worker contract
  - `request_info` → Leader reads Verifier's questions, decides outcome (or relays to Worker in next contract) → go to ⑧
  - `blocked` → write BLOCKED sentinel, stop
- If `--debug`: debug_log `[GOV] iter=N phase=verdict engine=<engine> verdict=<pass|fail|request_info> us_id=<us_id> L1=<status> L2=<status> L3=<status> L4=<status>`
- If `--debug`: debug_log `[GOV] iter=N phase=sufficiency test_count=<N> ac_count=<N> ratio=<N> verdict=<pass|fail>`

**⑦d Archive iteration artifacts** (always — independent of --debug)
After reading the verdict, archive to `logs/<slug>/`:
- `iter-NNN-done-claim.json` ← copy from `memos/<slug>-done-claim.json`
- `iter-NNN-verify-verdict.json` ← copy from `memos/<slug>-verify-verdict.json`
(Preserved across clean; data source for campaign report generation and SV analysis.)

**CRITICAL: Immediately proceed to ⑧. Do NOT pause, do NOT ask the user. Continue the loop.**

**⑧ Write result log and report to user, continue loop**
- Write `logs/<slug>/iter-NNN.result.md`:
  - Result status `[leader-measured]`
  - Files changed: cumulative working tree state via `git diff --stat HEAD` `[git-measured]` (note: cumulative in tmux mode, not per-iteration delta)
  - Verifier verdict `[leader-measured]`
- **Record cost & performance per iteration**:
  - Agent mode: record `total_tokens` and `duration_ms` from Agent() return metadata for both Worker and Verifier
  - Tmux mode: record `duration_seconds` from shell timing. Estimate tokens from file sizes: `(prompt_bytes + done_claim_bytes + verdict_bytes) / 4` — label as "estimated"
  - Write to `status.json`: `{"iter_N": {"worker_tokens": N, "worker_duration_ms": N, "verifier_tokens": N, "verifier_duration_ms": N, "token_source": "measured|estimated"}}`
- Write `status.json`
- Report via tool call: `Bash("echo 'Iter N | US-NNN | verdict | model | next_action'")` — NEVER plain text. This keeps the turn alive for the next iteration.
- **Always**: append to baseline.log: `[timestamp] iter=N verdict=<pass|fail|continue> us=<us_id> model=<worker_model>`
- **Always**: append JSONL to `~/.claude/ralph-desk/analytics/<slug>/campaign.jsonl`: `{"iter":N,"us_id":"US-NNN","verdict":"pass|fail","worker_model":"...","worker_engine":"...","verifier_model":"...","verifier_engine":"...","consensus_mode":"off|all|final-only","duration_worker_s":N,"duration_verifier_s":N,"timestamp":"ISO8601"}`
- If `--debug`: debug_log `[FLOW] iter=N phase=result status=<result> consecutive_failures=<N> verified_us=<list>`

At loop end (COMPLETE, BLOCKED, or TIMEOUT):
- If `--debug`: debug_log `[FLOW] result=<COMPLETE|BLOCKED|TIMEOUT> iterations=<N> verified_us=<list>`

**⑨ Campaign Self-Verification** (when `--with-self-verification` is enabled):

After the loop ends, the Leader performs post-campaign analysis:

1. **Collect data**: Read all archived `iter-NNN.result.md`, done-claim.json (with execution_steps), and verify-verdict.json (with reasoning) from `logs/<slug>/`
2. **Write cumulative data**: `~/.claude/ralph-desk/analytics/<slug>/self-verification-data.json` — normalized iteration records (agent-mode only artifact)
3. **Generate versioned report**: `~/.claude/ralph-desk/analytics/<slug>/self-verification-report-NNN.md` (NNN = auto-increment from existing reports)
4. **Report to user**: Display the full report content

Report template (10 sections):

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

## 9. Cost & Performance
Table: Iter | Role | Model | Tokens | Duration | Source
Aggregate: total Worker tokens, total Verifier tokens, total campaign tokens, total duration
Source: "measured" (Agent mode) or "estimated" (Tmux mode, from file sizes / 4)

## 10. Blind Spots
What this report CANNOT prove from available data

## Data Provenance Rule
Report content MUST be derivable from: done-claim.json (execution_steps), verify-verdict.json (reasoning),
PRD, and test-spec. Information from source code inspection that is not in these files must be excluded
or explicitly marked as "[source-inspection]" with justification.
```

**⑩ Campaign Report** (always — independent of `--debug` and `--with-self-verification`)

After the loop ends (COMPLETE, BLOCKED, or TIMEOUT), generate `logs/<slug>/campaign-report.md`:

1. If `campaign-report.md` already exists, rename it to `campaign-report-v{N}.md` (N = next available integer ≥ 1) before writing new.
2. Generate report with 8 required sections:
   - **Objective**: From PRD
   - **Execution Summary**: Iterations run, terminal state (COMPLETE/BLOCKED/TIMEOUT), elapsed time
   - **US Status**: Each US with final verified/failed/pending status (from `status.json`)
   - **Verification Results**: Per-US and final verify outcomes (from archived iter artifacts)
   - **Issues Encountered**: Fix contracts and failure verdicts from campaign
   - **Cost & Performance**: Per-iter token/duration data from `status.json`
   - **SV Summary**: If `--with-self-verification` ran, pointer to SV report file; otherwise "N/A — --with-self-verification not enabled"
   - **Files Changed**: `git diff --stat <baseline_commit>` (working tree vs baseline, includes uncommitted changes and untracked files). Note: may include pre-existing uncommitted changes if the campaign started in a dirty worktree.
3. Data sources: `status.json` (baseline_commit, per-iter data), archived `iter-NNN-done-claim.json` / `iter-NNN-verify-verdict.json`, PRD, git diff.
4. If `--with-self-verification` was enabled: ⑨ SV report runs first, then ⑩ Campaign Report (which includes the SV Summary section pointing to the SV report file).

### Circuit Breaker
- context-latest.md unchanged 3 iterations → BLOCKED
- Same acceptance criterion fails 2 consecutive iterations → upgrade model, retry once, then BLOCKED
- 3 consecutive **fail** verdicts on 3 unique criterion IDs → upgrade to opus, retry once, then BLOCKED
- max_iter reached → TIMEOUT, report to user

Track `consecutive_failures` in `status.json` (increment on `fail`, reset on `pass`, unchanged by `request_info`). Only **fail** verdicts count for CB chains — `request_info` does not break or contribute.

Track `verified_us` (array of US IDs that passed verification) in `status.json` when using `--verify-mode per-us`.

When `--consensus` is not `off`, also track in `status.json`:
- `consensus_round`: current consensus round for this US (resets per US)
- `claude_verdict`: latest claude verifier verdict for this US
- `codex_verdict`: latest codex verifier verdict for this US

### Important Rules
- Each Agent() = new process = fresh context
- YOU track iteration count
- Write `status.json` after each iteration
- Worker claim ≠ complete. Only YOU write COMPLETE sentinel after verifier pass.
- **NEVER modify rlp-desk infrastructure files** (`~/.claude/ralph-desk/*`, `~/.claude/commands/rlp-desk.md`). If you or a Worker/Verifier discovers a bug in rlp-desk itself, write BLOCKED sentinel with reason `"rlp-desk bug: <description>"` and STOP. Do NOT attempt to fix rlp-desk — report the bug to the user.

---

## `status <slug>`
Read `.claude/ralph-desk/logs/<slug>/runtime/status.json` and display a detailed report:

```
Campaign: <slug>
Iteration: <iteration> / <max_iter>
Phase: <phase> | Last Result: <last_result>
Worker Model: <worker_model> | Verifier: <verifier_model> (per-US) / <final_verifier_model> (final)
Verify Mode: <verify_mode> | Consensus: <consensus_mode>
Consecutive Failures: <consecutive_failures>
Verified US: <verified_us array, comma-separated>
Updated: <updated_at_utc> (elapsed: now - updated_at)
```

If `status.json` does not exist, display "No active campaign for <slug>."
If the campaign has a `complete` or `blocked` sentinel, show that status prominently.
Read the last `verify-verdict.json` to show the most recent verdict summary and any failure issues.

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
- `.claude/ralph-desk/logs/<slug>/runtime/session-config.json`
- `.claude/ralph-desk/logs/<slug>/runtime/worker-heartbeat.json`
- `.claude/ralph-desk/logs/<slug>/runtime/verifier-heartbeat.json`
- `.claude/ralph-desk/memos/<slug>-escalation.md`
Note: `campaign-report.md`, `campaign-report-v{N}.md`, `iter-NNN-done-claim.json`, and `iter-NNN-verify-verdict.json` are intentionally preserved across clean for historical comparison. Analytics files (`debug.log`, `campaign.jsonl`, `self-verification-data.json`, `self-verification-report-NNN.md`) at `~/.claude/ralph-desk/analytics/<slug>/` are NOT affected by project-level clean.

If `--kill-session` is passed, clean up Worker/Verifier tmux panes using session-config.json:
```bash
# Read pane IDs from session-config.json (safe — targets only Worker/Verifier panes)
SESSION_CONFIG=".claude/ralph-desk/logs/<slug>/runtime/session-config.json"
if [ -f "$SESSION_CONFIG" ] && command -v jq &>/dev/null; then
  WORKER_PANE=$(jq -r '.panes.worker // empty' "$SESSION_CONFIG")
  VERIFIER_PANE=$(jq -r '.panes.verifier // empty' "$SESSION_CONFIG")

  for pane_id in "$WORKER_PANE" "$VERIFIER_PANE"; do
    if [ -n "$pane_id" ]; then
      tmux send-keys -t "$pane_id" C-c 2>/dev/null
      tmux send-keys -t "$pane_id" "/exit" Enter 2>/dev/null
    fi
  done
  sleep 2
  for pane_id in "$WORKER_PANE" "$VERIFIER_PANE"; do
    if [ -n "$pane_id" ]; then
      tmux kill-pane -t "$pane_id" 2>/dev/null
    fi
  done
else
  echo "WARNING: session-config.json not found or jq not installed."
  echo "Cannot safely identify Worker/Verifier panes. Kill them manually."
fi
```
**CRITICAL: NEVER use `grep -i 'claude\|codex'` to find panes to kill.** The user's own Claude Code session matches those patterns. Always use the specific pane IDs from session-config.json.

## `analytics [slug]`

Cross-project analytics dashboard. Scans `~/.claude/ralph-desk/analytics/` for all campaign data.

- No slug: show summary across all projects (total campaigns, pass/fail rate, average iterations, total cost)
- With slug: show detailed analytics for that project (per-US pass rate, model upgrade frequency, iteration distribution, cost per US)

Data sources:
- `campaign.jsonl` — per-iteration structured records
- `metadata.json` — project root, campaign status, timestamps
- `self-verification-data.json` — campaign-level quality metrics

## `resume <slug>`

Resume a previously interrupted campaign. Equivalent to `run <slug>` but explicitly restores state:

1. Read `.claude/ralph-desk/logs/<slug>/runtime/status.json` for `verified_us`, `iteration`, `consecutive_failures`
2. Read `.claude/ralph-desk/memos/<slug>-memory.md` for completed stories and next iteration contract
3. Check for sentinels (`complete.md`, `blocked.md`) — if present, inform user and stop
4. If no sentinels, invoke `run <slug>` with the same options from the previous session (stored in status.json fields: `worker_model`, `verifier_model`, `final_verifier_model`, `verify_mode`, `consensus_mode`)
5. The runner automatically restores `verified_us` from memory or status.json on startup

Example:
```
/rlp-desk resume my-feature
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
  --mode agent|tmux                    Execution mode (default: agent)
  --worker-model MODEL                 Worker model: haiku|sonnet|opus or gpt-5.4:high|spark:high (default: haiku)
  --lock-worker-model                  Disable auto model upgrade on failure
  --verifier-model MODEL               per-US verifier (default: sonnet)
  --final-verifier-model MODEL         Final ALL verifier (default: opus)
  --consensus off|all|final-only       Cross-engine consensus (default: off)
  --consensus-model MODEL              per-US cross-verifier (default: gpt-5.4:medium)
  --final-consensus-model MODEL        Final cross-verifier (default: gpt-5.4:high)
  --verify-mode per-us|batch           Verification strategy (default: per-us)
  --cb-threshold N                     Consecutive failures before BLOCKED (default: 6)
  --max-iter N                         Max iterations (default: 100)
  --iter-timeout N                     Per-iteration timeout, tmux only (default: 600)
  --debug                              Debug logging (~/.claude/ralph-desk/analytics/<slug>/debug.log)
  --with-self-verification             Campaign self-verification analysis (post-loop report)
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
