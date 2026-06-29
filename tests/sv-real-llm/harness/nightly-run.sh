#!/usr/bin/env bash
# Nightly real-LLM B3 Stage-2 sample runner (runbook §7.5.2).
#
# Runs the two B3 lifecycle scenarios (bug-05, bug-07) with the real-LLM gate AND
# lifecycle telemetry enabled, appends a dated verdict to
# results/nightly-streak.jsonl, and evaluates the 3-night PASS streak that gates the
# `B3_STAGE2_BLOCKING=1` flip (PR-B6 precondition; see
# docs/plans/v0.15.4-release-runbook.md §7.5.2 and
# docs/plans/v0.15-phase-b3-revalidation-findings.md §4).
#
# This is the missing automation piece: the scenarios + Stage 1/2 assertions already
# exist (run-scenario.sh, lib/b3-lifecycle-assertions.sh); this script schedules them,
# persists the streak, and reports readiness. Designed for launchd/cron — see
# nightly.plist.template and README.md "Nightly streak".
#
# Usage:
#   RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/nightly-run.sh   # full nightly (LLM cost ~$2-6)
#   bash tests/sv-real-llm/harness/nightly-run.sh --eval-only           # print streak status, no run, no cost
#   bash tests/sv-real-llm/harness/nightly-run.sh                       # dry-run: SKIPPED + streak status
#
# Env:
#   RLP_REAL_LLM_GATE=1            required to actually run (else SKIPPED, no cost)
#   RLP_NIGHTLY_STREAK_TARGET=N    consecutive PASS nights required (default 3, runbook §7.5.2)
#
# Exit: 0 night PASS / 1 night FAIL / 77 SKIPPED (gate off).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIOS_DIR="$(cd "$SCRIPT_DIR/../scenarios" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"
STREAK_LOG="${RLP_NIGHTLY_STREAK_LOG:-$RESULTS_DIR/nightly-streak.jsonl}"
STREAK_TARGET="${RLP_NIGHTLY_STREAK_TARGET:-3}"

SCENARIOS=(bug-05-worker-dead-on-reuse bug-07-post-sentinel-race)

# --- streak evaluation (pure: reads $1 log, target $2; prints a verdict line) ---
# Verdicts: READY_TO_FLIP | NOT_YET | INVESTIGATE. grep-based (no jq dep) so it is
# robust and unit-testable with a mock log.
evaluate_streak() {
  local log="$1" target="$2"
  if [[ ! -s "$log" ]]; then
    echo "NOT_YET: 0/$target consecutive PASS nights logged (no streak log yet)"
    return 0
  fi
  local recent total pass fail
  recent=$(tail -n "$target" "$log")
  total=$(printf '%s\n' "$recent" | grep -c '"night_verdict"')
  pass=$(printf '%s\n' "$recent" | grep -c '"night_verdict":"PASS"')
  fail=$(printf '%s\n' "$recent" | grep -c '"night_verdict":"FAIL"')
  if (( fail > 0 )); then
    echo "INVESTIGATE: $fail FAIL night(s) in the last $target — halt the B3_STAGE2_BLOCKING flip (runbook §7.5.2: Stage 1 fail = B4 regression; Stage 2 exceeded = refit bands)"
    return 0
  fi
  if (( total < target )); then
    echo "NOT_YET: $total/$target consecutive PASS nights logged — keep running nightly"
    return 0
  fi
  if (( pass == target )); then
    # ADVISORY ONLY — not a flip authorization. On the production zsh leader only
    # pane_eof_to_cleanup_ms is value-gated (the other 3 B3-S2 metrics are Node-only
    # and SKIP), and that band is still Node-calibrated. A PASS streak here therefore
    # does NOT establish that a release-blocking Stage 2 would be sound on the leader
    # that ships. Do NOT set B3_STAGE2_BLOCKING=1 off this signal until the zsh-leader
    # band refit lands (deferred follow-up; see README "Known limitation").
    echo "STREAK_OK_ADVISORY: $target consecutive PASS nights (pane_eof only on zsh; bands Node-calibrated) — NOT yet a B3_STAGE2_BLOCKING flip authorization; zsh band refit required first"
    return 0
  fi
  echo "NOT_YET: $pass/$target PASS in the last $target nights"
}

if [[ "${1:-}" == "--eval-only" ]]; then
  evaluate_streak "$STREAK_LOG" "$STREAK_TARGET"
  exit 0
fi

if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
  echo "SKIPPED: set RLP_REAL_LLM_GATE=1 to run the nightly (incurs LLM cost ~\$2-6)."
  echo "         Current streak status:"
  echo -n "  "; evaluate_streak "$STREAK_LOG" "$STREAK_TARGET"
  exit 77
fi

export RLP_LIFECYCLE_METRICS=1
# codex P1: run the scenarios with Stage-2 band-blocking ON. The flip trigger is
# "3 consecutive nights PASSING with B3_STAGE2_BLOCKING=1" (runbook line 275). With
# it OFF, a Stage-2 INFO band exceedance still records PASS, so three over-band nights
# would falsely reach READY_TO_FLIP. With it ON, a band breach FAILs the scenario →
# FAILs the night → INVESTIGATE, matching the README/runbook guidance.
export B3_STAGE2_BLOCKING=1
DATE=$(date -u +%Y-%m-%d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# codex P1: scalar verdicts, NOT `declare -A` — macOS launchd runs /bin/bash (3.2),
# which has no associative arrays. The scenario set is fixed (bug-05, bug-07).
oc_05=""; oc_07=""
for s in "${SCENARIOS[@]}"; do
  echo "─── nightly: $s ───"
  RLP_REAL_LLM_GATE=1 RLP_LIFECYCLE_METRICS=1 B3_STAGE2_BLOCKING=1 bash "$SCRIPT_DIR/run-scenario.sh" "$SCENARIOS_DIR/$s.test.sh"
  rc=$?
  v="FAIL"; [[ "$rc" -eq 0 ]] && v="PASS"; [[ "$rc" -eq 77 ]] && v="SKIPPED"
  case "$s" in
    bug-05-*) oc_05="$v" ;;
    bug-07-*) oc_07="$v" ;;
  esac
done

# A night is PASS only if BOTH scenarios PASS — which, with B3_STAGE2_BLOCKING=1, means
# Stage 1 present AND Stage 2 within bands. SKIPPED (gate/prereq not satisfied) or FAIL
# → not a valid PASS night.
if [[ "$oc_05" == "PASS" && "$oc_07" == "PASS" ]]; then night_verdict="PASS"; else night_verdict="FAIL"; fi

printf '{"date":"%s","ts":"%s","bug05":"%s","bug07":"%s","night_verdict":"%s"}\n' \
  "$DATE" "$TS" "$oc_05" "$oc_07" "$night_verdict" >> "$STREAK_LOG"

echo "═════════════════════════════════════════════════════════════════"
echo "Night $DATE: bug05=$oc_05 bug07=$oc_07 → $night_verdict"
echo -n "  "; evaluate_streak "$STREAK_LOG" "$STREAK_TARGET"
echo "═════════════════════════════════════════════════════════════════"

[[ "$night_verdict" == "PASS" ]] && exit 0 || exit 1
