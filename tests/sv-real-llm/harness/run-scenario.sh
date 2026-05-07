#!/usr/bin/env bash
# Real-LLM SV Gate — single scenario runner.
#
# Sources a scenario file, validates header, sets up sandbox, runs SETUP →
# EXERCISE → ASSERT → REPORT, captures artifacts on FAIL.
#
# Usage:
#   RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/run-scenario.sh <scenario-path>
#
# Exit codes:
#   0   PASS
#   1   FAIL
#   2   ERROR (harness failure, not scenario failure)
#   77  SKIPPED (gate not enabled or prerequisite missing)

set -uo pipefail

SCENARIO_PATH="${1:-}"
if [[ -z "$SCENARIO_PATH" ]]; then
  echo "ERROR: scenario path required" >&2
  exit 2
fi
if [[ ! -f "$SCENARIO_PATH" ]]; then
  echo "ERROR: scenario not found: $SCENARIO_PATH" >&2
  exit 2
fi

# Gate check — default OFF so accidental invocations don't burn LLM credits.
if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
  echo "SKIPPED: RLP_REAL_LLM_GATE=1 required to run real-LLM scenarios."
  echo "         Set RLP_REAL_LLM_GATE=1 explicitly to incur LLM cost."
  exit 77
fi

# Required tools.
for tool in tmux jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not on PATH" >&2
    exit 2
  fi
done

# At least one of claude / codex CLI must be available.
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: neither 'claude' nor 'codex' CLI on PATH" >&2
  exit 2
fi

# Source scenario header (read-only — extract metadata before running body).
SCENARIO_ID=""
SCENARIO_DESCRIPTION=""
SCENARIO_BUG_CATEGORY=""
SCENARIO_HISTORICAL_BUG=""
SCENARIO_COST_BUDGET_USD=""
SCENARIO_TIMEOUT_SECONDS=""

# Source in a subshell first to validate, then in main shell to actually run.
if ! ( source "$SCENARIO_PATH" > /dev/null 2>&1 ); then
  echo "ERROR: scenario failed to source cleanly: $SCENARIO_PATH" >&2
  exit 2
fi

# Now extract header values via grep+eval (header lines are simple assignments).
eval "$(grep -E '^SCENARIO_(ID|DESCRIPTION|BUG_CATEGORY|HISTORICAL_BUG|COST_BUDGET_USD|TIMEOUT_SECONDS)=' "$SCENARIO_PATH" | head -10)"

# Validate header completeness.
for required_var in SCENARIO_ID SCENARIO_DESCRIPTION SCENARIO_BUG_CATEGORY SCENARIO_COST_BUDGET_USD SCENARIO_TIMEOUT_SECONDS; do
  if [[ -z "${!required_var:-}" ]]; then
    echo "ERROR: scenario header missing required variable: $required_var" >&2
    exit 2
  fi
done

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/tests/sv-real-llm/results"
mkdir -p "$RESULTS_DIR"

DATE_STR=$(date -u +%Y-%m-%d)
TS_STR=$(date -u +%Y%m%dT%H%M%SZ)
RESULT_JSON="$RESULTS_DIR/${DATE_STR}-${SCENARIO_ID}.json"
RESULT_LOG="$RESULTS_DIR/${DATE_STR}-${SCENARIO_ID}.log"
CAPTURED_BUNDLE_DIR="$RESULTS_DIR/${DATE_STR}-${SCENARIO_ID}.bundle"

START_TS=$(date -u +%s)
START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "─────────────────────────────────────────────────"
echo "Scenario: $SCENARIO_ID"
echo "  $SCENARIO_DESCRIPTION"
echo "  bug class: $SCENARIO_BUG_CATEGORY${SCENARIO_HISTORICAL_BUG:+ ($SCENARIO_HISTORICAL_BUG)}"
echo "  budget: \$${SCENARIO_COST_BUDGET_USD} USD / ${SCENARIO_TIMEOUT_SECONDS}s"
echo "─────────────────────────────────────────────────"

# Run the scenario with timeout, capture stdout+stderr.
OUTCOME="ERROR"
FAILURE_REASON="harness exit before scenario report"
ASSERTIONS_PASSED=0
ASSERTIONS_FAILED=0

