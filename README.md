# RLP Desk

> Autonomous Claude Code campaigns — durable on-disk state, independent verifier governance, and cross-family consensus.

RLP Desk runs long-horizon Claude Code campaigns as a Worker/Verifier loop, and stakes its reliability on three things:

- **Durable file-based state** — campaign status is written atomically (write-then-rename), the verified ledger is an append-only JSONL record, and handoff artifacts (done-claims, verify-verdicts) are write-locked sentinels a finished pane cannot revise — all resumable and `jq`-inspectable. Kill the session, the terminal, the pane — the campaign resumes from where the files left off.
- **Independent verifier governance** — a separate fresh-context agent checks the Worker's claims against real evidence, governed by Iron Laws (no completion claims without fresh evidence) and an Evidence Gate protocol (IDENTIFY → RUN → READ → VERIFY → only then claim), with anti-rubber-stamp guidance against reflexive passes.
- **Cross-family consensus** — Worker and Verifier can run on different model families (Claude × Codex/GPT); in consensus mode, both must independently PASS before a campaign completes.
- **Deterministic pre-gates** — before any LLM verifier is dispatched, a mechanical layer (campaign gate script + built-in done-claim lint + execution-step replay) bounces machine-checkable failures straight back to the Worker in seconds. Machines catch what machines can catch; LLM verification rounds are spent on real defects only.

This rides on a **fresh-context loop**: each Worker/Verifier iteration starts with no prior conversation, reading only the PRD and the on-disk campaign state. That statelessness is the mechanism — durable state and independent verification are what it buys you, not the headline.

