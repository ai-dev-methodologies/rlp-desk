# Ralph Desk Governance v2

Fresh-context independent verification protocol.
The Leader orchestrates, while Worker/Verifier run in isolated fresh contexts every iteration.

---

## 1. Core Principles

- **Fresh context per iteration**: Worker/Verifier start fresh every time. No prior conversation.
- **Filesystem = memory**: State exists only on the filesystem (PRD, memory, context, memos).
- **Worker claim ≠ complete**: A Worker's DONE is merely a claim. The Verifier must independently verify before it's confirmed.
- **Worker scope is bounded**: Worker implements only the contracted US per iteration (Scope Lock). Out-of-scope changes are flagged by the Verifier.
- **Verifier is independent**: The Verifier judges based on evidence alone, without knowledge of the Worker's reasoning process.
- **Sentinels are Leader-owned**: Only the Leader writes COMPLETE/BLOCKED sentinels.
- **Supported engines**: claude (default; models: haiku, sonnet, opus) and codex (opt-in via `--worker-engine codex` / `--verifier-engine codex`).

## 1a. Iron Laws

Absolute rules that cannot be violated under any circumstance.

```
IL-1: NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
IL-2: NO INIT WITHOUT AC QUALITY SCORE >= 6
IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3
IL-5: NO PASS WHEN TESTS ARE SKIPPED OR NOT EXECUTED
```

**IL-1: Evidence Mandate**
Required: every verdict must reference at least one command execution with its exit code.
A verdict without command output evidence is automatically invalid.
Additional signal: phrases such as "should pass", "probably works", "seems to",
"looks correct", "appears to" (including but not limited to) without command evidence
confirm the violation but are not the primary check — command output presence is.
`request_info` is not an escape from IL-1 — if evidence was collectible, it must be collected.

**IL-2: Ambiguity Gate**
Each AC is scored 0-12 on 6 dimensions (0/1/2 points each):
- Single behavior: 0=multiple behaviors, 1=mostly single, 2=exactly one testable behavior
- Domain language: 0=technical terms (class names, API paths, DB tables), 1=mixed, 2=pure domain language
- Stakeholder clarity: 0=unclear who benefits, 1=implied, 2=explicitly stated
- Portability: 0=tech-stack specific, 1=mostly portable, 2=fully stack-independent
- Concrete example: 0=vague ("some input"), 1=partial specifics, 2=exact values with expected results
- Independence: 0=requires another AC to pass first, 1=loosely coupled, 2=fully self-contained

Score interpretation:
- 0-5: **REJECT** — init blocked. ACs too ambiguous.
- 6-9: **WARN** — init proceeds with logged warning. Show which dimensions scored low.
- 10-12: **PASS** — clean.

IL-2 is a pre-run gate: scoring MUST happen during brainstorm or at init time.
In tmux mode, IL-2 must be satisfied before `/rlp-desk run` is invoked.

Calibration example:
- Score 5 (REJECT): "Given a user, When they log in, Then the system works correctly"
  → single:1 (login is one behavior), domain:2 (domain terms only), stakeholder:1 (implied user), portability:1 (mostly portable), concrete:0 ("works correctly" is vague), independence:0 (implies registration AC) = 5
- Score 7 (WARN): "Given a registered user with email 'test@example.com' and valid password, When they submit the login form, Then they are redirected to the dashboard within 2 seconds"
  → single:2 (exactly one: login redirect), domain:1 ("submit" is slightly technical), stakeholder:1 (implied end user), portability:1 (web-specific "form"), concrete:2 (specific email, 2s threshold), independence:0 (requires registration) = 7

**IL-3: Layer Completeness**
Verification layers:
- L1: Unit Test — function-level, mocks allowed. Always required.
- L2: Integration — real external services (DB, API, Redis). Required when external dependencies exist.
- L3: E2E Simulation — known input → full pipeline → output comparison. Always required.
- L4: Deploy Verify — production environment checks. Required when deploying.

Layer requirements per US are determined by risk classification (§1c).
Non-applicable layers must be explicitly marked "N/A — {reason}" in the test-spec.
Any required layer section with TODO or blank = automatic Verifier FAIL.
See §1d for full layer definitions.

**IL-4: Test Sufficiency**
Each AC must have >= 3 tests covering >= 2 of 3 categories (happy path, negative/error, boundary).
Tests must be mapped to ACs in the test-spec's criteria-to-test mapping table.
Only tests listed in this mapping count toward IL-4.
Count < 3 per any AC = FAIL.

### Enforcement

