# Ralph Desk Governance v2

Fresh-context independent verification protocol.
The Leader orchestrates, while Worker/Verifier run in isolated fresh contexts every iteration.

---

## 1. Core Principles

- **Fresh context per iteration**: Worker/Verifier start fresh every time. No prior conversation.
- **Filesystem = memory**: State exists only on the filesystem (PRD, memory, context, memos).
- **Worker claim ≠ complete**: A Worker's DONE is merely a claim. The Verifier must independently verify before it's confirmed.
- **Worker scope is bounded**: Worker implements only the contracted US per iteration (Scope Lock). Out-of-scope changes are flagged by the Verifier.
- **Worker must NEVER modify Claude Code settings** (settings.json, settings.local.json). Permission prompts must be reported as blocked, not bypassed by editing settings.
- **Verifier is independent**: The Verifier judges based on evidence alone, without knowledge of the Worker's reasoning process.
- **Sentinels are Leader-owned**: Only the Leader writes COMPLETE/BLOCKED sentinels.
- **Supported engines**: claude (default; models: haiku, sonnet, opus) and codex (opt-in via `--worker-model spark:high` or `--worker-model gpt-5.5:high`).

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

## 1c. Task Sizing Principle

Tasks must be sized within the assigned Worker's comfortable zone — not at its ceiling.
A task that pushes a Worker to its maximum capability will frequently fail in fresh-context execution,
because context budget must also cover PRD reading, test writing, and evidence collection.

Rules:
- Each US: max 3-4 ACs, max 2 changed files, completable in 1-2 iterations.
- If a task is at the edge of a Worker's capability, either split the task or upgrade the Worker model.
- Leader model selection: choose a model that can succeed comfortably, not the minimum viable model.
- During brainstorm: when proposing US splits, target "smaller than what the Worker can handle" not "as much as the Worker can handle."

This aligns with the original Ralph Loop principle: small tasks succeed most of the time.

## 1c½. Risk Classification

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
- On fail: fix loop; escalation to user if 6 consecutive failures (default cb_threshold)

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
- Step types: `plan`, `write_test`, `verify_red`, `implement`, `verify_green`, `refactor`, `commit`, `verify`, `verify_existing`
- This proves the Worker followed test-first approach and did not skip steps
- **Existing implementation rule**: When code already exists from a prior iteration/campaign, Worker MAY use `verify_existing` instead of `write_test → verify_red → implement → verify_green`. `verify_existing` requires: run all existing tests, record exit codes, confirm all AC are covered by passing tests. Worker MUST NOT skip recording evidence — `verify_existing` is evidence that existing code satisfies AC, not a shortcut to skip verification.

### Verifier: reasoning in verify-verdict.json
Verifier records WHY each judgment was made in `verify-verdict.json`:
- Each check includes: what was checked, decision (pass/fail), and the specific evidence basis
- **failure_category** (required on fail verdicts): Verifier classifies each issue's root cause as one of:
  - `spec` — AC is ambiguous, contradictory, or untestable (suggests IL-2 re-assessment, not model upgrade)
  - `implementation` — code logic error, missing case, wrong algorithm (model upgrade may help)
  - `integration` — individual pieces work but interaction fails (suggests task split or architecture review)
  - `flaky` — non-deterministic failure, timing, environment (suggests retry, not escalation)
  Leader uses failure_category to decide between model upgrade, spec refinement, or architecture escalation.
- Checks include: IL-1 Evidence Gate, Layer Enforcement, Test Sufficiency, Anti-Gaming, Worker Process Audit, Test Coverage Audit
- This proves the Verifier actually performed each check rather than rubber-stamping
- **Test Coverage Audit (mandatory)**: Verifier MUST check that tests cover ALL code paths, not just happy paths. Specifically:
  - Every branch in `case` statements must have a test (e.g., all model types in get_next_model)
  - Every engine/model combination must be tested (claude, codex 5.4, spark — not just 1-2)
  - Every ceiling/boundary must be tested (not just "opus ceiling" — also spark ceiling, 5.4 ceiling)
  - If Worker's tests cover only 2 of 3 engine paths, verdict MUST be fail with "test coverage gap" issue
  - "Tests pass" is NOT sufficient — "tests cover all code paths" is required
