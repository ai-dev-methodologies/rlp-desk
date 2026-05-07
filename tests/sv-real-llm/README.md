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

## Adding a new scenario

1. Copy `scenarios/_template.test.sh` to `scenarios/<bug-id-or-feature>.test.sh`
2. Fill in 4 parts: SETUP, EXERCISE, ASSERT, REPORT
3. Set the scenario header (ID, description, bug class, budget, timeout, requires)
4. Run dry-mode to verify SKIPPED message
5. Run real-mode with `RLP_REAL_LLM_GATE=1` to verify scenario actually catches the bug
6. Add to spec §8 coverage table