Below: the native-mode dispatch (`--mode native`, via `Agent()`). `--mode tmux` — the production default — runs Worker/Verifier as interactive Claude/Codex TUI tmux panes instead; see [Execution Modes](#execution-modes).

```
[Your Session = LEADER]
        │
  Agent()├──▶ [Worker (fresh context)]
        │     └── reads PRD + memory → implements → updates memory
        │
  Agent()└──▶ [Verifier (fresh context)]
              └── reads done-claim → runs checks → writes verdict
```

## What's new in v0.23.0

- **Luna-first cost routing.** Workers use evidence-gated escalation: `luna:high → luna:max → terra:max → sol:xhigh`.
- **Effort-aware iteration timeout.** Worker budgets scale with `:xhigh` and `:max` efforts.
- **Campaign cost summary.** Reports include estimated sol-equivalent Codex costs, escalation counts, and the final model.
- **Environment failure category.** Harness, tooling, capacity, and safety-refusal failures no longer climb the model ladder.

See [CHANGELOG.md](CHANGELOG.md) for the complete release notes.

## Deterministic Pre-Gates

Most Ralph-loop and autonomous-agent stacks verify an LLM's work with more LLM calls — every verification round pays the full model cost, and a large share of that cost re-checks things a script could have decided. RLP Desk puts a deterministic layer in front of the verifier: machine-checkable claims are settled by machines, in seconds, at zero token cost, and only what survives reaches an LLM. **Machines catch what machines can — LLM rounds are for real defects only.**

```
Worker done-claim
        │
        ▼
  Mechanical pre-gate  ── seconds, zero tokens
   ├─ L1    campaign gate script (typecheck / registry / anything you script)
   ├─ L1.5  built-in done-claim TDD-sequence lint (v0.22.17)
   └─ L2    execution_steps replay (claimed vs actual exit codes)
        │   any failure → bounce to Worker with a fix contract, no LLM dispatched
        ▼
  per-US LLM verification (fresh context)   ── real-defect judgment
        ▼
  cross-engine consensus (Claude × Codex)   ── optional, other-engine rebuttal
        ▼
  final verification                        ── once per campaign, last line of defense
```

When the Worker submits a done-claim, the mechanical pre-gate runs before any verifier is dispatched:

- **L1 — campaign gate script.** Anything you can script: typecheck, registry/lockfile checks, format lint. A non-zero exit rejects the claim without an LLM.
- **L1.5 — built-in done-claim TDD-sequence lint (v0.22.17).** A canonical predicate — `jq` on the zsh leader, a pure Node module on the Node leader, one governed spec (§3a) — checks that every acceptance criterion carries its own labeled `write_test → verify_red → implement → verify_green` steps, in order. Comma-separated lists count; the bundle label `all` does not. On failure the claim bounces back with per-AC step-index coordinates as a fix contract — zero tokens, no LLM round. The verifier is told the lint already passed, so it never re-litigates format. Opt out with `RLP_DONECLAIM_LINT=0`.
- **L2 — execution_steps replay.** The leader re-runs the commands the Worker claimed it ran and compares the actual exit codes against the claimed ones. A claim that does not reproduce is rejected before it can cost a verification round.

Any pre-gate failure returns a fix contract to the Worker and redispatches — no verifier is spawned, so the ~20-minute LLM round is never spent on a claim a script could reject.

The same mechanical discipline now guards the **contract side**, not just the Worker's claim (v0.22.22). Sealing a campaign with `gate-receipt` content-hashes the PRD *and* the test-spec, so a post-seal edit to either surfaces as drift at run start; a deterministic 3-doc consistency lint (PRD ↔ test-spec ↔ per-US split) hard-rejects structural drift at `init`; and every post-seal contract edit is appended to a `contract-revisions.jsonl` audit chain. Both the input contract and the output claim are held to machine checks before an LLM round is spent.

### Field results

From a production analytics campaign:

- **A false RED claim, caught in seconds.** A Worker claimed `verify_red` exited 1 (test failing before implementation); L2 replay got exit 0. The leader skipped the ~20-25 min LLM round entirely and redispatched with a fix contract:
  `Pre-gate L2 FAILED (replay mismatch: verify_red claimed=1 actual=0) — skipping LLM verification, redispatching Worker`
- **Format defects no longer burn LLM rounds.** A cross-engine verifier once failed the same story for two rounds (~65 minutes) purely on done-claim TDD label format — while all four acceptance criteria were verified green. That entire defect class is now settled in seconds by the built-in L1.5 lint.
- **Before / after.** Before the mechanical routing, the cross-engine leg sat at pass 0 / fail 15 — rounds of 20-25 minutes each, format and routing noise dominating. After the machine checks moved to machines, the very next story produced the campaign's first both-engines pass. **Cross-verification wasn't the waste — making an LLM do a machine's job was.**

This is the same provability story the rest of RLP Desk tells — the Evidence Gate, the append-only verified ledger, write-locked handoff artifacts — extended with a ratchet: every recurring failure class gets pushed down into the deterministic layer, where its recurrence cost trends to zero.

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
- **Work-Type Classification** — each US sorted into 명세형/발굴형/검증형 (specification / discovery / verification, IL-2¾): specification-type enters the loop, discovery-type is rejected to prior reconnaissance, and verification-type stays but is routed to the `verify_existing` gate so the TDD-RED mandate doesn't false-fail confirm-existing-behavior work
- **Models** — which Claude model for Worker/Verifier

### 3. Run

```bash
# Recommended (cross-engine + final consensus, luna-first cost lane):
/rlp-desk run <slug> --mode tmux --worker-model gpt-5.6-luna:high --consensus final-only --debug

# Claude-only:
/rlp-desk run <slug> --debug
```

The leader loop runs autonomously — spawning workers, verifying results, and tracking progress until completion or a circuit breaker triggers.

## Supported Platforms

- **macOS** — primary development platform.
- **Ubuntu Linux** — CI/server platform.
- Anything else (other Linux distros, WSL, BSD) is best-effort and unsupported: it may work, but issues specific to those environments are not a support priority.

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
  3. Select model (haiku/sonnet/opus — or full claude-* ids with effort — by complexity)
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
- Verifier minimum: claude sonnet (haiku cannot verify). Recommended per-US verifier is complexity-tiered (`claude-sonnet-5:high` up to `claude-opus-5:max` by risk) and final verifier `claude-fable-5:max` — version-pinned ids so the tier does not drift when aliases remap

Tables below show the **recommended** config that `brainstorm` proposes per risk level (you can override any flag). Worker cells are the campaign-starting model; the Worker auto-upgrades on repeated failure per `src/model-upgrade-table.md`. Verifier cells are version-pinned ids so the tier does not drift when aliases remap. Unspecified flags fall back to their plain defaults (`--verifier-model sonnet`, `--final-verifier-model opus`).

#### 1. Claude-only (codex not installed)

Same-engine Worker and Verifier share blind spots — install codex for cross-engine detection.

| Risk | Worker | Per-US Verifier | Final Verifier | Consensus |
|------|--------|-----------------|----------------|-----------|
| LOW | haiku | claude-sonnet-5:high | claude-fable-5:max | off |
| MEDIUM | sonnet | claude-opus-5:low | claude-fable-5:max | off |
| HIGH | opus | claude-opus-5:high | claude-fable-5:max | off |
| CRITICAL | opus | claude-opus-5:max | claude-fable-5:max + human | off |

Worker auto-upgrade ladder: haiku → sonnet → opus (ceiling). Final: **claude-fable-5:max solo** ⚠ same-engine warning displayed.

#### 2. Cross-engine: GPT-5.6 (codex installed, recommended, luna-first)

Codex worker + claude verifier — different engines catch each other's blind spots. Worker defaults to the **luna-first cost lane** — the cheapest capable GPT-5.6 tier, escalating on failure (codex-cli 0.144 catalog); the verifier legs stay on claude, complexity-tiered.

| Risk | Worker (cost lane) | Per-US Verifier (claude) | Final Verifier (claude) | Consensus (per-US leg) |
|------|----------------|--------------------------|-------------------------|-----------|
| LOW | gpt-5.6-luna:high | claude-sonnet-5:high | claude-fable-5:max | final-only (gpt-5.6-luna:max) |
| MEDIUM | gpt-5.6-luna:xhigh | claude-opus-5:low | claude-fable-5:max | final-only (gpt-5.6-terra:high) |
| HIGH | gpt-5.6-luna:max | claude-opus-5:high | claude-fable-5:max | all (gpt-5.6-sol:medium) |
| CRITICAL | gpt-5.6-sol:high | claude-opus-5:max | claude-fable-5:max + human | all (gpt-5.6-sol:high) |

HIGH-complexity campaigns also get a **speed lane** (`gpt-5.6-sol:medium` worker, skipping the terra quota hop) for time-sensitive work; `brainstorm` asks which lane to use whenever HIGH-complexity US are present (no question when all US are LOW/MEDIUM, none for CRITICAL — those are lane-independent). Final consensus (all complexities): **gpt-5.6-sol:xhigh**. Both engines must PASS → COMPLETE. Worker auto-upgrade — cost lane: `luna:high → luna:max → terra:max → sol:xhigh` (ceiling); speed lane HIGH: `sol:medium → sol:high → sol:xhigh`.

> **Alternatives (still supported, not headline presets):** previous-generation codex models `gpt-5.5` and `gpt-5.4` / `gpt-5.4-mini` (low..xhigh ladders) if the account lacks GPT-5.6 access; and `spark` (`gpt-5.3-codex-spark`) — ultra-fast, but only for small tasks that fit its 100k context window (single-file, AC ≤ 4). See `src/model-upgrade-table.md` for the full catalog.

#### Final Verify

Recommended values shown; if the flags are left unset the final verifier defaults to `opus` and the final codex consensus leg to `gpt-5.6-sol:xhigh`.

| Environment | Engine 1 (claude) | Engine 2 (codex) | Rule |
|-------------|-------------------|------------------|------|
| Claude-only | claude-fable-5:max | — | Solo ⚠ |
| Cross-engine | claude-fable-5:max | gpt-5.6-sol:xhigh | Both must PASS → COMPLETE |

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

> Default below is the CLI/canonical default (`tmux`). Invoked via the `/rlp-desk run` slash
> command without an explicit `--mode`, the default is `native` instead — see [Execution Modes](#execution-modes).

| Option | Default | Description |
|--------|---------|-------------|
| `--mode tmux\|native\|agent` | tmux | tmux=zsh Leader (production default); native=slash-command-only; agent=hard-errors (ADR-001) |
| `--worker-model MODEL` | haiku | Worker model. Plain name or claude id incl. `:effort` = claude; any other `model:reasoning` = codex. A colon alone does NOT mean codex. E.g. `opus:max`, `claude-fable-5:max`, `spark:high` |
| `--lock-worker-model` | off | Disable auto model upgrade on failure |
| `--verifier-model MODEL` | sonnet | per-US verification model (lighter; recommended per complexity: `claude-sonnet-5:high`/`claude-opus-5:low`/`claude-opus-5:high`/`claude-opus-5:max`) |
| `--final-verifier-model MODEL` | opus | final ALL verification model (stricter; recommended `claude-fable-5:max`) |
| `--consensus off\|all\|final-only` | off | Cross-engine consensus scope |
| `--consensus-model MODEL` | gpt-5.6-terra:high | per-US cross-verifier — codex leg only (lighter) |
| `--final-consensus-model MODEL` | gpt-5.6-sol:xhigh | final cross-verifier — codex leg only (stricter) |
| `--verify-mode per-us\|batch` | per-us | per-us: verify each US → final ALL |
| `--cb-threshold N` | 6 | Consecutive failures → BLOCKED |
| `--max-iter N` | 100 | Max iterations → TIMEOUT |
| `--iter-timeout N` | 600 | Per-iteration timeout seconds (tmux only); effort-aware — effective worker budget ×1.5 for `:xhigh` and ×2.0 for `:max` (worker only; verifier/consensus waits use the base value) |
| `--debug` | off | Debug logging |
| `--with-self-verification` | off | Post-campaign SV report |

#### Per-US vs Final Verification

RLP Desk runs two distinct verification passes:

- **Per-US** (`--verifier-model`, default: sonnet) — runs after each user story completes. Lightweight and fast, catches issues early before later stories build on broken foundations.
- **Final ALL** (`--final-verifier-model`, default: opus) — runs once after all user stories pass individually. Stricter and more thorough, catches cross-US integration issues and anything per-US missed.

When `--consensus` is enabled, a second cross-engine verifier runs alongside each pass: `--consensus-model` for per-US and `--final-consensus-model` for the final ALL gate. Both engines must pass.

### Init Presets

After `brainstorm`, `init` detects your environment and presents run command presets:

- **Codex detected (recommended)** → cross-engine + final consensus, luna-first cost lane (`--worker-model gpt-5.6-luna:high --consensus final-only`)
- **Codex detected (small tasks: single-file, AC <= 4)** → spark preset (`--worker-model spark:high --consensus final-only`; spark has a 100k context limit)
- **Codex detected (critical)** → full consensus on every verify (`--worker-model gpt-5.6-sol:high --consensus all`)
- **Claude-only** → defaults to `--debug` with haiku worker and opus final verifier
- **Basic** → minimal flags for quick iteration

The brainstorm phase evaluates complexity (US count, file scope, logic, dependencies, code impact) and recommends a starting model. You can override any recommendation.

## Execution Modes

RLP Desk has three execution modes, all honoring the same governance protocol. **`--mode tmux` is the canonical, recommended path for any real campaign** (see [ADR-001](docs/plans/adr-001-leader-consolidation.md)).

> **Mode status:**
> - **`--mode tmux`** (zsh-backed) — **stable / production / canonical.** Full safety net (heartbeat,
>   copy-mode guard, prompt-stall timeout, no-progress detection, model upgrade chain). Use this for
>   long campaigns and autonomous loops.
> - **`--mode native`** (the slash-command **default**) — the current Claude Code session is the Leader,
>   dispatching via `Agent()`. Works anywhere (no tmux), good for short/interactive use, but is a
>   second-class companion: no iteration watchdog, turn-based pauses possible. Not for long unattended runs.
> - **`--mode agent`** (direct Node CLI) — **HARD-ERRORS (exit 2)** per [ADR-001](docs/plans/adr-001-leader-consolidation.md).
>   The direct-CLI Node leader was retired; the Node leader code (`campaign-main-loop.mjs`) is a dormant mirror
>   used only by the `--mode native` slash path's `Agent()` engine and its tests. Use `--mode tmux`.

### Environment Compatibility

| Environment | Native (slash-only) | Tmux (canonical, CLI default) | Agent |
|-------------|------------------|------------------|--------------------|
| Claude Code (any terminal) | **Works** (slash) | Requires tmux | Hard-errors (ADR-001) |
| Inside tmux session | **Works** (slash) | **Works** — panes split in current window | Hard-errors (ADR-001) |
| Outside tmux session | **Works** (slash) | **Rejected** — "start tmux first" | Hard-errors (ADR-001) |

### Choosing Your Mode

| Need | Use |
|------|-----|
| Production / autonomous / overnight / CI campaigns | `--mode tmux` (canonical, CLI default) |
| Quick interactive exploration, no tmux available | `/rlp-desk run … --mode native` (slash-command only) |
| ~~Direct-Node-CLI~~ | `--mode agent` hard-errors (ADR-001) — use `--mode tmux` |

### Native Mode (slash-command default) — "Smart Mode"

```
/rlp-desk run calculator        # defaults to --mode native
```

The current Claude Code session acts as the Leader, dispatching Workers and Verifiers via `Agent()`. The Leader is an LLM that dynamically routes models and reasons about context.

- Works anywhere — no tmux required
- Dynamic model routing — Leader upgrades models on failure
- Fix Loop — extracts verifier issues and feeds them back to the next worker
- Best for short, interactive development

**Known limitation:** Native mode runs inside Claude Code's turn-based request-response model. If the LLM outputs text without a tool call, the turn terminates and the loop pauses until the user sends "continue." This is a platform constraint — the protocol mitigates it but cannot guarantee 100% uninterrupted execution. **For guaranteed autonomous loops, use `--mode tmux`.**

### Tmux Mode — "Lean Mode"

```
/rlp-desk run calculator --mode tmux
```

**Requires running inside a tmux session.** A shell script takes over as Leader, splitting your current window into panes. Workers run interactive `claude` sessions — you can watch them work in real-time.

**Launch paths (both canonical).** Started *inside* a tmux session, the Leader anchors on its own pane via `$TMUX_PANE` (v0.22.19+) and splits Worker/Verifier off it — even with several tmux clients attached, it can never adopt another client's active pane. Started *outside* any tmux session, the runner fails fast (`start tmux first`) rather than guessing a target. Either way, every campaign pane is created inside the tmux session the Leader owns and never lands in an unrelated session.

**Canonical layout — two forms.** The Leader pane is a pane-creation *anchor*, not a log viewer, but it stays visible at a readable width (never collapsed) so you can always see what is running — the runner enforces this and the single-right-column geometry on every create/recreate path (a mismatch stops the campaign rather than drifting silently).

When your own shell is the Leader (human operator), it is a 3-pane layout:

```
+---------------------+---------------------+
| Your pane (Leader)  | Worker pane         |  ← -h split off Leader
| shell loop running  | claude TUI running  |
| polls signal files  | you see it working  |
|                     +---------------------+
|                     | Verifier pane       |  ← -v split off Worker
|                     | claude TUI running  |
|                     | (only when needed)  |
+---------------------+---------------------+
```

When the operator pane is an AI CLI (e.g. a Claude Code session) it cannot host the shell Leader, so the operator creates a dedicated pane and launches the runner in it (the runner anchors on that pane via `$TMUX_PANE`) — a 4-pane layout (owner mandate: the Leader stays visible at a readable width, never hidden):

```
+-------------+--------+---------------------+
| Operator    | Leader | Worker pane         |  ← -h split off Leader
| pane        | pane   |---------------------|
| (AI CLI —   | (shell | Verifier pane       |  ← -v split off Worker
|  not the    |  loop, |---------------------|
|  Leader)    |  shown)| (Consensus pane)    |  ← -v split off Verifier
+-------------+--------+---------------------+
```

The operator pane is outside the runner's control (it only assumes it exists). Worker, Verifier, and the optional Consensus pane always form ONE right column stacked top-down; a new pane appearing in a second column, another window, or another session is drift the runner blocks. The split width (`RLP_LEADER_SPLIT_WIDTH`, default 110) is a readability comfort width, not a tmux hard minimum — on a genuinely narrow terminal, lower it to avoid a startup width error.

- Real-time visibility — watch Worker/Verifier execute live
- Zero-token orchestration — shell loop, not LLM
- Automatic cleanup — panes removed on completion
- Self-healing stalls — a codex "model at capacity" freeze is auto-resumed with bounded retries (`RLP_CAPACITY_*` knobs) before failing fast with an explicit `model capacity` BLOCKED, so a transient capacity wall doesn't silently burn the iteration budget (v0.22.18)
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

Uses Claude Code's `Agent()` tool (agent mode) or `claude -p` CLI (tmux mode). Supports dynamic model routing (haiku/sonnet/opus, or full `claude-*` ids with an effort suffix such as `claude-opus-5:high`).

### Codex (opt-in)

```bash
# Install codex CLI first
npm install -g @openai/codex

# Run with codex worker (recommended: luna-first, cheapest capable tier)
/rlp-desk run calculator --worker-model gpt-5.6-luna:high

# Frontier model + reasoning effort (HIGH/CRITICAL work)
/rlp-desk run calculator --worker-model gpt-5.6-sol:high

# spark — ultra-fast, small tasks only (100k context: single-file, AC <= 4)
/rlp-desk run calculator --worker-model spark:high

# Cross-engine: codex worker, claude verifier (recommended)
/rlp-desk run calculator --worker-model gpt-5.6-luna:high --consensus final-only --debug
```

The engine is inferred automatically from the `--worker-model` value: a plain model name (`haiku`) OR any claude id — short alias or full `claude-*`, with or without an effort suffix (`opus:max`, `claude-opus-5:high`) — routes to Claude; any other `model:reasoning` (`spark:high`, `gpt-5.6-luna:high`) routes to Codex. A colon does NOT imply Codex. The `codex` binary is only required when a codex model is specified.

Every codex launch injects `-c check_for_update_on_startup=false` (v0.22.21) to suppress the startup "Update available!" dialog, which can otherwise freeze a TUI pane since its key handling shifts between codex releases; set `RLP_CODEX_UPDATE_CHECK=1` to restore codex's default update check.

| Engine | Agent Mode | Tmux Mode | Dynamic Routing |
|--------|-----------|-----------|-----------------|
| claude | `Agent()` tool | `claude -p` TUI | Yes (haiku/sonnet/opus, + `claude-*` ids) |
| codex  | `Bash("codex ...")` | `codex` TUI | No (static model) |

## Verification Modes

### Per-US Verification (default)

Each user story is verified independently, then a final full verification runs:

```
Worker: US-001 → Verifier(per-US): US-001 only → pass
Worker: US-002 → Verifier(per-US): US-002 only → pass
...
Final Verify: claude-fable-5:max + gpt-5.6-sol:xhigh → both pass → COMPLETE
```

Per-US catches issues early before later stories build on broken foundations.

### Batch Verification

```
/rlp-desk run calculator --verify-mode batch
```

Worker completes all stories, then a single verification checks all AC at once. Final verify still applies.

## Autonomous Mode

By default, Worker and Verifier stop and ask for human input when they encounter document conflicts (e.g., PRD says one thing, test-spec says another) or ambiguous instructions. This breaks unattended execution.

**`--autonomous`** enables fully unattended campaigns:

```bash
/rlp-desk run my-feature --mode tmux --worker-model gpt-5.6-luna:high --autonomous --debug
```

### How it works

When `--autonomous` is active:

1. **PRD is the single source of truth.** Resolution priority: `PRD > test-spec > context > memory`
2. **No stopping for questions.** Worker and Verifier make autonomous decisions based on the priority chain
3. **All conflicts are logged.** Every decision is recorded in `conflict-log.jsonl` for post-campaign review

### Conflict log

Each conflict is logged as a JSONL entry in `logs/<slug>/conflict-log.jsonl`:

```json
{
  "iteration": 1,
  "us_id": "US-001",
  "source_a": "worker-prompt",
  "source_b": "prd",
  "conflict": "US-00 is required by the iteration prompt but is not defined as a PRD user story.",
  "resolution": "Followed PRD as source of truth."
}
```

### When to use

- **Long-running campaigns** that run overnight or while you're away
- **High-iteration tasks** where stopping for every ambiguity wastes hours
- **Well-defined PRDs** where the PRD is comprehensive and authoritative

### When NOT to use

- **Exploratory work** where you want to review each decision
- **Ambiguous PRDs** where conflicts indicate real design gaps that need human judgment
- **First run of a new project** — run without `--autonomous` first to catch PRD issues interactively

### Post-campaign review

After the campaign, review the conflict log to identify systemic issues:

```bash
cat .rlp-desk/logs/<slug>/conflict-log.jsonl | jq .
```

Common patterns:
- **Repeated PRD vs test-spec conflicts** — test-spec needs updating to match PRD
- **Scope lock vs fix contract conflicts** — governance rules may need tuning
- **Missing PRD definitions** — Worker created stories not in the PRD (add them or tighten the brainstorm)

## Project Structure

After `init`, your project gets this scaffold:

```
your-project/
├── .claude/
│   └── settings.local.json          # rlp-desk permissions (auto-added by init)
└── .rlp-desk/                        # scaffold (v0.13.0+; was .claude/ralph-desk/)
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
        ├── status.json
        └── runs/superseded-<ts>/         # prior-run evidence, relocated never deleted (v0.22.23)
```

A bare restart or `init --mode fresh|improve` no longer overwrites or deletes a prior
run's per-iteration evidence (done-claim, verify-verdict, iter-signal) or `verified.jsonl` —
those receipts are **relocated** into `logs/<slug>/runs/superseded-<ts>/` so the live paths
start clean while past verdicts survive. `ledger-seed --evidence` accepts the archived
paths, so a past pass verdict can be re-bound to a revised PRD (v0.22.23).

### Local Settings

`init` automatically adds the following permissions to `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Read(.rlp-desk/**)",
      "Edit(.rlp-desk/**)",
      "Write(.rlp-desk/**)"
    ]
  }
}
```

**Why:** Since v0.13.0 the scaffold lives at `.rlp-desk/` (outside `.claude/`), so Claude Code's `.claude/` sensitive-file gate no longer blocks Worker/Verifier writes. These explicit `.rlp-desk/**` permissions are a belt-and-suspenders helper that keeps automated loop execution prompt-free.

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

## Lifecycle Observability (v0.15.4+, default ON since v0.22.0)

Structured tmux/process lifecycle telemetry is always on for both the Node and zsh (`--mode tmux`) leaders (the `RLP_LIFECYCLE_METRICS` opt-out flag was removed in v0.22.4 after two default-ON release cycles with no opt-out use).

```bash
node ~/.claude/ralph-desk/node/run.mjs run my-slug --mode tmux            # telemetry on by default
```

Five metrics are emitted per iteration:

| Metric | Meaning |
|---|---|
| `iter_signal_write_to_read_ms` | Worker FS write → leader poll resolve |
| `verdict_write_to_read_ms` | Verifier FS write → leader poll resolve |
| `pane_eof_to_cleanup_ms` | Kill-start → process-exit-confirmed (`killPaneProcess` + `waitForProcessExit` settle) |
| `pane_reap_latency_ms` | Same window as `pane_eof_to_cleanup_ms` — recorded in addition to it only when the reap follows a sentinel observation, tagged with `sentinel_type` |
| `sentinel_lock_to_unlock_ms` | per sentinel type, lock vs unlock pair |

**Where they land:**
- `debug.log` — `[LIFECYCLE]` tagged lines (per emission)
- `campaign.jsonl` — batched `lifecycle_metrics` object per iteration record (canonical authoritative source)

**When to enable:**
- Investigating tmux race windows or leader-poll latency
- Pre-merge real-LLM SV scenarios (`bug-05` / `bug-07` two-stage assertions consume this telemetry)
- Long-running campaigns where lifecycle SLO tracking matters

**See also:** `docs/rlp-desk/failure-modes.md` for known race patterns the metrics catch.

## Documentation

- [Architecture](docs/rlp-desk/architecture.md) — Design philosophy, Agent() and tmux execution modes
- [Getting Started](docs/rlp-desk/getting-started.md) — Step-by-step tutorial with the calculator example
- [Protocol Reference](docs/rlp-desk/protocol-reference.md) — Full protocol specification
- [Failure Modes Atlas](docs/rlp-desk/failure-modes.md) — known failure patterns + recovery procedures
- [Future Plans](docs/rlp-desk/TODO-verification-next.md) — P3 items and upcoming features

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

[MIT](LICENSE)