- **Integration Test (mandatory when functions call other functions)**: Verifier MUST check that function call chains produce correct end-to-end results, not just that each function works in isolation. Specifically:
  - If function A's output is function B's input, there MUST be a test that runs A→B together and verifies the result
  - Example: `get_model_string()` returns "gpt-5.3-codex-spark:medium" — `get_next_model()` must accept that exact value and return the correct upgrade. A test must verify this chain.
  - Unit tests (extract_fn + isolated run) are necessary but NOT sufficient for refactored code
  - Structural tests (grep for function existence) are necessary but NOT sufficient
  - "All unit tests pass" does NOT prove the system works — integration tests prove it

### Why This Is Default (Not Optional)
- IL-1 says "no claims without evidence" — this applies to Worker AND Verifier
- Without execution_steps, Worker's done-claim is an unsubstantiated assertion
- Without reasoning, Verifier's verdict is an unsubstantiated judgment
- Both are archived in `logs/<slug>/` per existing audit trail pattern

### Cost Log (US-023 R11 P2-K)
`logs/<slug>/cost-log.jsonl` always has at least one entry per campaign. tmux mode runs the estimated path (no LLM SDK token counters), so when prompt/claim/verdict bytes are all zero the entry's `note` field is set to `no_actual_usage_recorded`. Audit pipelines branch on `note` to distinguish "iteration ran but tokens not captured" (tmux estimated path) from "logging broken" (file empty / writer never called). The runner registers `trap '_emit_final_cost_log; cleanup' EXIT INT TERM` so an unconditional final entry is appended even if the campaign exits via an early-return path.

### A4 Fallback Audit (US-017 R5 P0-D)
When Worker writes done-claim.json but forgets iter-signal.json, the runner auto-generates a verify signal as A4 fallback. This produces an opaque `summary="auto-generated by A4 fallback (done-claim without signal)"` that erases debugging context.

- Each A4 fallback invocation appends a JSONL entry to `logs/<slug>/a4-fallback-audit.jsonl` (event=`a4_fallback`, iter, us_id, source).
- **Recommended ratio < 10%** of total iterations (per mission). Above this threshold, Worker prompt mandate (Step N+1) is failing — investigate prompt clarity or Worker model.
- Verifier sets `meta.iter_signal_quality='auto_generated'` when it detects an A4 fallback summary so audit pipelines can join the signal-quality dimension to verdicts.

### BLOCKED Surfacing
A BLOCKED outcome MUST surface its reason on **FIVE channels at once**: (1) sentinel file (markdown `<slug>-blocked.md` + JSON sidecar `<slug>-blocked.json`), (2) status.json, (3) Leader's stderr console, (4) campaign report, (5) memory.md/latest.md hygiene update (worker mandate per US-020 R8 P1-H — `Blocking History` entry in memory.md and `Known Issues` update in latest.md before the sentinel is written). Sentinel-only is silent failure; operators (and wrappers) must see WHY without grep'ing memo files. The leader propagates `verdict.reason || verdict.summary` into the sentinel reason field, the JSON sidecar, the return object, and the campaign report. The 5th channel survives across iterations: the next worker reads memory.md before re-attempting, preventing same-block-reason loops.

When the worker writes a sentinel without performing the 5th-channel hygiene update (memory.md/latest.md mtime older than 5 minutes at sentinel-write time), the runner stamps `meta.blocked_hygiene_violated=true` on the JSON sidecar and emits an analytics event so audit pipelines can track hygiene compliance.

### Failure Taxonomy (P1-D)
BLOCKED writes a JSON sidecar (`<slug>-blocked.json`) alongside the markdown sentinel so wrappers can `jq .reason_category` instead of regex'ing free text. Schema:

```json
{
  "schema_version": "2.0",
  "slug": "<slug>",
  "us_id": "<us_id or ALL>",
  "blocked_at_iter": <int>,
  "blocked_at_utc": "<iso8601>",
  "reason_category": "metric_failure | cross_us_dep | context_limit | infra_failure | repeat_axis | mission_abort",
  "reason_detail": "<full reason text>",
  "failure_category": "spec | implementation | integration | flaky | null",
  "recoverable": true | false,
  "suggested_action": "next_mission_chain | restart | retry_after_fix | terminal_alert"
}
```

**Wrapper contract (binding)**:
- `reason_category` is **PRIMARY** — wrappers MUST branch on this field for recovery decisions.
- `failure_category` is **SECONDARY, diagnostic only** — do NOT branch on it; logging/triage only.

