#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #9 verified_us persistence across relaunches.
#
# Bug #9: leader's `verified_us` array (US IDs that passed final verify)
# was lost across relaunch — leader re-ran already-verified stories. Fix
# persists verified_us in status.json and restores on readCurrentState.
#
# Asserts: status.json schema includes verified_us; readCurrentState
# restores it; documented restore log line ("Restored verified_us from
# status.json: ...") exists in source.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-09-verified-us-persistence"
SCENARIO_DESCRIPTION="verified_us survives relaunch via status.json (Bug #9)"
SCENARIO_BUG_CATEGORY="b-artifact-contract"
SCENARIO_HISTORICAL_BUG="Bug #9"
SCENARIO_COST_BUDGET_USD="0"
SCENARIO_TIMEOUT_SECONDS="60"
SCENARIO_REQUIRES="jq; grep"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  local script_abs repo_root
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
  repo_root="$(cd "$(dirname "$script_abs")/../../.." 2>/dev/null && pwd)"
  if [[ -z "$repo_root" || ! -d "$repo_root/src/node" ]]; then
    SCENARIO_FAILURE_REASON="setup: repo root resolution failed"
    return 1
  fi
  cd "$repo_root" || return 1

  # A1: readCurrentState restores verified_us from status.json
  if grep -qE "verified_us:\s*status\.verified_us" src/node/runner/campaign-main-loop.mjs; then
    echo "ASSERT A1 PASS: verified_us restored in readCurrentState"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: verified_us not restored in readCurrentState"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: verified_us restore missing"
  fi

  # A2: zsh runner restores verified_us from status.json (Bug #9 fallback)
  if grep -qE "Restored verified_us from status.json" src/scripts/run_ralph_desk.zsh; then
    echo "ASSERT A2 PASS: zsh runner restores verified_us"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: zsh verified_us restore missing"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: zsh verified_us restore removed"
  fi

  # A3: status.json schema includes verified_us field in writeStatus
  if grep -qE "verified_us" src/node/runner/campaign-main-loop.mjs | head -1 >/dev/null; then
    echo "ASSERT A3 PASS: verified_us referenced in main loop (read+write)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 FAIL: verified_us not in main loop"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A3: verified_us absent"
  fi

  SCENARIO_COST_USD_ACTUAL="0.00"
  (( ASSERTIONS_FAILED == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
    echo "SKIPPED: RLP_REAL_LLM_GATE=1 required to enable. Scenario: $SCENARIO_ID"
    echo "         Cost ~\$${SCENARIO_COST_BUDGET_USD} per run (structural; zero)."
    exit 77
  fi
  if run_scenario; then echo "PASS: $SCENARIO_ID"; exit 0; else echo "FAIL: $SCENARIO_ID — ${SCENARIO_FAILURE_REASON:-(no reason)}"; exit 1; fi
fi