# Scenario must export OUTCOME, FAILURE_REASON, ASSERTIONS_PASSED, ASSERTIONS_FAILED
# at end. Harness captures via tmpfile.
SUMMARY_FILE=$(mktemp)
trap 'rm -f "$SUMMARY_FILE" 2>/dev/null' EXIT

(
  set -u
  source "$SCENARIO_PATH"
  # Scenarios SHOULD define a `run_scenario` function. Call it.
  if typeset -f run_scenario >/dev/null 2>&1 || declare -f run_scenario >/dev/null 2>&1; then
    if run_scenario; then
      OUTCOME="PASS"
      FAILURE_REASON=""
    else
      OUTCOME="FAIL"
      FAILURE_REASON="${SCENARIO_FAILURE_REASON:-run_scenario returned non-zero}"
    fi
  else
    OUTCOME="ERROR"
    FAILURE_REASON="scenario does not define run_scenario function"
  fi
  printf '%s|%s|%s|%s\n' "$OUTCOME" "$FAILURE_REASON" "${ASSERTIONS_PASSED:-0}" "${ASSERTIONS_FAILED:-0}" > "$SUMMARY_FILE"
) > "$RESULT_LOG" 2>&1 &
SCENARIO_PID=$!

# Enforce timeout.
TIMEOUT_REACHED=0
while kill -0 "$SCENARIO_PID" 2>/dev/null; do
  ELAPSED=$(( $(date -u +%s) - START_TS ))
  if (( ELAPSED >= SCENARIO_TIMEOUT_SECONDS )); then
    kill -TERM "$SCENARIO_PID" 2>/dev/null
    sleep 2
    kill -KILL "$SCENARIO_PID" 2>/dev/null
    TIMEOUT_REACHED=1
    break
  fi
  sleep 1
done
wait "$SCENARIO_PID" 2>/dev/null
SCENARIO_EXIT=$?

if (( TIMEOUT_REACHED )); then
  OUTCOME="FAIL"
  FAILURE_REASON="timeout (${SCENARIO_TIMEOUT_SECONDS}s exceeded)"
elif [[ -s "$SUMMARY_FILE" ]]; then
  IFS='|' read -r OUTCOME FAILURE_REASON ASSERTIONS_PASSED ASSERTIONS_FAILED < "$SUMMARY_FILE"
fi

END_TS=$(date -u +%s)
END_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DURATION=$(( END_TS - START_TS ))

# Cost estimate placeholder — real cost requires reading rlp-desk's
# cost-log.jsonl. For bootstrap, scenarios should self-report estimate.
COST_ESTIMATE="${SCENARIO_COST_USD_ACTUAL:-unknown}"

# Write result JSON.
cat > "$RESULT_JSON" <<EOF
{
  "scenario_id": "$SCENARIO_ID",
  "scenario_description": "$SCENARIO_DESCRIPTION",
  "bug_category": "$SCENARIO_BUG_CATEGORY",
  "historical_bug": "${SCENARIO_HISTORICAL_BUG:-}",
  "outcome": "$OUTCOME",
  "started_at_utc": "$START_ISO",
  "ended_at_utc": "$END_ISO",
  "duration_seconds": $DURATION,
  "cost_usd_estimate": "$COST_ESTIMATE",
  "cost_budget_usd": "$SCENARIO_COST_BUDGET_USD",
  "log_path": "$RESULT_LOG",
  "captured_state_path": "$CAPTURED_BUNDLE_DIR",
  "assertions_passed": $ASSERTIONS_PASSED,
  "assertions_failed": $ASSERTIONS_FAILED,
  "failure_reason": $(printf '%s' "${FAILURE_REASON:-}" | jq -Rs '.')
}
EOF

# Print summary.
echo ""
echo "─────────────────────────────────────────────────"
echo "Outcome: $OUTCOME (${DURATION}s)"
echo "Result : $RESULT_JSON"
echo "Log    : $RESULT_LOG"
[[ -n "${FAILURE_REASON:-}" ]] && echo "Reason : $FAILURE_REASON"
echo "─────────────────────────────────────────────────"

case "$OUTCOME" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  SKIPPED) exit 77 ;;
  *) exit 2 ;;
esac