**Category → wrapper recovery action mapping** (defaults set by writer; wrappers may override but should follow):
- `metric_failure` → `retry_after_fix` (fix PRD/code, retry; recoverable=true)
- `cross_us_dep` → `retry_after_fix` (move AC to later US or switch to batch mode; recoverable=true)
- `infra_failure` → `restart` (CLI/network/spawn issue; recoverable=true)
- `context_limit` → `next_mission_chain` (current mission stale; recoverable=false)
- `repeat_axis` → `next_mission_chain` (model ceiling reached on this axis; recoverable=false)
- `mission_abort` → `terminal_alert` (flywheel guard exhausted; recoverable=false)

**Cross-US token list (cross_us_dep classifier)** — verifier verdict / worker signal text matching ANY of these is classified as `cross_us_dep`:
- English: `depends on US-`, `blocking US-`, `awaits US-`, `post-iter US-`, `requires US-N`, `cross-US`
- Korean: `US-N 산출물`, `신규 US-`, `post-iter`

**Write Order Contract (atomicity invariant)** — v5.7 §4.24 reversed:
1. **markdown sentinel written FIRST** via `writeSentinelExclusive` (`fs.open(path, 'wx')` — O_EXCL first-writer-wins). The md acts as the race lock.
2. **JSON sidecar written SECOND**, only by the winning writer.
3. Invariant: **markdown exists ⇒ JSON exists** (winner writes both; losers see EEXIST and return without touching JSON, preserving the winner's content).
4. Wrappers SHOULD watch markdown sentinel, then read JSON sidecar. If JSON not yet visible (rare ≤50ms), retry up to 5 × 50ms before failing.

`writeSentinelExclusive` (in `src/node/shared/fs.mjs`) provides per-file first-writer-wins; cross-file ordering is enforced by the explicit md-then-JSON sequence inside `writeSentinel`.

## 1g. Sentinel Guarantee Invariant (file-guarantee contract)

**Every terminal exit of `runCampaign()` MUST leave exactly one sentinel on disk: `<slug>-blocked.md` XOR `<slug>-complete.md`.**

This invariant is the foundation of the fresh-context architecture. If a campaign exits without any sentinel, future iterations cannot determine campaign state — Worker/Verifier are dispatched into a campaign whose history they cannot reconstruct.

### Enforcement (3-layer defense)

1. **Per-poll-site sentinel write** (`_handlePollFailure` helper at `src/node/runner/campaign-main-loop.mjs`). Every `pollForSignal` call site (Worker, VerifierPerUS, VerifierFinal, Flywheel, Guard) is wrapped in `try { … } catch (error) { return _handlePollFailure(error, { role, … }); }`. The helper classifies via `BLOCK_TAGS` typed enum, calls `writeSentinel` (idempotent via O_EXCL), and returns `{status:'blocked', …}` so the caller exits the loop cleanly.

2. **Run-level try/finally backstop** (`_ensureTerminalSentinel`). After the campaign body executes, a `finally` block checks `exists(blockedSentinel) XOR exists(completeSentinel)`. If neither (paused state `continue` excepted), writes a synthetic BLOCKED `infra_failure/leader_exited_without_terminal_state` so even unhandled exceptions cannot escape silently.

3. **Schema validator at READ boundary** (`validateArtifact`). After every `pollForSignal` returns parsed JSON, validates `(slug, iteration ≥ floor, signal_type matches read context, us_id ∈ usList ∪ {ALL})`. Throws `MalformedArtifactError({field, expected, got})` → caught by same `_handlePollFailure` → BLOCKED `contract_violation/malformed_artifact` (recoverable).

### Per-role failure-category enum

`_classifyBlock` (in `campaign-main-loop.mjs`) maps each `BLOCK_TAGS` value to one of the locked taxonomy categories:

| Tag | reason_category | recoverable | Example trigger |
|-----|----------------|-------------|-----------------|
| `WORKER_EXITED` | `infra_failure` | false | Worker pane returned to shell without writing signal |
| `VERIFIER_EXITED` | `infra_failure` | false | Per-US Verifier exited without writing verdict |
| `FINAL_VERIFIER_EXITED` | `infra_failure` | false | Final ALL-verifier exited without writing verdict |
| `FLYWHEEL_EXITED` | `infra_failure` | false | Flywheel pane crashed |
| `GUARD_EXITED` | `infra_failure` | false | Guard pane crashed |
| `PROMPT_BLOCKED` | `infra_failure` | false | Default-No prompt — auto-Enter would CANCEL |
| `<role>_TIMEOUT` | `infra_failure` | false | pollForSignal timed out without exit detected |
| `MALFORMED_ARTIFACT` | `contract_violation` | true | Worker/Verifier wrote schema-violating JSON |
| `LEADER_EXITED_WITHOUT_TERMINAL_STATE` | `infra_failure` | false | Backstop fired (uncaught exception or paths outside controlled scope) |

### Auditing

Operators can verify the invariant for any campaign by running:

```sh
zsh tests/sv-gate-fast.sh   # 30s mechanical check (greps + units)
zsh tests/sv-gate-full.sh   # 5min including REAL tmux + REAL campaign E2E
```

The fast gate fails immediately if any pollForSignal call site lacks a `_handlePollFailure` wiring or the writeSentinelExclusive primitive is bypassed.

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
- **Verdict output rule**: MUST write verdict JSON as a FILE (not stdout). Leader polls the file path — terminal output is lost. Evidence strings: include key metrics and exit codes only, do NOT quote full command output or logs verbatim.
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
| Worker | haiku | Default; auto-upgrades on failure (sonnet → opus) |
| Worker (locked) | haiku | `--lock-worker-model` disables auto-upgrade |
| Verifier (per-US) | sonnet | Lightweight; campaign-fixed (no progressive upgrade) |
| Verifier (final) | opus | Full rigor; independent of per-US model |

**Worker auto-upgrade**: When a Worker fails, the Leader upgrades the model for the retry (haiku → sonnet → opus). This upgrade is Worker-only. Verifier model is campaign-fixed — it does not upgrade on failure.

**Verifier model is campaign-fixed**: `--verifier-model` applies to all per-US verifications throughout the campaign. `--final-verifier-model` applies to the final ALL verification. Neither upgrades automatically.

The Leader decides each iteration. Decision criteria:
- Previous iteration failed → upgrade Worker model (unless `--lock-worker-model`)
- Simple repetitive task → keep current Worker model
- User explicitly specified → use as given

### Codex (opt-in engine)

Model routing uses `--worker-model` and `--verifier-model` with codex format: `spark:high` or `gpt-5.5:high`.

```
--worker-model spark:high        # codex worker, spark model, high reasoning
--verifier-model gpt-5.5:high    # codex verifier, gpt-5.5, high reasoning
```

`parse_model_flag()` auto-detects engine from the model name: plain names (haiku, sonnet, opus) = claude; `name:reasoning` format = codex. Claude is the default engine; codex is explicitly opt-in.

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

If `--worker-model` or `--verifier-model` uses codex format (e.g., `spark:high`, `gpt-5.5:high`) (opt-in):
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
codex -m gpt-5.5 \
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
│   ├── <slug>.worker.prompt.md      # Worker base prompt (regenerated on re-execution)
│   └── <slug>.verifier.prompt.md    # Verifier base prompt (regenerated on re-execution)
├── context/
│   └── <slug>-latest.md             # Current frontier; Worker updates (reset to template on re-execution)
├── memos/
│   ├── <slug>-memory.md             # Campaign memory; Worker updates (reset to template on re-execution)
│   ├── <slug>-done-claim.json       # Worker's completion claim (runtime; deleted on re-execution)
│   ├── <slug>-iter-signal.json      # Worker's iteration signal (runtime; deleted on re-execution)
│   ├── <slug>-verify-verdict.json   # Verifier's verdict (runtime; deleted on re-execution)
│   ├── <slug>-escalation.md         # Architecture escalation report (tmux mode, §7¾; deleted on re-execution)
│   ├── <slug>-complete.md           # SENTINEL (Leader only; deleted on re-execution)
│   └── <slug>-blocked.md            # SENTINEL (Leader only; deleted on re-execution)
├── plans/
│   ├── prd-<slug>.md                # PRD (in-place: --mode improve | deleted: --mode fresh)
│   └── test-spec-<slug>.md          # Verification criteria (regenerated on re-execution)
└── logs/<slug>/                          # Project-level operational data
    ├── campaign-report.md           # Campaign summary (versioned: campaign-report-v{N}.md on re-execution)
    ├── iter-NNN.worker-prompt.md    # Audit trail prompt copy (deleted on re-execution)
    ├── iter-NNN.verifier-prompt.md  # Audit trail prompt copy (deleted on re-execution)
    ├── iter-NNN.result.md           # Iteration result (deleted on re-execution)
    ├── iter-NNN-done-claim.json     # Archived done-claim per iteration (deleted on re-execution)
    ├── iter-NNN-verify-verdict.json # Archived verdict per iteration (deleted on re-execution)
    ├── status.json                  # Leader's loop state (deleted on re-execution)
    ├── baseline.log                 # Baseline capture (deleted on re-execution)
    └── cost-log.jsonl               # Per-iteration cost log (deleted on re-execution)

~/.claude/ralph-desk/analytics/<slug>--<root_hash>/  # User-level cross-project analytics
    ├── metadata.json                # Campaign metadata (slug, project_root, status, times)
    ├── debug.log                    # Debug output (versioned: debug-v{N}.log on re-execution)
    ├── campaign.jsonl               # Per-iteration structured data (versioned: campaign-v{N}.jsonl)
    ├── self-verification-data.json  # Cumulative SV data (agent-mode only, --with-self-verification)
    └── self-verification-report-NNN.md  # Versioned SV report (--with-self-verification; NNN auto-increment)
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

  ⑥½ Flywheel direction review (when --flywheel on-fail and consecutive_failures > 0)
     - Dispatch Flywheel agent (fresh context, --flywheel-model)
     - Read flywheel-signal.json for direction decision (hold/pivot/reduce/expand)
     - Optional `next_mission_candidate` field (string | null): when present, the leader propagates it to status.json so consumer wrappers can chain the next mission without code edits. See docs/multi-mission-orchestration.md.
     - If --flywheel-guard on:
       - Dispatch Guard agent (fresh context, --flywheel-guard-model)
       - Read flywheel-guard-verdict.json:
         • pass → proceed to Worker with updated contract
         • pass + analysis_only → skip Worker, record analysis, next iteration
         • fail → re-run Flywheel with guard feedback (max 2 retries)
         • fail + retries exhausted → BLOCKED
         • inconclusive → BLOCKED (escalate to user)
       - Guard count tracked per-US in status.json
     - **Mode support (v0.12.0+, v5.7 §4.3)**: flywheel runs identically in
       --mode agent and --mode tmux when routed through the Node leader
       (`node ~/.claude/ralph-desk/node/run.mjs run --mode tmux`). The legacy
       `run_ralph_desk.zsh` runner rejects --flywheel/--flywheel-guard with
       exit 2 + migration banner; users must use the Node entry. Same applies
       to --with-self-verification: SV report generation is supported in
       tmux mode via the Node leader's generateSVReport() (no longer
       agent-mode-only).

  ⑦ Execute Verifier (see §7a for per-US and §7b for consensus details)
     - Build prompt (scoped to us_id if per-us mode) → log
     - Agent(subagent_type="executor", model=selected, prompt=prompt)
     - If --consensus is not off: run second verifier with alternate engine (see §7b)
     - Read verify-verdict.json:
       • pass + specific US → add to verified_us, Worker does next US
       • pass + us_id=ALL or complete → write COMPLETE sentinel, stop
       • fail + continue → go to ⑧
       • blocked → write BLOCKED sentinel, stop

  ⑦d Archive iteration artifacts (after verdict read, before next prep)
     - Archive done-claim.json → logs/<slug>/iter-NNN-done-claim.json
     - Archive verify-verdict.json → logs/<slug>/iter-NNN-verify-verdict.json
     (Preserved across clean; data source for Campaign Report and SV analysis)

  ⑧ Write iter-NNN.result.md to logs/<slug>/ (result status + git diff --stat)
     Update status.json, report to user, continue to next iteration

