# N×M Self-Verification Matrix Harness

Runnable real-agent self-verification harness for the four
`(WORKER_ENGINE, VERIFIER_ENGINE) ∈ {codex, claude}²` cells, built to the
Self-Verification Methodology v2 spec (ADR-001-aligned).

It drives the **REAL** `launch_worker_*` / `launch_verifier_*` / `create_session`
functions from `src/scripts/run_ralph_desk.zsh` (the single canonical `--mode tmux`
leader per ADR-001) — it does **not** reimplement them. Each cell runs a trivial
deterministic task with anti-gaming evidence (random-nonce round-trip artifact +
schema-valid verifier verdict) and a fail-closed coverage ledger.

## Files

| File | Role |
|------|------|
| `assemble-base.zsh` | INV-7: regenerates the `main()`-stripped base from `run_ralph_desk.zsh` at gate time and asserts it differs by EXACTLY the 2 known edits (LIB_DIR pin, drop `main "$@"`). No checked-in snapshot. |
| `_preamble.zsh` | Harness-enforced isolation contract (INV-1..INV-4): `sv_capture_caller` (unset TMUX), `sv_assert_isolated` (exit 99 on violation), `safe_kill_session/pane`, `sv_teardown`. |
| `_cell_body.zsh` | One parameterized matrix cell: builds worker/verifier prompts, drives the real launch fns, applies the L1–L5 evidence ladder + timing band + nonce round-trip, writes `cell-result.json`. |
| `run-cell.zsh` | Assembles base+preamble+body, sets up a `/tmp` sandbox + distinct session, runs under a hard timeout, gated by `RLP_REAL_LLM_GATE=1`. |
| `run-matrix.zsh` | Runs all 4 cells serially and emits the fail-closed `results/matrix-<ts>.json` ledger. |
| `results/` | Per-run evidence dirs (gitignored): captures, `ANSWER.txt`, `verdict.json`, `cell-result.json`, regenerated base. |

## Run

```sh
# Full 4-cell matrix (real paid agents):
RLP_REAL_LLM_GATE=1 ./run-matrix.zsh

# Cheapest diagonal smoke (production default W=V=claude/haiku):
RLP_REAL_LLM_GATE=1 ./run-matrix.zsh C4

# A single cell:
RLP_REAL_LLM_GATE=1 ./run-cell.zsh C1 codex codex

# Deterministic INV-7 assembler self-test (NO LLM):
./assemble-base.zsh /tmp/base-check.zsh && diff ../../src/scripts/run_ralph_desk.zsh /tmp/base-check.zsh
```

Tunables (env): `WORKER_MODEL` / `VERIFIER_MODEL` (claude side, default `haiku`),
`WORKER_CODEX_MODEL` / `WORKER_CODEX_REASONING` (codex side, default `gpt-5.5`/`low`),
`ANSWER_BUDGET`, `TIMING_FLOOR_S`, `CELL_TIMEOUT_S`, `COST_BUDGET_USD`.

## Cells

| Cell | Worker | Verifier | Binaries | Notes |
|------|--------|----------|----------|-------|
| C1 | codex | codex | codex | both via `launch_*_codex` (`›` ready + codex activity words) |
| C2 | codex | claude | codex+claude | mixed-engine independence |
| C3 | claude | codex | claude+codex | reaches claude-only restart-recovery branch (492-512) |
| C4 | claude | claude | claude | production default; cheapest diagonal smoke |

## Evidence ladder (per cell — rc=0 is necessary-NOT-sufficient)

- **L1** `launch_*` rc==0
- **L2** engine ready glyph in a real `capture-pane` snapshot (codex `›` / claude `❯>›»`)
- **L3** engine telemetry activity marker (model-produced, not generic prompt words)
- **L4** worker nonce round-trip: `ANSWER.txt == reverse(NONCE)` on disk (echo-proof; reversed nonce is never verbatim in the prompt) + timing floor
- **L5** verifier `verdict.json` schema-valid AND cites the worker's reversed-nonce evidence (rubber-stamps cannot satisfy this)

Any rung failing ⇒ cell FAIL with the failing rung named. Missing required binary
⇒ BLOCKED (never PASS). Timeout ⇒ BLOCKED(timeout). The top-level ledger is
PASS only if all 4 cells `ran:true` AND `outcome:PASS`; any SKIPPED/BLOCKED ⇒ PARTIAL/BLOCKED.

## Isolation invariants (the main session can never die)

1. `sv_capture_caller` records `CALLER_SESSION`/`CALLER_PANE` then `unset TMUX`, forcing
   `create_session`'s isolated `tmux new-session -d` branch (INV-1).
2. `sv_assert_isolated` aborts (exit 99, BLOCKED-isolation) if `SESSION_NAME` rebound
   to the caller or panes equal caller panes (INV-2).
3. Teardown trap (`trap sv_teardown EXIT INT TERM`) kills ONLY the local `MYSESS`
   throwaway, never the mutable global, never a glob/kill-server (INV-3/INV-4).
   **Installed at top-level scope** — a zsh `trap ... EXIT` set inside a function
   fires on function return and would kill the session prematurely.
4. `/tmp` `mktemp -d` sandbox ROOT, git-init'd, never the repo checkout (INV-6).
5. `RLP_BACKGROUND=1` is set so `create_session` applies `destroy-unattached off`;
   without it the unattached throwaway session is reaped instantly and `WORKER_PANE`
   points at an already-destroyed pane.

## Substrate (ADR-001) — what this harness is and is NOT

- The 4 cells are intrinsically a **`--mode tmux`** (zsh leader) test — the four
  `launch_*` functions exist ONLY on that canonical leader.
- `--mode agent` (Node direct-CLI) is a DEAD non-target — it hard-errors `return 2`
  at `src/node/run.mjs:489-506`; the only permissible test of it is a labeled
  exit-2 deprecation guard, NEVER a campaign SV cell.
- `--mode native` (slash prose) is second-class; never satisfies the campaign KPI gate.
- Node engine unit tests are valid component evidence but never substitute for a
  tmux leader E2E.

### Note on `tests/self-verification-methodology.md`

Per the v2 spec, the **"Agent Mode Self-Verification" section (lines 65-95)** of
`tests/self-verification-methodology.md` is STALE: it mislabels the native path
with the deprecated leader's name and inverts substrate priority by listing it
first. It should be deleted/retitled and the doc led with the tmux canonical
substrate. That edit is tracked separately from this harness (this harness does
not modify the methodology doc).
