#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #4 verifier no-progress regression.
#
# Bug #4 was a regression of Bug #3: codex worker writes verdict to legacy
# .claude/ralph-desk/memos/ path instead of canonical .rlp-desk/memos/.
# Fix-D added legacyVerdictFile fallback in campaign-main-loop.mjs L1572 +
# signal-poller.mjs `legacySignalFile` last-chance branch.
#
# Asserts: legacy fallback branch exists in signal-poller and main loop
# wires the legacyVerdictFile parameter.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-04-verifier-noprogress-regression"
SCENARIO_DESCRIPTION="Codex legacy verdict path fallback (Bug #4 Fix-D)"
SCENARIO_BUG_CATEGORY="b-artifact-contract"
SCENARIO_HISTORICAL_BUG="Bug #4 (BOS 2026-05-05, regression of #3)"
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

  # A1: campaign-main-loop.mjs has legacyVerdictFile path field
  if grep -q "legacyVerdictFile" src/node/runner/campaign-main-loop.mjs; then
    echo "ASSERT A1 PASS: legacyVerdictFile path defined"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: legacyVerdictFile missing — Bug #4 Fix-D regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: legacyVerdictFile field removed"
  fi

  # A2: signal-poller.mjs has legacy fallback branch
  if grep -qE "legacySignalFile|legacyVerdictFile|Bug Report #4 Fix-D" src/node/polling/signal-poller.mjs; then
    echo "ASSERT A2 PASS: signal-poller legacy fallback branch present"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: signal-poller missing legacy fallback — Bug #4 Fix-D regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: signal-poller legacy fallback removed"
  fi

  # A3: prompt-assembler emits the strong "MUST write verdict to <abs path>"
  # rule (Fix-E) so codex doesn't infer legacy path from CWD
  if grep -qE "MUST write verdict to|verdictWritePath|Bug Report #4 Fix-E" src/node/prompts/prompt-assembler.mjs; then
    echo "ASSERT A3 PASS: prompt-assembler verdict-path directive present"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 FAIL: prompt-assembler verdict-path directive missing"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A3: prompt-assembler missing Fix-E directive"
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