After loop end (COMPLETE, BLOCKED, TIMEOUT):
  ⑧½ Campaign Report (always — independent of --debug)
     - Generate logs/<slug>/campaign-report.md with 8 sections
     - Version existing report to campaign-report-v{N}.md before writing new
     - Data: status.json (baseline_commit, per-iter), archived iter artifacts, PRD, git diff
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

**Cross-US dependency rule (per-us only):** In per-us mode each AC must reference only the same US or earlier verified US' artifacts. Future-US references (e.g. "post-iter US-(N+M) batch", "new US-(M) artifact") make the AC unsatisfiable inside a single per-us iteration and are rejected at init time (`init_ralph_desk.zsh` exits 2). Fold cross-US verification into the last measurement US, or run with `--verify-mode batch`.

**Cross-mission us_id leak prevention (US-022 R10 P2-J):** When the same `$DESK` directory hosts back-to-back missions, an `iter-signal.json` left over from the prior mission can carry a `us_id` (e.g. `US-005`) that has no corresponding section in the new mission's PRD (`US-001` through `US-003`). The runner would then scope-lock the next iteration to a non-existent US and block. `init_ralph_desk.zsh` runs `_quarantine_stale_signal` (lib_ralph_desk.zsh) which moves any signal whose `us_id` is absent from the new mission's PRD into `.sisyphus/quarantine/iter-signal.<epoch>.json` instead of `rm`-ing it. The PRD US-list extractor `_extract_prd_us_list` recognises three heading variants (`## US-005:`, `## US-005 -`, bare `## US-005`) so legitimate references are not false-flagged. The quarantine file is preserved so the operator can recover when the leak was actually intentional handoff state.

