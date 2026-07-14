# Real-LLM SV Gate Scenarios

> **Spec**: `docs/plans/v0.16-real-llm-sv-gate-spec.md`
> **Plan**: `docs/plans/v0.15-stabilization-plan.md` Phase F.

Real campaigns + real claude/codex agents catching production failure modes that grep+unit tests cannot.

## Why

The 10 historical bugs (#1-#10, 2026-05-01..05-07) all passed the grep+unit SV gate before shipping. None were caught pre-release. Production failures live in LLM non-determinism, tmux pane lifecycle race timing, and recovery hygiene under partial state — none reproducible with mocks. This directory contains scenarios that run actual campaigns and assert on actual outcomes.

## Run

Default (dry-run, no LLM cost):

```bash
bash tests/sv-real-llm/scenarios/bug-10-relaunch-phase-verify-hygiene.test.sh
# → SKIPPED — RLP_REAL_LLM_GATE=1 to enable
```

Real run (LLM cost ~$1-3 per scenario):

```bash
RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/scenarios/bug-10-relaunch-phase-verify-hygiene.test.sh
```

Run all scenarios:

```bash
RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/run-all.sh
```

## Outcome format

Each scenario writes `tests/sv-real-llm/results/<date>-<scenario>.json`:

```json
{
  "scenario_id": "bug-10-relaunch-phase-verify-hygiene",
  "outcome": "PASS|FAIL|SKIPPED|ERROR",
  "started_at_utc": "2026-05-07T10:00:00Z",
  "ended_at_utc": "2026-05-07T10:03:24Z",
  "duration_seconds": 204,
  "cost_usd_estimate": 1.23,
  "log_path": "results/2026-05-07-bug-10.log",
  "captured_state_path": "results/2026-05-07-bug-10.bundle/",
  "assertions_passed": 3,
  "assertions_failed": 0,
  "failure_reason": null
}
```

On FAIL, the captured state bundle holds the campaign artifacts (status.json, sentinels, prompts, verdicts) for forensic reproduction.

## Cost discipline

- Each scenario declares `SCENARIO_COST_BUDGET_USD`. Runtime exceeding budget is FAIL.
- Each scenario declares `SCENARIO_TIMEOUT_SECONDS`. Hard timeout via `timeout` command.
- Aggregate budget for nightly suite: $50.
- Per-PR LIGHT subset: under $1, under 60s.

## Coverage roadmap

10 historical bugs → 10 scenarios. Each merged PR fixing a bug class adds the scenario for that class. See spec §8 for table.

## What this is NOT

- NOT a replacement for `tests/sv-gate-fast.sh` (grep + Node unit + zsh helper). Those stay.
- NOT auto-run on every PR by default. Real-LLM cost is bounded by explicit operator action.
- NOT a stress test or load test. Single-iter, single-US scenarios. Stress is a separate workstream.

## Nightly streak (B3 Stage-2 gate)

> **⚠ KNOWN LIMITATION — only 1 of the 5 B3 metrics is wired on the production zsh path,
> so a PASS streak is ADVISORY, not a flip authorization (updated 2026-06-30).**
> The zsh leader (the production `--mode tmux` backend) writes a `lifecycle_metrics` object
> into `campaign.jsonl` (B3 zsh-leader port: `lib_ralph_desk.zsh` accumulates in
> `LIFECYCLE_RECORDS`, `write_campaign_jsonl` flushes it), and B3-S1 **does** pass on
> production. **But only `pane_eof_to_cleanup_ms` is instrumented in the zsh leader** — the
> other four B3 metrics (`pane_reap_latency_ms`, `iter_signal_write_to_read_ms`,
> `verdict_write_to_read_ms`, `sentinel_lock_to_unlock_ms`) are measured only by the Node
> leader (`campaign-main-loop.mjs`, unreachable via `run` per ADR-001), so they **SKIP** in
> B3-S2 on the zsh path. The one wired band has been **refit for the zsh leader**
> (`pane_eof_to_cleanup_ms` = 10000ms, raised from the Node-calibrated 5000ms to envelope
> the zsh `_kill_pane_process` ~6.5s structural ceiling), so the earlier false-FAIL risk
> under `B3_STAGE2_BLOCKING=1` is resolved. **A PASS streak therefore reports
> `STREAK_OK_ADVISORY`, NOT `READY_TO_FLIP`** — do not set `B3_STAGE2_BLOCKING=1` off it,
> because only 1 of 5 metrics is value-gated on the leader that ships. The single remaining
> follow-up to make the gate authoritative is instrumenting the other four metrics in the
> zsh hot loop.
>
> **PROOF the zsh emit chain works (deterministic + both verify routes e2e):**
> - Deterministic (zero-cost): `tests/test_b3_pane_reap_integration.sh` drives the REAL
>   `_kill_pane_process` (the function the leader calls on every pane reap) on a real tmux
>   pane → `campaign.jsonl` → B3-S1 PASS. `tests/test_post_sentinel_reap_lock.sh` pins the
>   Bug #7 reap+lock-freeze invariant the same way.
> - Real-LLM, single-ALL verify route: `scenarios/b3-lifecycle-e2e.test.sh` pre-seeds an
>   operator-recovery state with an empty US_LIST → one live verifier reap (run:4152) →
>   `pane_eof_to_cleanup_ms` in `campaign.jsonl` → B3-S1 + B3-S2 PASS. The nightly's sole
>   B3 gate.
> - Real-LLM, per-US sequential-split route: `scenarios/bug-07-post-sentinel-race.test.sh`
>   uses a `### US-001` PRD so the ALL verify takes the per-US split (run:3991), exercising
>   the worker reap (run:3838) AND verifier reaps (run:2968/3075) — its `campaign.jsonl`
>   carries 2 lifecycle records. (bug-05 still carries no B3: it pre-seeds stale panes, so
>   there is no deterministic reap to measure.)

`harness/nightly-run.sh` is the automation that turns the per-scenario runner into the
3-night sample feeding the (currently advisory) `B3_STAGE2_BLOCKING` decision (runbook
§7.5.2; `docs/plans/v0.15-phase-b3-revalidation-findings.md` §4). It runs **`b3-lifecycle-e2e`
only** (the sole scenario that validates B3 end-to-end on the live zsh leader) with
`RLP_REAL_LLM_GATE=1` **and `B3_STAGE2_BLOCKING=1`** — so a Stage-2
band breach FAILs the night (→ INVESTIGATE) instead of a silent INFO PASS. It appends a
dated, scenario-set-stamped (`"set":"b3-e2e"`) verdict to `results/nightly-streak.jsonl`
and reports the streak; `evaluate_streak` counts only `set=b3-e2e` nights so stale
old-regime lines cannot leak in. The streak DOES value-gate B3 (`pane_eof_to_cleanup_ms`)
end-to-end; it stays `STREAK_OK_ADVISORY` only because the other four metrics are Node-only.

```bash
# one night (LLM cost ~$2-6):
RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/nightly-run.sh

# check streak status without running (no cost):
bash tests/sv-real-llm/harness/nightly-run.sh --eval-only
```

Streak verdicts:
- **STREAK_OK_ADVISORY** — N consecutive `set=b3-e2e` PASS nights (default 3). ADVISORY only:
  on the zsh leader only `pane_eof_to_cleanup_ms` is value-gated (its band IS now zsh-refit
  to 10000ms), so this does NOT authorize setting `B3_STAGE2_BLOCKING=1` — the remaining-metric
  instrumentation (the other four, currently Node-only) must land first (see limitation above).
- **NOT_YET** — fewer than N `set=b3-e2e` PASS nights logged; keep running.
- **INVESTIGATE** — a FAIL night in the window; do NOT flip. Per runbook §7.5.2: a Stage-1
  fail is a B4 telemetry regression (file an issue); Stage-2 band exceeded → re-run
  `node tests/sv-real-llm/lib/b3-band-revalidation.mjs` and refit bands.

Override the target with `RLP_NIGHTLY_STREAK_TARGET=N`. The streak evaluator is pinned by
`tests/test_nightly_streak.sh` (deterministic, no LLM cost).

### Scheduling (macOS launchd)

`harness/nightly.plist.template` is a LaunchAgent template. It is NOT auto-installed —
real-LLM cost accrues every night, so installation is a deliberate operator step:

1. Replace `__REPO__` (checkout path) and `__EXTRA_PATH__` (dirs for claude/codex/node/jq/tmux).
2. `cp` it to `~/Library/LaunchAgents/com.rlp-desk.nightly-sv.plist`
3. `launchctl load ~/Library/LaunchAgents/com.rlp-desk.nightly-sv.plist`
4. After ≥3 nights: `bash tests/sv-real-llm/harness/nightly-run.sh --eval-only` → expect
   STREAK_OK_ADVISORY (advisory only — see the limitation note above before any flip).

(Linux: wrap the same command in a cron entry / systemd timer instead.)

## Adding a new scenario

1. Copy `scenarios/_template.test.sh` to `scenarios/<bug-id-or-feature>.test.sh`
2. Fill in 4 parts: SETUP, EXERCISE, ASSERT, REPORT
3. Set the scenario header (ID, description, bug class, budget, timeout, requires)
4. Run dry-mode to verify SKIPPED message
5. Run real-mode with `RLP_REAL_LLM_GATE=1` to verify scenario actually catches the bug
6. Add to spec §8 coverage table