| Iron Law | Checked by | When | Method |
|----------|-----------|------|--------|
| IL-1 | Verifier | verification time | mechanical (command output presence) |
| IL-2 | Leader | brainstorm/init | scored (6-dimension rubric) |
| IL-3 | Verifier | verification time | mechanical (TODO/blank scan) |
| IL-4 | Verifier | verification time | scored (test count per AC) |
| IL-5 | Verifier | verification time | mechanical (skip/pending/0-collected scan in test output) |

- Violation of any Iron Law overrides all other verdict considerations — verdict MUST be FAIL.
- When an Iron Law is violated, the verdict MUST be `fail` regardless of uncertainty.
  `request_info` remains valid only when the Verifier cannot determine whether an Iron Law
  was violated (e.g., cannot access test files, command execution blocked).
- You (the Leader) cannot waive Iron Laws. Only the user can explicitly waive an Iron Law
  for a specific US with documented justification in the PRD.

## 1b. Evidence Gate

This section operationalizes IL-1 (Evidence Mandate) into a concrete step-by-step protocol.

Before any verdict, the Verifier MUST follow this 5-step process:

1. **IDENTIFY**: What command proves this claim?
2. **RUN**: Execute the command (fresh, not cached or recalled)
3. **READ**: Full output + exit code + failure count
4. **VERIFY**: Does output confirm the claim?
   - YES → state claim WITH evidence (command + output + exit code)
   - NO → state actual status with evidence
5. **ONLY THEN**: Issue verdict

Skipping any step = invalid verification (IL-1 violation).

### Forbidden Patterns
- "should pass", "probably works" without command output
- Trusting Worker's success reports without independent re-execution
- Partial verification ("linter passed" ≠ "tests passed" ≠ "all AC met")
- "Code inspection" as substitute for automated command execution
- Citing cached/prior results instead of fresh execution

## 1c. Risk Classification

Each US is classified by risk level during brainstorm. Higher risk = more verification layers.

| Level | Description | Required Layers | Extra Requirements |
|-------|-------------|-----------------|-------------------|
| LOW | Read-only, docs, config | L1 + L3 | — |
| MEDIUM | New feature, refactor | L1 + L2 (if external deps) + L3 | — |
| HIGH | Production deploy, data migration | L1 + L2 + L3 + L4 | — |
| CRITICAL | Financial, security, medical | L1 + L2 + L3 + L4 | consensus + mutation testing (when mutation testing tool is configured in test-spec) |

L2 is included in MEDIUM+ rows but is marked N/A when no external services exist (see §1d L2 "When N/A" clause).

### Who Decides
- During brainstorm: user assigns risk level per US (Leader suggests, user confirms).
- If brainstorm was skipped: Leader assigns based on PRD content at first run iteration.
- Risk level is recorded in PRD per US. Cannot be downgraded without user approval.

### Examples
- LOW: README update, adding comments, .env.example
- MEDIUM: REST API endpoint, React component, business rule
- HIGH: database migration, CI/CD change, deployment config
- CRITICAL: payment processing, auth, encryption, PII handling

## 1d. Verification Layers

Four layers of verification, each targeting a different failure mode.

### L1: Unit Test (always required)
- Scope: function/method level, isolated logic
- Mocks: allowed for external boundaries only
- Evidence: test runner output with pass/fail count + exit code

### L2: Integration (required when external dependencies exist)
- Scope: interaction with real external services (database, API, message queue, cache)
- Mocks: NOT allowed — use real or containerized services
- Evidence: integration test output with connection confirmation + data verification
- When N/A: "N/A — no external services (pure computation/transformation)"

### L3: E2E Simulation (always required)
- Scope: known input → full pipeline → quantitative output comparison
- Evidence: input data + actual output + expected output + comparison result
- For simple utilities: E2E = "run function with known input, verify output matches expected"

### L4: Deploy Verify (required when deploying)
- Scope: production/staging environment health after deployment
- Evidence: health check response + deployment status + monitoring state
- When N/A: "N/A — no deployment (library/tool, local-only change)"

### Rules
- L1 and L3: always required regardless of risk level.
- L2: required for MEDIUM+ risk when external services are involved.
- L4: required for HIGH+ risk when deployment occurs.
- Layer requirements per US are determined by risk classification (§1c).
- Non-required layers must be marked "N/A — {reason}" per IL-3. Blank or TODO = FAIL.

## 1e. Verification Checkpoints

Verification occurs at two boundaries, not as a single final event.