## 7b. Cross-Engine Consensus Verification

Controlled by `--consensus off|all|final-only` (default: `off`).

- `off`: single engine verification only
- `all`: cross-engine consensus on every per-US verify and final ALL verify
- `final-only`: cross-engine consensus only on final ALL verify

When consensus is active, after the primary verifier runs, a second verifier runs with the alternate engine:

```
Worker completes US → signal verify
  → Primary Verifier runs (checks AC)
  → Cross Verifier runs (checks AC)
  → Both pass → proceed (next US or COMPLETE)
  → Either fails → combined issues → fix contract → Worker retry
  → Max 6 consensus rounds per US → BLOCKED if still disagreeing
```

**NO ENGINE PRIORITY:** Both verifiers have equal weight. If one passes and the other fails, the verdict is FAIL. No engine may be prioritized or dismissed. Infrastructure failure = CLI crash, timeout, or verdict file not generated — NOT a valid verdict with verdict=fail.

### Consensus Model Routing

| Scenario | Primary verifier | Cross verifier |
|----------|-----------------|----------------|
| per-US, primary=claude | `--verifier-model` (sonnet) | `--consensus-model` (gpt-5.5:medium) |
| per-US, primary=codex | `--verifier-model` | claude opus (fixed) |
| final, primary=claude | `--final-verifier-model` (opus) | `--final-consensus-model` (gpt-5.5:high) |
| final, primary=codex | `--final-verifier-model` | claude opus (fixed) |

