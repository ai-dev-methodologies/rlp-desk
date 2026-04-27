# rlp-desk E2E Test Scenarios (v5.7 §4.25)

> Two-tier coverage: **Tier A** (deterministic injection, ~ms) runs in `sv-gate-fast`; **Tier B** (real-subprocess + real-tmux + real-claude, seconds–minutes) runs in `sv-gate-full`. Every fix path is covered by at least one tier.

## Tier A — Deterministic injection (sv-gate-fast)

Uses `pollForSignal` injection seam (no subprocess spawn) — deterministic, fast, CI-stable.

| Scenario | Test file | Asserts |
|----------|-----------|---------|
| writeSentinelExclusive O_EXCL race | `tests/node/test-sentinel-exclusive.mjs` | First-writer-wins, parent dir create, EEXIST returns no-op, parallel race |
| Backstop: missing scaffold | `tests/node/test-leader-exit-invariant.mjs` | `_ensureTerminalSentinel` writes `blocked.md` even on `ensureScaffold` throw |
| Backstop: pollForSignal throws | `tests/node/test-leader-exit-invariant.mjs` | `_handlePollFailure` writes BLOCKED + run() returns blocked status |
| Backstop: idempotent first-writer-wins | `tests/node/test-leader-exit-invariant.mjs` | Pre-existing BLOCKED is NOT overwritten by backstop |
| Lying worker (signal missing) | `tests/node/test-lying-worker.mjs` | BLOCKED `infra_failure/worker_exited_without_artifacts` |
| Lying verifier (per-US verdict missing) | `tests/node/test-lying-worker.mjs` + `tests/node/sv-e2e/test-lying-verifier.mjs` | BLOCKED `verifier_exited_without_artifacts` |
| Lying final verifier (US-ALL) | `tests/node/sv-e2e/test-lying-verifier.mjs` | BLOCKED `final_verifier_exited_without_artifacts` |
| Prompt-blocked (default-No worker) | `tests/node/sv-e2e/test-prompt-blocked.mjs` | BLOCKED `prompt_blocked` |
| Prompt-blocked (default-No verifier) | `tests/node/sv-e2e/test-prompt-blocked.mjs` | BLOCKED `prompt_blocked` (verifier role) |
| Schema: empty object | `tests/node/test-artifact-schema.mjs` | No crash |
| Schema: wrong slug | `tests/node/test-artifact-schema.mjs` | BLOCKED `contract_violation/malformed_artifact` |
| Schema: us_id outside set | `tests/node/test-artifact-schema.mjs` | BLOCKED `malformed_artifact` |
| Schema: iteration regress | `tests/node/test-artifact-schema.mjs` | BLOCKED `malformed_artifact` |
| Schema: iteration not integer | `tests/node/test-artifact-schema.mjs` | BLOCKED `malformed_artifact` |
| Schema: signal_type mismatch | `tests/node/test-artifact-schema.mjs` | BLOCKED `malformed_artifact` |
| Schema: valid signal (back-compat) | `tests/node/test-artifact-schema.mjs` | No false positive |
| Auto-dismiss prompt patterns (24+) | `tests/node/test-prompt-dismisser.mjs` | Each `(y/n)`/`[Y/n]`/`[y/N]` variant + scrollback + unknown-fast-fail + claude v2.x trust |
| Shell quote (Bug 1) | `tests/node/test-shell-quote.mjs` | POSIX single-quote escape for `[1m]` etc. |
| Opus 1M context | `tests/node/test-opus-1m-context.mjs` | `ANTHROPIC_BETA` prefix, isOpusModel detection |

**Tier A total**: 50+ tests across 11 files. Runtime: ~0.7s. Always runs in CI.

## Tier B — Real-subprocess (sv-gate-full)

Uses real tmux session + real `tmux send-keys` / `capture-pane` / real claude haiku CLI. Slow (~5min) but exercises actual production paths.