### Checkpoint 1: Story/Unit (per-US)
- Trigger: Worker signals verify with us_id = specific US
- Scope: that US's acceptance criteria (L1 pass is verified as part of layer enforcement in Verifier step 5)
- On fail: fix loop (§7½)

### Checkpoint 2: Release Readiness (us_id=ALL)
- Trigger: all individual US pass Checkpoint 1 → Worker signals verify with us_id = "ALL"
- Scope: all AC + L2 integration (if applicable) + L3 E2E Simulation + L4 deploy (if applicable) + mutation score (if CRITICAL, when mutation testing tool is configured in test-spec)
- On fail: fix loop; escalation to user if 3 consecutive failures

### Relationship to Existing Flow
- Checkpoint 1 = existing per-US verify (§7a). No change.
- Checkpoint 2 = existing "us_id=ALL final full verify" (§7a). Adds explicit layer scope.
- No new iteration steps are introduced.

## 1f. Execution & Judgment Traceability

Every iteration, Worker and Verifier MUST record their process and reasoning — not just results.
This is the default behavior, not an optional flag. Without it, IL-1 (Evidence Mandate) is incomplete.

### Worker: execution_steps in done-claim.json
Worker records what was done, in what order, with command evidence in `done-claim.json`:
- Each step includes: what action, which AC, command executed, exit code, summary
- Step types: `write_test`, `verify_red`, `implement`, `verify_green`, `refactor`, `commit`, `verify`
- This proves the Worker followed test-first approach and did not skip steps

### Verifier: reasoning in verify-verdict.json
Verifier records WHY each judgment was made in `verify-verdict.json`:
- Each check includes: what was checked, decision (pass/fail), and the specific evidence basis
- Checks include: IL-1 Evidence Gate, Layer Enforcement, Test Sufficiency, Anti-Gaming, Worker Process Audit
- This proves the Verifier actually performed each check rather than rubber-stamping

### Why This Is Default (Not Optional)
- IL-1 says "no claims without evidence" — this applies to Worker AND Verifier
- Without execution_steps, Worker's done-claim is an unsubstantiated assertion
- Without reasoning, Verifier's verdict is an unsubstantiated judgment
- Both are archived in `logs/<slug>/` per existing audit trail pattern

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
│   ├── <slug>-escalation.md          # Architecture escalation report (tmux mode, §7¾)
│   ├── <slug>-complete.md           # SENTINEL (Leader only)
│   └── <slug>-blocked.md            # SENTINEL (Leader only)
├── plans/
│   ├── prd-<slug>.md                # PRD (shared contract)
│   └── test-spec-<slug>.md          # Verification criteria
└── logs/<slug>/
    ├── iter-NNN.worker-prompt.md    # Audit trail prompt copy
    ├── iter-NNN.verifier-prompt.md  # Audit trail prompt copy
    ├── iter-NNN.result.md           # Iteration result (leader-measured + git-measured)
    ├── self-verification-data.json              # Cumulative campaign data (--with-self-verification)
    ├── self-verification-report-NNN.md          # Versioned campaign analysis report (--with-self-verification)
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

**NO ENGINE PRIORITY:** Claude and Codex have equal weight. If one passes and the other fails, the verdict is FAIL. No engine may be prioritized or dismissed. Infrastructure failure = CLI crash, timeout, or verdict file not generated — NOT a valid verdict with verdict=fail.
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

## 7¾. Architecture Escalation

Note: Circuit Breaker (§8) fires first at 2 consecutive failures (model upgrade + retry). If the retry also fails (3rd consecutive failure), Architecture Escalation applies. The CB retry counts toward the consecutive_failures counter.

If 3+ consecutive fix attempts fail for the same US:

1. **STOP fixing symptoms** — the problem is likely architectural, not a bug.
2. **Leader reports to user**: "3 consecutive fix attempts failed for US-{id}. This suggests an architectural issue, not a simple bug."
3. **Include in report**:
   - What was attempted in each fix
   - What specifically kept failing
   - Hypothesis: why fixes are not sticking
4. **Do NOT attempt fix #4** without user guidance.
5. **Options**: refactor architecture, simplify the US, split the US, or mark BLOCKED.

In tmux mode: Leader writes `<slug>-escalation.md` with the report and sets BLOCKED sentinel with reason "architecture-escalation."

## 8. Circuit Breaker

| Condition | Verdict |
|-----------|---------|
| context-latest.md unchanged for 3 consecutive iterations | BLOCKED |
| Same acceptance criterion fails 2 consecutive iterations | Upgrade model, retry once; if still failing → Architecture Escalation (§7¾) → BLOCKED |
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