- Both must pass. No engine priority.
- spark is not allowed as a consensus cross verifier (100k output limit).

**Key rules:**
- Both claude and codex CLI must be installed
- Verifiers run sequentially in the same Verifier pane (tmux) or as sequential calls (Agent mode)
- Verdicts are saved as `verify-verdict-claude.json` and `verify-verdict-codex.json`
- Combined fix contracts include issues from both engines
- `status.json` includes `consensus_round`, `claude_verdict`, and `codex_verdict` fields
- Consensus can be combined with per-US verification (`--consensus all`: each US gets consensus-verified)

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

Note: Circuit Breaker (§8) fires first at 2 consecutive failures (model upgrade + retry — Path A: Agent-mode only; in tmux mode the shell CB triggers directly without model upgrade). If the retry also fails (`cb_threshold` reached), Architecture Escalation applies. The CB retry counts toward the consecutive_failures counter.

If `cb_threshold` or more consecutive fix attempts fail for the same US:

1. **STOP fixing symptoms** — the problem is likely architectural, not a bug.
2. **Leader reports to user**: "`cb_threshold` consecutive fix attempts failed for US-{id}. This suggests an architectural issue, not a simple bug."
3. **Include in report**:
   - What was attempted in each fix
   - What specifically kept failing
   - Hypothesis: why fixes are not sticking
4. **Do NOT attempt fix #4** without user guidance.
5. **Options**: refactor architecture, simplify the US, split the US, or mark BLOCKED.

In tmux mode: Leader writes `<slug>-escalation.md` with the report and sets BLOCKED sentinel with reason "architecture-escalation."

## 7e. Lane Enforcement (P1-E)

Default mode is **WARN-only** (`LANE_MODE=warn`). The opt-in `--lane-strict`
flag (or `LANE_MODE=strict`) escalates lane violations to BLOCKED, but the
escalation is **downgraded** to `recoverable=true` + `suggested_action=retry_after_fix`
(NOT `terminal_alert`) so an inaccurate mtime audit does not terminally
kill a campaign.

### Decision tree

| Detection | Default (`warn`) | `--lane-strict` |
|-----------|-----------------|-----------------|
| PRD / test-spec / memory mtime changed during a worker iteration | analytics event `event_type=lane_violation_warning` + `log_warn` + audit log entry. Loop continues. | All of the WARN actions PLUS sentinel BLOCKED with `reason_category=infra_failure`, `recoverable=true`, `suggested_action=retry_after_fix`. |

### Channels (Silent failure 0)

WARN mode is NOT silent — violations always emit on three channels:
1. analytics jsonl event (`lane_violation_warning`)
2. leader stderr (`log_warn`)
3. audit log file `~/.claude/ralph-desk/logs/<slug>/lane-audit.json`

