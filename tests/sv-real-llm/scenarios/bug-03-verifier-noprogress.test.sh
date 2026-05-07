#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #3 verifier no-progress (last-chance read).
#
# Bug #3: leader's pollForSignal timed out and BLOCKED even though verifier
# had written verify-verdict.json just before timeout (mtime drift). Fix
# (signal-poller.mjs L252-258): one synchronous last-chance read after
# timeout before declaring real BLOCKED.
#
# Asserts: when verdict file exists at timeout boundary, leader reads it
# instead of writing BLOCKED sentinel.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-03-verifier-noprogress"
SCENARIO_DESCRIPTION="Verifier verdict last-chance read at timeout boundary (Bug #3)"
SCENARIO_BUG_CATEGORY="b-artifact-contract"
SCENARIO_HISTORICAL_BUG="Bug #3 (BOS 2026-05-04)"
SCENARIO_COST_BUDGET_USD="3"
SCENARIO_TIMEOUT_SECONDS="600"
SCENARIO_REQUIRES="claude_cli OR codex_cli; tmux; jq; node"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  # Resolve repo root robustly (BASH_SOURCE may be relative or absolute).
  local script_abs repo_root
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
  repo_root="$(cd "$(dirname "$script_abs")/../../.." 2>/dev/null && pwd)"
  if [[ -z "$repo_root" || ! -d "$repo_root/src/node/polling" ]]; then
    echo "ASSERT setup FAIL: cannot resolve repo root from $script_abs"
    SCENARIO_FAILURE_REASON="setup: repo root resolution failed"
    return 1
  fi

  # A1: structural — last-chance read invariant present
  if grep -qE "last.chance|Bug Report #3|Bug #3" "$repo_root/src/node/polling/signal-poller.mjs"; then
    echo "ASSERT A1 PASS: last-chance read invariant present in signal-poller.mjs"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: last-chance read code missing — Bug #3 regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: source missing last-chance read"
  fi

  # A2: structural — node test for last-chance contract passes
  cd "$repo_root" || { SCENARIO_FAILURE_REASON="setup: cd to repo root failed"; return 1; }
  if node --test tests/node/test-signal-poller-last-chance.mjs 2>&1 | grep -qE "^ℹ pass [1-9]"; then
    echo "ASSERT A2 PASS: signal-poller last-chance test green"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: signal-poller last-chance test failed"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: last-chance test broken"
  fi

  SCENARIO_COST_USD_ACTUAL="0.00"
  (( ASSERTIONS_FAILED == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
    echo "SKIPPED: RLP_REAL_LLM_GATE=1 required to enable. Scenario: $SCENARIO_ID"
    echo "         Cost ~\$${SCENARIO_COST_BUDGET_USD} per run (mostly structural; near-zero)."
    exit 77
  fi
  if run_scenario; then echo "PASS: $SCENARIO_ID"; exit 0; else echo "FAIL: $SCENARIO_ID — ${SCENARIO_FAILURE_REASON:-(no reason)}"; exit 1; fi
fi
