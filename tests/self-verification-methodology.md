# RLP Desk Self-Verification Methodology (v2 — ADR-001-aligned)

## Overview

RLP Desk validates every change before it ships through **real-agent self-verification (SV)**: live Worker and Verifier LLM processes drive the canonical leader end to end, leave reviewer-replayable evidence on disk, and pass a fail-closed gate. This methodology follows the [Claude Agent Skills Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices#workflows-and-feedback-loops) feedback loop pattern: run → validate → fix → repeat.

> **Anti-gaming first principle (the reason this doc was rewritten):** prior "self-verification" frequently degenerated into scaffold-only checks, source-grep, `rc==0`-only assertions, or `echo`-simulation. **Those are BANNED as evidence.** Every campaign-level claim of PASS must come from a REAL LLM round-trip whose output is bound to a per-run random nonce, captured to disk, and replayable by a second agent or human without re-running the model. See the [N×M matrix](#nm-real-agent-matrix) and [anti-gaming predicates](#per-cell-real-execution-evidence-l1l5).

## Principles

1. **Feedback Loop**: Run test → validate evidence → fix errors → repeat until ALL pass.
2. **Evaluation-driven**: Pass criteria defined BEFORE claiming completion.
3. **Real execution only**: campaign SV is satisfied only by live agent processes producing nonce-bound artifacts; `echo`/grep/`rc==0`/Node-unit-as-E2E do NOT count.
4. **Iterative refinement**: observe → fix → re-test ALL (not just the failing one).
5. **No shortcuts**: it works or it doesn't ship. No "experimental" or "scaffold-only" labels.
6. **User approval required**: SV passes → report → user tests → user approves → deploy.

---

## Execution Substrate (ADR-001)

Per [ADR-001 — Leader Consolidation](../docs/plans/adr-001-leader-consolidation.md) (ACCEPTED 2026-06-17), there is exactly ONE canonical leader for any SV that exercises an end-to-end campaign:

| Mode | Status | Role in SV |
|------|--------|-----------|
| **`--mode tmux`** (zsh leader `src/scripts/run_ralph_desk.zsh`) | **CANONICAL** | The ONLY substrate with the full safety net (heartbeat/watchdog, copy-mode guard, prompt-stall + no-progress detection, model-upgrade chain, R12 lifecycle monitor) and real-tmux + real-campaign coverage. All campaign SV runs here. |
| `--mode agent` (Node direct-CLI) | **DEPRECATED — HARD-ERRORS** | Returns `2` at `src/node/run.mjs:489-506`. A **dead non-target.** The only permissible "test" is a labeled exit-2 deprecation-regression guard asserting `node run.mjs run X --mode agent` exits 2 — **NEVER a campaign SV cell.** |
| `--mode native` (slash prose / `Agent()`) | **SECOND-CLASS** | Permitted ONLY for short interactive checks. Every result MUST be stamped `(native: no watchdog/flywheel/SV)`, carries strictly less weight, and can **NEVER** satisfy the autonomous-campaign KPI gate. |
| Node engine unit tests (`src/node/**`, ~378 tests) | **COMPONENT-only** | Valid component-level evidence (retained per ADR-001), but **NEVER** a substitute for a tmux leader E2E. |

**Why tmux is intrinsic, not a preference.** The four engine-launch functions the matrix exercises exist ONLY on the zsh leader:

- `launch_worker_codex` (`run_ralph_desk.zsh:367`)
- `launch_worker_claude` (`:441`)
- `launch_verifier_codex` (`:521`)
- `launch_verifier_claude` (`:592`)

So the matrix is, by construction, a tmux-substrate test.

**How to drive it.** Either:
- `node run.mjs run <slug> --mode tmux` (the Node CLI forwards to the zsh leader), or
- append an `_sv_` body to a freshly **regenerated** `main()`-stripped copy of `run_ralph_desk.zsh` and call the REAL functions in their REAL load context (this is what the [N×M harness](#the-nm-harness-canonical-runner) does).

**Install-path note.** The zsh wrappers are NOT npm-installed (Node-canonical from v5.7+; `npm install` removes them). Reference the canonical `node run.mjs ... --mode tmux` invocation, **not** `~/.claude/ralph-desk/*.zsh`.

> **Removed legacy section.** A previous "Agent Mode Self-Verification" section described the AI acting as Leader and dispatching Worker/Verifier via `Agent()` in-session. That section is INVALID under ADR-001: it mislabeled the native/`Agent()` path with the deprecated leader's exact name and inverted substrate priority by listing it first. It has been deleted. The `Agent()`/native path is now governed by the SECOND-CLASS row above.

---

## N×M Real-Agent Matrix

Engine launch surface is `Worker engine ∈ {codex, claude} × Verifier engine ∈ {codex, claude}` = **4 cells**. All four MUST be exercised with **REAL agent processes** (never `echo`-simulation).

### The four cells

| Cell | Worker | Verifier | Required binaries | What it uniquely exercises |
|------|--------|----------|-------------------|----------------------------|
| **C1** | codex | codex | `CODEX_BIN` | Diagonal: `launch_worker_codex` / `launch_verifier_codex`; ready = `›` glyph; submit = codex activity vocabulary (`working\|thinking\|Exploring\|Running\|reading\|searching\|editing\|writing`). |
| **C2** | codex | claude | `CODEX_BIN`+`CLAUDE_BIN` | Off-diagonal: mixed-engine independence — codex worker + claude verifier (`wait_for_pane_ready` `{❯,>,›,»}` + shorter claude verifier word set). |
| **C3** | claude | codex | `CLAUDE_BIN`+`CODEX_BIN` | Off-diagonal: claude worker via `build_claude_cmd` reaches the **claude-only restart-recovery branch (`:492-512`)** that no other cell reaches; codex verifier (`›` ready). |
| **C4** | claude | claude | `CLAUDE_BIN` | **Production default** (`WORKER_ENGINE`/`VERIFIER_ENGINE` both default `claude` at `:196-197`). Cheapest smoke cell (run with claude/haiku). |

### Rationale (why the 2×2 is meaningful and non-redundant)

Each engine has a **distinct ready glyph** and a **distinct activity-word predicate**, so the four `(W,V)` cells run genuinely different detection code.

- **Diagonal cells (C1, C4)** exercise the per-engine ready/submit/restart paths each engine uniquely owns — notably the claude-only restart-recovery branch (`:492-512`) reachable ONLY through C3/C4.
- **Off-diagonal cells (C2, C3)** uniquely prove cross-role global-state **independence**: that `_auto_detect_engine` (`:206-212`) normalizes worker and verifier engine/model/effort independently and that no global state leaks between the two roles' launch functions.

The matrix multiplies ONLY the engine×role launch surface. It deliberately does **NOT** multiply orthogonal axes (verdict-schema parity, consensus topology, model-upgrade chain, per-US/batch accounting, autonomous-mode prompt contract) — those are kept as [separate targeted tests](#orthogonal-targeted-tests) so the live (paid) matrix stays minimal.

---

## Per-Cell Real-Execution Evidence (L1–L5)

A cell is **PASS only** when the full L1–L5 ladder holds **AND** the timing band holds **AND** isolation invariants INV-1..INV-4 held. **`rc==0` is necessary-NOT-sufficient.** Any rung failing ⇒ cell **FAIL with the failing rung NAMED** in the ledger.

| Rung | Requirement |
|------|-------------|
| **L1** | `launch_*` returns `rc==0`. |
| **L2** | Engine **ready glyph** present in a REAL `capture-pane` snapshot (codex `›` / claude `{❯,>,›,»}`). |
| **L3** | Engine **telemetry activity marker** in the model's response region (codex `tokens used` / `Worked for Ns` / spinner; claude `esc to interrupt` / token footer). Generic English words that also occur in the pasted instruction are NOT sufficient. |
| **L4** | **Worker nonce round-trip** (see anti-gaming below). |
| **L5** | **Verifier schema-valid `verdict.json`** citing the worker's real artifact. |

### Anti-gaming predicates (the heart of v2)

- **BANNED — fixed prompt-embedded sentinel.** The old fixed `SELFVERIFY_OK` sentinel (`_sv_codex_live_body.zsh:33/68`) is explicitly banned: a TUI `echo` can satisfy it.
- **L4 — Worker nonce round-trip (echo-proof).** The worker performs a tiny REAL task producing a `/tmp`-sandbox artifact whose content equals a **per-run RANDOM NONCE transform** (e.g. `ANSWER.txt == reverse(NONCE)`). The reversed nonce is **never present verbatim in the prompt**. PASS asserts (a) the artifact exists on disk in the sandbox, (b) its content == the nonce transform, (c) git shows the **worker** as author of the change.
- **L5 — Verifier verdict (echo-proof).** The verifier MUST WRITE `verdict.json` with `{status ∈ {pass,fail}, criteria_results:[{id,status,evidence}] length≥1, summary}`. At least one criterion's `evidence` MUST contain a value that could ONLY come from reading the worker's real artifact (the nonce transform). PASS asserts jq schema validity AND that the cited worker-produced value is present. A verifier that never ran, or rubber-stamps, cannot satisfy this. Off-diagonal cells (V≠W) additionally prevent one shared stub from satisfying both roles.
- **Timing plausibility band.** Assert a per-engine FLOOR (`>= ~2-3s`; sub-second "answers" are FAIL/stub-suspect) `<= elapsed_to_answer <= per-cell TIMEOUT_SECONDS`. Record `elapsed_s` in the ledger. An engine usage/token marker must independently corroborate that a model (not a `printf`) produced the text.
- **Evidence-region scoping.** L3 (activity) and L4 (answer) greps run ONLY on the model's response region BELOW the last prompt glyph, excluding harness-injected instruction lines and TUI chrome — so the pasted prompt cannot satisfy the predicates.
- **Per-run fresh evidence dir.** Each cell uses a unique evidence dir (`mktemp -d` or `results/<ts>-<cell>-<nonce>/`) with prior-artifact `rm` at cell start. PASS is bound to **THIS run's nonce**, so stale last-run evidence (old fixed `/tmp` paths) can never satisfy the current predicate. Every PASS cell leaves capture files + `verdict.json` + ledger on disk so a human or second agent can replay the nonce round-trip and verdict **WITHOUT re-running the LLM** (reviewer-replayable, auditable rather than self-asserted).
- **Binary presence + version capture.** At cell entry, hard-assert each required engine binary (`CODEX_BIN` and/or `CLAUDE_BIN` per the cell) resolves to a real executable and record `--version` into the ledger. `build_claude_cmd` emits an EMPTY-binary command if `CLAUDE_BIN` is unset, so a missing required binary marks the cell **BLOCKED** (NOT SKIPPED, NOT PASS) — preventing silent no-ops in mixed cells C2/C3.

**Banned as cell evidence:** `rc`-only, `echo`-simulation, source-grep, Node-unit-tests-as-leader-E2E.

---

## Isolation Invariants (harness-enforced)

The catastrophic failure this section prevents: `create_session()` (`run_ralph_desk.zsh:861-866`) silently REBINDS the global `SESSION_NAME`/`LEADER_PANE`/`WORKER_PANE`/`VERIFIER_PANE` to the CALLER's live tmux session when `$TMUX` is set (`:866` does `SESSION_NAME=$(tmux display-message -p '#{session_name}')`). A teardown that then `tmux kill-session -t "$SESSION_NAME"` would **destroy the user's main Claude Code session.** This actually happened with `_sv_codex_live_body.zsh`. These invariants are HARNESS-ENFORCED, not author-remembered.

| ID | Invariant |
|----|-----------|
| **INV-1** | **`unset TMUX` before `create_session`.** A shared preamble captures `CALLER_SESSION` + `CALLER_PANE` FIRST, then `unset TMUX`, forcing the isolated `tmux new-session -d -s $SESSION_NAME` branch (`:873-908`). |
| **INV-2** | **Post-create isolation ASSERT (loud abort).** Immediately after `create_session` and BEFORE any kill/split, assert `[[ -n $SESSION_NAME && $SESSION_NAME != ${CALLER_SESSION} && $SESSION_NAME == ${INTENDED_THROWAWAY} ]]` AND `WORKER_PANE/VERIFIER_PANE != CALLER_PANE`. On violation print `ISOLATION ASSERT FAILED` and exit 99 — mark cell **BLOCKED(isolation)**, never scored. This single control defeats the whole bug class regardless of an `unset-TMUX` mistake. |
| **INV-3** | **Mandatory trap covering EXIT INT TERM.** Every SV body MUST `trap '<safe teardown>' EXIT INT TERM` that captures the throwaway name into a LOCAL at creation (`MYSESS=$SESSION_NAME`) and kills ONLY that local — never the mutable global `SESSION_NAME`, never a glob/prefix, never `tmux kill-server`. Teardown must be idempotent and must NOT depend on reaching end-of-script. **Install the trap at TOP-LEVEL scope** — a zsh `trap ... EXIT` set inside a function fires on function return and would kill the session prematurely. |
| **INV-4** | **`safe_kill_session` / `safe_kill_pane` wrappers MANDATORY.** Refuse any target equal to a pre-captured `CALLER_SESSION`/`CALLER_PANE`. Raw `tmux kill-session`/`kill-pane` in an SV body is a gate failure. Forbid prefix/glob kills and `kill-server` in ALL modes. |
| **INV-5** | **Production Node→zsh path must strip TMUX.** `buildZshEnv` (`run.mjs:306-308`) does `{...parentEnv}`, propagating `$TMUX` verbatim to the spawned zsh child — so `node run.mjs run <slug> --mode tmux` launched from inside the operator's tmux makes `create_session` rebind to the caller session. SV/isolated runs MUST delete `TMUX`/`TMUX_PANE` from the forwarded child env (or `create_session` must honor an `RLP_ISOLATED=1` flag that forces the new-session branch). *(Status: documented; src change pending approval — see [open items](#open-items--follow-ups).)* |
| **INV-6** | **`/tmp` sandbox ROOT mandatory.** `ROOT=$(mktemp -d)`, git-init'd, never the rlp-desk checkout. A real Worker runs with `--dangerously-bypass-approvals-and-sandbox` / `--dangerously-skip-permissions` and CAN write outside ROOT by absolute path, so FS isolation is best-effort; ROOT must have no write-relevance to the repo. Forgetting `export ROOT` defaults it to `$PWD`, mutating repo state. |
| **INV-7** | **Deterministic regenerated base, never a snapshot.** The `main()`-stripped base is REGENERATED from `run_ralph_desk.zsh` at gate time (`sed -e 's#^LIB_DIR=...#LIB_DIR=<computed>#' -e '/^main "$@"$/d'`), asserted byte-identical to current `run_ralph_desk.zsh` apart from the two known edits before any cell runs, and gitignored. The checked-out `src/scripts/.run_src_verify.zsh` is a DRIFT HAZARD (untracked, hardcoded absolute `LIB_DIR`) and must NOT be relied on. |
| **INV-8** | **Parallel non-interference.** Every cell uses a DISTINCT SLUG (so `check_existing_sessions:843` `rlp-desk-${SLUG}-` grep isolates cells AND excludes real campaigns), a DISTINCT `mktemp -d` ROOT, and a DISTINCT session name embedding cell-id + `$$` + `$RANDOM` (set BEFORE `create_session`). Default execution is SERIAL; opt-in parallel ≤2 with a concurrency cap (shared tmux server + shared rate limits mean 4 concurrent cells / up to 8 live agents can exhaust limits and contaminate the signal). The end-of-suite sweep kills ONLY exact throwaway-prefixed session names, never a glob of a live campaign. |
| **INV-9** | **`tests/_sv_codex_tmux_body.zsh` must be converted before wiring.** As of this writing it calls the REAL `create_session` with NO `unset TMUX` and does raw `kill-pane` (`:102`) / decoy kill (`:117-121`) — one mutation from the live catastrophe. It MUST adopt the enforced preamble/wrappers before any gate uses it. |

---

## Pass Gates

- A cell is **PASS** only when the full L1–L5 ladder holds AND the timing band holds AND isolation INV-1..INV-4 held (no `BLOCKED(isolation)`). Any rung failing ⇒ cell **FAIL** with the named failing rung.
- **Top-level coverage ledger (`results/matrix-<ts>.json`) FAILS CLOSED.** Exactly 4 entries keyed `(worker_engine, verifier_engine)`, each carrying `ran:true|false`, `outcome ∈ {PASS,FAIL,BLOCKED,SKIPPED}`, `evidence_dir`, `worker_artifact_path`, `verifier_verdict_path`, `nonce`, `elapsed_s`, `failing_rung`, `binary_versions`. **Overall = PASS ONLY IF `count==4` AND all 4 `ran:true` AND all 4 `outcome:PASS`.** Any BLOCKED (missing binary / timeout / isolation) or SKIPPED (gate off) forces overall **PARTIAL/BLOCKED — NEVER PASS.** "Didn't run" must never be scored as "nothing failed" (the `SV_FAIL==0` convention is insufficient on its own).
- **Every live cell gated behind `RLP_REAL_LLM_GATE=1`** with per-cell `COST_BUDGET_USD` + `TIMEOUT_SECONDS` headers (mirrors `tests/sv-real-llm/harness/run-scenario.sh`). Timeout enforced with kill-TERM/KILL and recorded as `BLOCKED(timeout)` — never a silent hang, never PASS.
- **A gate check FAILS any `_sv_*_body.zsh`** that lacks a `trap` covering EXIT INT TERM, contains a raw `tmux kill-session`/`kill-pane`, or calls `create_session` without the enforced preamble.

### Orthogonal targeted tests

These run when THEIR specific surface changes, regardless of matrix tier, and **most require NO real LLM**:

- **Verdict-schema parity across engines** — fixture verdict files per engine satisfy the leader schema + consensus merge at `:2766`. (deterministic, no LLM)
- **Consensus** — forced-fail verifier ⇒ fix-contract emitted + `EFFECTIVE_CB_THRESHOLD` doubles (`:231`) + does-NOT-complete. (deterministic)
- **Model-upgrade chain** — stub worker forcing `_SAME_US_FAIL_COUNT>=2` (`:319`) ⇒ `check_model_upgrade` (`:3505`) ⇒ restore-on-pass (`:3441-3449`) ⇒ ceiling escalation (`:3544-3547`). (deterministic)
- **Per-US / batch accounting** — `per_us_coverage=PASS` and `us_id=ALL` on haiku. (engine-agnostic, cheap)
- **Autonomous-mode prompt contract** — grep the rendered prompt for the autonomous block when `AUTONOMOUS_MODE=1` + ambiguous PRD does not stop. (deterministic)
- **`--mode agent` deprecation-regression guard** — assert `node run.mjs run X --mode agent` exits `2` (`run.mjs:489-506`). (deterministic)

---

## When to Run (tiered, keyed to changed files)

The full 4-cell paid matrix is reserved for high-blast-radius changes, so authors are never tempted back to scaffold-only SV.

| Tier | Trigger | What runs |
|------|---------|-----------|
| **T0** | EVERY change | `sv-gate-fast`: grep code-patterns + Node unit tests + zsh unit tests. `<30s`, NO real LLM. |
| **T1** (default smoke) | Routine source changes | ONE diagonal cell **W=V=claude/haiku** (the production default `:196-197`, cheapest representative of what real users hit). |
| **T2** (launch-fn change) | Any edit to `launch_worker_codex` / `launch_worker_claude` / `launch_verifier_codex` / `launch_verifier_claude`, `create_session`, `build_claude_cmd`, `wait_for_pane_ready`, or the ready/submit predicates | **FULL 4-cell real-agent matrix** (all cells run different detection code; off-diagonal proves independence; C3/C4 reach the claude restart-recovery branch). |
| **T3** (governance / release) | Changes to `src/commands/rlp-desk.md`, `src/governance.md`, `src/scripts/init_ralph_desk.zsh`, or any release | **FULL 4-cell matrix + consensus + verdict-schema parity + model-upgrade chain + per-US/batch + autonomous targeted tests.** This satisfies the CLAUDE.md Self-Verification Gate's LOW/MEDIUM/CRITICAL trio. |

Every live tier (T1/T2/T3) runs behind `RLP_REAL_LLM_GATE=1` with per-cell budget + timeout. The orthogonal targeted tests run when THEIR specific surface changes regardless of tier, and most are deterministic (no LLM cost).

---

## The N×M Harness (canonical runner)

The canonical, built way to run the matrix lives in:

```
tests/sv-nxm-matrix/
```

It drives the REAL `launch_worker_*` / `launch_verifier_*` / `create_session` functions from `src/scripts/run_ralph_desk.zsh` (it does NOT reimplement them) and enforces every invariant above.

| File | Role |
|------|------|
| `assemble-base.zsh` | INV-7: regenerates the `main()`-stripped base at gate time and asserts the diff is EXACTLY the 2 known edits (LIB_DIR pin + drop `main "$@"`). No checked-in snapshot. |
| `_preamble.zsh` | Harness-enforced isolation (INV-1..INV-4): `sv_capture_caller` (`unset TMUX`), `sv_assert_isolated` (exit 99 on violation), `safe_kill_session`/`safe_kill_pane`, `sv_teardown` (top-level `trap`). |
| `_cell_body.zsh` | One parameterized cell: builds worker/verifier prompts, drives the real launch fns, applies the L1–L5 ladder + timing band + nonce round-trip, writes `cell-result.json`. |
| `run-cell.zsh` | Assembles base+preamble+body, sets up a `/tmp` sandbox + distinct session, runs under a hard timeout, gated by `RLP_REAL_LLM_GATE=1`. |
| `run-matrix.zsh` | Runs all 4 cells serially and emits the fail-closed `results/matrix-<ts>.json` ledger. |
| `results/` | Per-run evidence dirs (gitignored): captures, `ANSWER.txt`, `verdict.json`, `cell-result.json`, regenerated base. |

### Run

```sh
cd tests/sv-nxm-matrix

# Full 4-cell matrix (real paid agents); emits the fail-closed ledger:
RLP_REAL_LLM_GATE=1 ./run-matrix.zsh

# Cheapest diagonal smoke (production default W=V=claude/haiku):
RLP_REAL_LLM_GATE=1 ./run-matrix.zsh C4

# A single cell:
RLP_REAL_LLM_GATE=1 ./run-cell.zsh C1 codex codex

# Deterministic INV-7 assembler self-test (NO LLM):
./assemble-base.zsh /tmp/base-check.zsh
```

Tunables (env): `WORKER_MODEL` / `VERIFIER_MODEL` (claude side, default `haiku`), `WORKER_CODEX_MODEL` / `WORKER_CODEX_REASONING` (codex side, default `gpt-5.5`/`low`), `ANSWER_BUDGET`, `TIMING_FLOOR_S`, `CELL_TIMEOUT_S`, `COST_BUDGET_USD`. The harness self-sets `RLP_BACKGROUND=1` so `create_session` applies `destroy-unattached off` (without it the unattached throwaway session is reaped instantly and `WORKER_PANE` points at an already-destroyed pane). Every cell runs in a `/tmp` `mktemp -d` sandbox and an isolated tmux session — **the caller's main session is never targeted.**

### Smoke status (honest)

A REAL C1 smoke has run end-to-end: real codex `0.140.0` launched in an isolated tmux session, L1 (`launch_worker_codex` rc=0, 41s) + L2 (ready glyph) PASSED, evidence captured to disk, **caller session survived** and teardown left zero leftover sessions. The cell ultimately FAILED at L4 for an ENVIRONMENTAL reason (a codex auto-update prompt hijacked the worker), and the anti-gaming L4 check correctly REFUSED to PASS (`got='<none>'`). C2/C3/C4 are implemented but unverified in budget; C4 (claude/haiku diagonal) is the cheapest next verification target. See `tests/sv-nxm-matrix/README.md` and `results/` for replayable evidence.

---

## Three-Phase Debug Logging

Every campaign run with `DEBUG=1` produces structured logs that the leader emits and the gate validates:

```bash
grep '\[PLAN\]' debug.log     # What SHOULD happen (expected flow)
grep '\[EXEC\]' debug.log     # What ACTUALLY happened (every decision point)
grep '\[VALIDATE\]' debug.log # Was it CORRECT? (auto-validation)
```

### [PLAN] — Expected Execution Plan
Logged at startup. Captures configuration and expected flow:
```
[PLAN] slug=perus us_count=3 us_list=US-001,US-002,US-003
[PLAN] worker_engine=claude worker_model=sonnet
[PLAN] verify_mode=per-us consensus=0 max_iter=10
[PLAN] expected_flow=worker->verify(US-001)->worker->verify(US-002)->...->verify(ALL)->COMPLETE
```

### [EXEC] — Execution Events
Logged at every decision point during execution:
```
[EXEC] iter=1 phase=worker engine=claude model=sonnet dispatched=true
[EXEC] iter=1 worker_submit_check=OK attempts=1
[EXEC] iter=1 poll_signal_received=true
[EXEC] iter=1 phase=worker_signal status=verify us_id=US-001
[EXEC] iter=1 phase=verifier engine=claude model=opus scope=US-001 dispatched=true
[EXEC] iter=1 phase=verdict engine=claude verdict=pass us_id=US-001 issues=0
[EXEC] iter=1 verified_us_update=US-001 verified_us_total=US-001
```

Consensus-specific:
```
[EXEC] iter=1 phase=consensus_claude verdict=pass model=opus
[EXEC] iter=1 phase=consensus_codex verdict=pass model=gpt-5.5 reasoning=high
[EXEC] iter=1 phase=consensus round=1 claude=pass codex=pass combined_action=pass
```

### [VALIDATE] — Automatic Validation
Logged at cleanup. Compares plan vs execution:
```
[VALIDATE] verify_mode=per-us configured=true
[VALIDATE] per_us_coverage=PASS verified=3/3 us=US-001,US-002,US-003
[VALIDATE] dispatches worker=4 verifier=4
[VALIDATE] fix_loops=0
[VALIDATE] circuit_breakers_triggered=0
[VALIDATE] result=COMPLETE iterations=4 elapsed=760s verified_us=US-001,US-002,US-003
```

---

## Visible-Pane Self-Verification (Tmux Mode)

For interactive observation, SV can run in **visible tmux panes** so the user watches all roles in real time. This is the human-in-the-loop view of the same canonical `--mode tmux` substrate; it does NOT relax any isolation invariant above.

### Pane Layout

```
+------------------+------------------+------------------+
| Session pane     | Leader pane      | Worker pane      |
| Claude Code      | run_ralph_desk   |                  |
| (conversation)   | shell loop logs  +------------------+
| AI reports here  | visible output   | Verifier pane    |
+------------------+------------------+------------------+
```

### How it works
1. AI creates a **Leader pane** to the right of the session pane via `tmux split-window -h`.
2. The `run_ralph_desk.zsh` script runs **in foreground** in the Leader pane.
3. The runner script splits its pane further right into Worker/Verifier panes.
4. User observes all three: Leader loop output, Worker execution, Verifier execution.
5. AI monitors `debug.log` from the session pane (left) and reports results.
6. After completion, AI reads [PLAN]/[EXEC]/[VALIDATE] from `debug.log`.

### Pane safety rules
- **NEVER** kill the session pane (where Claude Code runs). The session pane is SACRED.
- Store the session pane ID at start; exclude it from all kill operations.
- Leader pane is created by AI, cleaned up by AI after each test.
- Worker/Verifier panes are created/cleaned by the runner script.
- Always verify pane ID before `tmux kill-pane`.
- **When SV launches the leader from inside the operator's tmux, INV-5 applies:** strip `TMUX`/`TMUX_PANE` (or set `RLP_ISOLATED=1`) so `create_session` does NOT rebind to the caller session.

---

## Recovery Patterns

### Instruction Delivery Failure
- Direct `tmux send-keys -l` + Enter (not `safe_send_keys`).
- Submit check loop: 15 attempts × 2s, checking for activity indicators.
- Adaptive retry at attempt 8: `C-u` clear + re-type instruction.
- If all attempts fail: log `worker_submit_check=FAILED`.

### Dead Worker/Verifier
- Kill-and-replace pattern (from omc-teams): `kill-pane` + `split-window`.
- Never use `respawn-pane`.
- Fresh pane gets a fresh claude/codex session.
- Dead pane ID discarded, new ID tracked.

### Permission Prompt Blocking
- Auto-detect "Do you want to" in pane capture.
- Auto-approve with Enter.
- Detected in: `safe_send_keys`, `wait_for_pane_ready`, `poll_for_signal`.

### Codex Update Prompt
- A codex auto-update prompt (`Update available X -> Y / Press enter to continue`) can hijack a worker launch: a submit-loop Enter selects "Update now", codex self-updates and exits, and the worker never produces its artifact.
- `wait_for_pane_ready` (`run_ralph_desk.zsh:1167`) dismisses this prompt, but `launch_worker_codex`'s own ready-wait loop does NOT — a known production-leader gap surfaced by the matrix harness. Mitigation for SV runs: pre-consume the update once before the matrix, or dismiss it in the cell's post-launch poll.

### Timeout with Active Worker
- Check `pane_current_command` — if `node`/`claude`/`codex`, the worker is alive.
- Re-poll the same iteration (don't increment).
- Only count as `monitor_failure` if the process is truly dead (`zsh`).

---

## Rules

- ALL tiers required for the change class must pass in ONE clean run before reporting to the user.
- Campaign SV PASS comes ONLY from real LLM execution with nonce-bound, reviewer-replayable evidence — never `echo`/grep/`rc==0`/Node-unit-as-E2E.
- Fix bugs immediately; don't defer to "next iteration".
- Re-run ALL tests after ANY fix, not just the failing one.
- The fail-closed ledger is authoritative: any BLOCKED/SKIPPED ⇒ NOT PASS.
- Panes must be cleaned up after completion (except during inspection).
- The current session pane is SACRED — never kill it; isolation invariants are harness-enforced, not author-remembered.
- commit/push/merge/publish requires explicit user approval.

---

## Open Items / Follow-ups

- **INV-5** (`buildZshEnv` must strip `TMUX`/`TMUX_PANE`, or honor `RLP_ISOLATED=1`) is documented but NOT yet implemented in `src/node/run.mjs` — a src change requiring approval.
- **Orthogonal targeted tests** (verdict-schema parity, consensus, model-upgrade, autonomous-prompt, `--mode agent` exit-2 guard) are specified above but not yet wired into a gate; decide between `sv-gate-fast` (deterministic, cheap) and a new `sv-gate-targeted`.
- **C2/C3/C4** live cells are implemented but unverified in budget; C4 (claude/haiku) is the cheapest next verification.
- **Per-engine calibration** — `COST_BUDGET_USD` and `TIMING_FLOOR_S` are placeholder defaults (`0.50 USD` / `3s`); one empirical calibration run should precede freezing them into headers.
- **`tests/_sv_codex_tmux_body.zsh`** must be converted to the enforced preamble/wrappers (INV-9) before any gate wires it in.
- **Nonce transform** — standardize on string-reverse (human-replayable) vs sha256-prefix (harder to fake); the harness currently uses reverse.