The audit log is initialized to `[]` at campaign start so the file always exists;
each violation appends an entry `{file, mtime_before, mtime_after, iter, lane_mode}`.

### Why downgrade in strict mode

mtime audit is best-effort heuristic — it cannot accurately attribute the
modifier (worker vs leader vs external editor). Running an inaccurate
detector with `terminal_alert` would hand it the power to permanently
terminate a campaign. The downgrade keeps `recoverable=true` so wrappers
can re-launch after operator review.

### Non-goals

- chmod-based enforcement (would break test fixtures and consumer envs).
- git_blame-based actor identification (best-effort hint only; verifier IL-2
  is the real lane gate via worker process audit).
- Auto-launching missions on violation (consumer wrapper responsibility).

## 7f. Test Density Enforcement (US-018 R6 P1-F)

Default mode is **WARN-default** (`TEST_DENSITY_MODE=warn`). The opt-in `--test-density-strict` flag escalates a `< 3 tests/AC` finding to a non-zero `init` exit. Worker prompt mandates **>= 3 tests per AC** (happy + negative + boundary categories — IL-4). The test-spec must encode the same density. When the test-spec encodes fewer (e.g., 1 test per AC) the contract collapses: Worker following the prompt fails IL-4, Worker following the spec fails the prompt.

`init_ralph_desk.zsh` runs `_lint_test_density` (lib_ralph_desk.zsh) on the generated PRD + test-spec pair before campaign launch.

### Decision tree

| Detection | Default (`warn`) | `--test-density-strict` |
|-----------|-----------------|-----------------|
| Any US has `test_count < 3 * ac_count` | log_warn to stderr + audit log entry (`logs/<slug>/test-density-audit.jsonl`). Init exits 0. | All WARN actions PLUS init exits 1 with the same message. |

### Why no downgrade in strict mode

Test density is a *static* property of the test-spec, deterministically measurable, and observed before any worker runs. There is no risk asymmetry comparable to the lane-mtime audit (which is best-effort heuristic). Strict mode is a hard fail because the failure is unambiguous: too few tests for the AC count.

### Categorization (happy + negative + boundary)

The `>= 3 tests / AC` rule is a coverage floor, not a ceiling. Worker should distribute tests across:
- **happy**: standard input → expected output
- **negative**: malformed/missing input → defined error
- **boundary**: edge of allowed range, off-by-one, empty/max collections

If any category is missing for an AC the test-spec generator should densify before init. The runtime gate only counts; the categorization is enforced by the verifier's Test Coverage Audit (governance §1f Verifier reasoning).

## 7g. Signal Vocabulary Extension (US-019 R7 P1-G)

The base signal vocabulary (`continue | verify | blocked`) is binary at the iteration level: every AC in the current US either passes together or the whole iteration blocks. When unblocked ACs share an iteration with a single unsatisfiable AC the all-or-nothing semantic discards real progress.

`verify_partial` lets the worker emit progress and a deferral in one signal:

```json
{
  "iteration": N,
  "status": "verify_partial",
  "us_id": "US-001",
  "verified_acs": ["AC1", "AC2"],
  "deferred_acs": ["AC3"],
  "defer_reason": "AC3 depends on US-003 batch artifacts; cross-US"
}
```

- Verifier evaluates **only** `verified_acs`. `deferred_acs` are out-of-scope (not fail).
- Deferred ACs queue for the next iteration or the final ALL verify pass.
- The runner downgrades to `blocked` with reason `verify_partial_malformed` (reason_category `mission_abort`, recoverable=true, suggested_action=retry_after_fix) when `verified_acs` is missing or empty — the verifier has nothing to evaluate, so silent acceptance would be a false GREEN.

The downgrade is intentionally recoverable: the malformed signal is a worker-side prompt regression, not an environment failure, and the operator can fix it in-place.

## 7h. Tmux Session Lifecycle Resilience (US-024/025/026 R12+R13+R14 P0)

Multi-mission queue/daemon (`RLP_BACKGROUND=1`) workflows can lose their tmux session between missions — terminal close, manual `tmux kill-session`, or tmux server restart all drop the session and every pane in it. Three independent guards now compose:

### R12 — Pane lifecycle monitor (5s authoritative budget)
`_verify_pane_alive` and `_verify_session_alive` (lib_ralph_desk.zsh) check `#{pane_dead}` and `tmux has-session`. The runner invokes `_r12_check_lifecycle` at three sites: (1) immediately after `create_session()`, (2) at the top of every iteration, (3) right after worker dispatch and before the wait-loop. The check polls 5 attempts with 1-second sleep (5-second hard budget). On expiry it writes a BLOCKED sentinel with `reason_category=infra_failure`, `recoverable=true`, `suggested_action=restart` and exits 1 — never an infinite loop.