| Scenario | Test | Asserts |
|----------|------|---------|
| Real tmux: `[Y/n]` auto-dismiss | `tests/sv-gate-real-e2e.sh` | Real `tmux send-keys Enter` after `auto_dismiss_prompts` |
| Real tmux: `[y/N]` BLOCK | `tests/sv-gate-real-e2e.sh` | `infra_failure` sentinel written, NO Enter sent |
| Real tmux: 10s no-progress timeout | `tests/sv-gate-real-e2e.sh` | BLOCKED on freeze regardless of prompt |
| Real tmux: unknown text + no bracket | `tests/sv-gate-real-e2e.sh` | No false BLOCK, no false Enter |
| Real tmux: unknown phrasing + `[y/N]` | `tests/sv-gate-real-e2e.sh` | Fast-fail BLOCK (10min wait avoided) |
| Real tmux: unknown phrasing + `(y/n)` | `tests/sv-gate-real-e2e.sh` | Fast-fail BLOCK |
| Real tmux: codex `[Y/n]` | `tests/sv-gate-real-e2e.sh` | Auto-dismiss (codex CLI variant) |
| Real tmux: codex `[y/N]` | `tests/sv-gate-real-e2e.sh` | BLOCK |
| Real tmux: scrollback contamination | `tests/sv-gate-real-e2e.sh` | Old `[Y/n]` + active `[y/N]` → BLOCK (scan-all) |
| Real haiku campaign (happy path) | `tests/sv-gate-full.sh` (inline) | `complete.md` written; trust prompt auto-dismissed; tests pass; commit recorded |

**Tier B total**: 10+ scenarios. Runtime: ~5 min (1 min for tmux scenarios + ~4 min for haiku campaign). Run before merge / release.

## Coverage matrix (per fix)

| Fix | Tier A | Tier B | Bug ID |
|-----|--------|--------|--------|
| zsh `[1m]` glob | shell-quote | (haiku campaign launches Opus models when promoted) | Bug 1 |
| tmux silent SV/flywheel | us012 | (haiku campaign exercises tmux mode) | Bug 2/3 |
| auto_dismiss prompts | prompt-dismisser | real-e2e #1-9 | Bug 4 |
| A4 fallback prompt guard | a4_fallback | (haiku campaign) | Bug 5 |
| scrollback contamination | prompt-dismisser | real-e2e #9 | §4.17.b |
| unknown-prompt fast-fail | prompt-dismisser | real-e2e #5-6 | §4.18 |
| Node iterTimeout fwd | (verified by haiku campaign actually completing in ≤300s) | full | §4.19 |
| claude v2.x trust prompt | prompt-dismisser | full (haiku triggers it) | §4.20 |
| capture window -50 + whitespace norm | prompt-dismisser | full (haiku narrow-pane wrap) | §4.21 |
| WorkerExitedError | lying-worker | (full campaign covers happy path; injection covers exit) | §4.22 |
| tail-15 normalized matching | prompt-dismisser | real-e2e | §4.23 |
| writeSentinelExclusive O_EXCL | sentinel-exclusive | (full campaign uses it for complete.md) | §4.24 |
| run() try/finally backstop | leader-exit-invariant | (full campaign verifies success path) | §4.24 §1g |
| _handlePollFailure | lying-worker, lying-verifier, prompt-blocked | (full campaign success path) | §4.25 |
| validateArtifact schema | artifact-schema | full (haiku artifacts schema-compliant) | §4.25 P1 |

Every fix has at least one Tier A test. Tier B exercises the production-realistic paths (real tmux, real subprocess, real claude haiku).

## Running the gates

```sh
# Fast gate (~0.7s, every commit)
zsh tests/sv-gate-fast.sh
# or
npm run sv-gate:fast

# Full gate (~5 min, before merge/release)
zsh tests/sv-gate-full.sh
# or
npm run sv-gate:full
```

`sv-gate-full` requires:
- Inside a tmux session (`echo $TMUX` non-empty)
- `claude` CLI in PATH with valid auth
- `node >= 16` in PATH
- `~/.claude/ralph-desk/` synced from latest `src/` (run `bash install.sh`)

## Adding a new scenario

1. **Determine tier**:
   - Deterministic, no subprocess → Tier A
   - Requires real tmux/claude/network → Tier B
2. **Tier A**: add `tests/node/sv-e2e/test-<name>.mjs` (or extend existing file). Use `pollForSignal` injection seam. Update `NODE_TESTS` array in `tests/sv-gate-fast.sh`.
3. **Tier B**: add scenario to `tests/sv-gate-real-e2e.sh` with `reset_pane_state` between scenarios. The script auto-runs in `sv-gate-full.sh`.
4. **Document**: add row to the Coverage matrix in this file.
5. **Verify**: run `npm run sv-gate:fast` (Tier A) or `npm run sv-gate:full` (both tiers); both must exit 0.
