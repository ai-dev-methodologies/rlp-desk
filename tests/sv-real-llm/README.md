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

> **⚠ KNOWN LIMITATION — B3 telemetry is orphaned on the production path (2026-06-29).**
> The B3-S1 assertion reads a non-null `lifecycle_metrics` object from `campaign.jsonl`.
> That field is written **only by the Node leader** (`src/node/runner/campaign-main-loop.mjs`
> via `src/node/util/lifecycle-metrics.mjs`, PR-B4). The Node leader is reachable only
> through the Native-agent path — the CLI `run` command hard-errors `--mode agent`
> (ADR-001) and `--mode tmux` delegates to the **production zsh leader**, whose
> `write_campaign_jsonl` (lib_ralph_desk.zsh) has **no `lifecycle_metrics` field** and
> emits only one of the five metrics (`pane_eof_to_cleanup_ms`) to `debug.log`, never to
> `campaign.jsonl`. So under the production (`--mode tmux`) path the B3 scenarios FAIL
> B3-S1 and the nightly perpetually reports **INVESTIGATE** — not a flake, a structural
> gap. Making the gate real on production requires porting the lifecycle collector into
> the zsh leader's `write_campaign_jsonl` — a converged-tool production change that
> ralplan consensus deferred (adjacent to the also-deferred PR-B6 metrics-flip). Until
> that is done, the harness machinery is correct but the underlying B3 telemetry it
> samples is Node-leader-only. (Fixture drift — US-heading `### ` anchoring per D-23 and
> the v0.13.0+ context/memory scaffold requirement — was fixed in the scenarios so they
> at least reach the leader; the orphan is the remaining, separate blocker.)

`harness/nightly-run.sh` is the automation that turns the per-scenario runner into the
3-night sample that gates the `B3_STAGE2_BLOCKING=1` flip (runbook §7.5.2;
`docs/plans/v0.15-phase-b3-revalidation-findings.md` §4 + runbook line 275). It runs
bug-05 + bug-07 with `RLP_REAL_LLM_GATE=1 RLP_LIFECYCLE_METRICS=1` **and
`B3_STAGE2_BLOCKING=1`** — so a Stage-2 band breach FAILs the night (→ INVESTIGATE)
instead of recording a silent INFO PASS; the flip trigger is 3 consecutive nights
passing *with* Stage-2 blocking on. It appends a dated verdict to
`results/nightly-streak.jsonl` and reports the streak.

```bash
# one night (LLM cost ~$2-6):
RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/nightly-run.sh

# check streak status without running (no cost):
bash tests/sv-real-llm/harness/nightly-run.sh --eval-only
```

Streak verdicts:
- **READY_TO_FLIP** — N consecutive PASS nights (default 3) → safe to set `B3_STAGE2_BLOCKING=1`.
- **NOT_YET** — fewer than N PASS nights logged; keep running.
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
4. After ≥3 nights: `bash tests/sv-real-llm/harness/nightly-run.sh --eval-only` → expect READY_TO_FLIP.

(Linux: wrap the same command in a cron entry / systemd timer instead.)

## Adding a new scenario

1. Copy `scenarios/_template.test.sh` to `scenarios/<bug-id-or-feature>.test.sh`
2. Fill in 4 parts: SETUP, EXERCISE, ASSERT, REPORT
3. Set the scenario header (ID, description, bug class, budget, timeout, requires)
4. Run dry-mode to verify SKIPPED message
5. Run real-mode with `RLP_REAL_LLM_GATE=1` to verify scenario actually catches the bug
6. Add to spec §8 coverage table