### R13 — Detached session protection (RLP_BACKGROUND only)
When `tmux new-session -d` collides with an existing session and `RLP_BACKGROUND=1`, the runner appends `-bg-<epoch>-<pid>` to `SESSION_NAME` and runs a `tmux has-session` loop with random 4-digit suffixes until the name is unique. The new session also sets `destroy-unattached off` so the session survives every attached client disconnecting. **Limits**: this option is best-effort; it does NOT survive a manual `tmux kill-session` or a tmux server restart. R12 will detect those events at the next checkpoint.

### R14 — Project-scoped runner lockfile (mkdir atomic)
`RUNNER_LOCKFILE_PATH` keys on `ROOT_HASH` (`shasum || sha1sum || cksum` of the repo root), so two different projects can run runners in parallel while the same project root is single-runner. `RUNNER_LOCKDIR` (`${RUNNER_LOCKFILE_PATH}.d`) is acquired by `mkdir` for true filesystem-level atomicity — no check-then-write race. Stale pids (no longer responding to `kill -0`) are reaped automatically; live duplicates exit 1 with a recovery hint.

## 8. Circuit Breaker

| Condition | Verdict |
|-----------|---------|
| context-latest.md unchanged for 3 consecutive iterations | BLOCKED |
| Same acceptance criterion fails 2 consecutive iterations | Upgrade model, retry once (Agent mode only; tmux: same model retry); if still failing → Architecture Escalation (§7¾) → BLOCKED |
| `cb_threshold` (default: 6) consecutive **fail** verdicts on `cb_threshold` unique criterion IDs | Upgrade to opus, retry once; if still failing → BLOCKED (adjustable via `--cb-threshold`; when `--consensus` is not `off`, effective threshold doubles automatically: default 6 → 12) |
| max_iter reached | TIMEOUT (report to user) |
| Same canonical block reason fires `BLOCK_CB_THRESHOLD` (default: 3) times in a row | Mission abort (`.sisyphus/mission-abort.json` + non-zero exit). US-021 R9 P2-I `consecutive_blocks` counter. |

The Leader tracks `consecutive_failures` in `status.json`:
- Increments on `fail`, resets on `pass`, **unchanged by `request_info`**.
- "Same error" = same acceptance criterion ID in two consecutive **fail** verdicts (`request_info` does not break or contribute to this chain).
- "Diverse failures" = `cb_threshold` most recent `fail` verdicts each have a unique criterion ID.

### consecutive_blocks (US-021 R9 P2-I)

`consecutive_failures` only counts `fail` verdicts; a worker that signals `blocked` does not advance it, so a contract defect (e.g., test-spec/PRD mismatch) can repeat silently for many iterations. `consecutive_blocks` closes that hole.

- Counter increments when the **canonical** block reason matches the previous block's reason (`_canonical_block_reason` strips wrapper prefixes like `hygiene_violated:` and `wrapped:` before comparison so R8 hygiene wrappers don't fragment the chain).
- Counter resets to 1 when a *different* canonical reason fires.
- `infra_failure` category is **exempt** — transient API/tmux/process failures are environment problems, not contract defects, and shouldn't trip the abort.
- The very first iteration (`ITERATION <= 1`) is **exempt** — mission setup blocks (e.g., missing PRD, init misconfig) shouldn't terminate before the first real attempt.
- When the counter reaches `BLOCK_CB_THRESHOLD` the runner writes `.sisyphus/mission-abort.json` (`{reason, count, last_reason, threshold, timestamp}`) and exits non-zero so wrappers can chain to the next mission instead of looping.

## 8½. Self-Verification Feedback Loop

When `--with-self-verification` is enabled, the SV report feeds back into the next brainstorm cycle:
- SV report identifies patterns: which US types fail most, which AC quality issues recur, which model tiers underperform.
- Next brainstorm SHOULD reference the prior campaign's SV report (if available) to inform US sizing, model selection, and AC quality standards.
- This creates an iterative improvement loop: campaign → SV report → next brainstorm → better campaign.
- The loop operates whether the reviewer is human or system — readiness to iterate is what matters.

## 9. Change Policy

- Changes to the shared workflow → modify this document
- Project-specific objectives/criteria → modify project-local files
- Init script changes → modify init_ralph_desk.zsh
