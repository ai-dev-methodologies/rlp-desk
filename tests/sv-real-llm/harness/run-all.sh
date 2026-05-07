#!/usr/bin/env bash
# Real-LLM SV gate — run all scenarios.
#
# Usage:
#   bash tests/sv-real-llm/harness/run-all.sh           # dry-run all (SKIPPED, no cost)
#   RLP_REAL_LLM_GATE=1 bash tests/sv-real-llm/harness/run-all.sh  # full run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIOS_DIR="$(cd "$SCRIPT_DIR/../scenarios" && pwd)"

PASS=0
FAIL=0
SKIPPED=0
ERROR=0

echo "═════════════════════════════════════════════════════════════════"
echo "Real-LLM SV gate — running all scenarios"
echo "Gate: ${RLP_REAL_LLM_GATE:-0} (set RLP_REAL_LLM_GATE=1 to enable)"
echo "═════════════════════════════════════════════════════════════════"

for scenario in "$SCENARIOS_DIR"/*.test.sh; do
  base=$(basename "$scenario" .test.sh)
  # Skip the template
  [[ "$base" == "_template" ]] && continue

  echo ""
  echo "[$base]"
  bash "$scenario"
  rc=$?
  case $rc in
    0)  PASS=$((PASS+1)) ;;
    1)  FAIL=$((FAIL+1)) ;;
    77) SKIPPED=$((SKIPPED+1)) ;;
    *)  ERROR=$((ERROR+1)) ;;
  esac
done

echo ""
echo "═════════════════════════════════════════════════════════════════"
echo "PASS=$PASS  FAIL=$FAIL  SKIPPED=$SKIPPED  ERROR=$ERROR"
echo "═════════════════════════════════════════════════════════════════"

if (( FAIL > 0 || ERROR > 0 )); then
  exit 1
fi
exit 0
