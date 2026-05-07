#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #6 claude worker idle false-positive.
#
# Bug #6: claude worker pane shows "no progress" (frozen byte stasis) but
# iter-signal.json was already written. Fix-M added _worker_pane_has_signal
# short-circuit in zsh check_no_progress before BLOCKED escalation.
#
# Asserts: helper exists in lib_ralph_desk.zsh AND check_no_progress wires
# it correctly.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-06-claude-worker-idle-noprogress"
SCENARIO_DESCRIPTION="claude worker idle false-positive short-circuit (Bug #6 Fix-M)"
SCENARIO_BUG_CATEGORY="a-tmux-process-lifecycle"
SCENARIO_HISTORICAL_BUG="Bug #6 (BOS 2026-05-06)"
SCENARIO_COST_BUDGET_USD="0"
SCENARIO_TIMEOUT_SECONDS="120"
SCENARIO_REQUIRES="zsh; jq; grep"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  local script_abs repo_root
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
  repo_root="$(cd "$(dirname "$script_abs")/../../.." 2>/dev/null && pwd)"
  if [[ -z "$repo_root" || ! -d "$repo_root/src/scripts" ]]; then
    SCENARIO_FAILURE_REASON="setup: repo root resolution failed"
    return 1
  fi
  cd "$repo_root" || return 1

  # A1: helper _worker_pane_has_signal defined in run_ralph_desk.zsh
  if grep -qE "^_worker_pane_has_signal\(\)" src/scripts/run_ralph_desk.zsh; then
    echo "ASSERT A1 PASS: _worker_pane_has_signal helper defined"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: _worker_pane_has_signal missing — Bug #6 Fix-M regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: Bug #6 helper removed"
  fi

  # A2: check_no_progress wires the short-circuit
  if grep -qE "if _worker_pane_has_signal" src/scripts/run_ralph_desk.zsh; then
    echo "ASSERT A2 PASS: check_no_progress wires the short-circuit"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: short-circuit wiring missing"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: short-circuit unwired"
  fi

  # A3: zsh integration test for Bug #6 still passes
  if zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 | grep -qE "PASS=[1-9][0-9]* FAIL=0"; then
    echo "ASSERT A3 PASS: bug6 worker-idle integration test green"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 FAIL: bug6 integration test broken"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A3: bug6 integration test failure"
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
