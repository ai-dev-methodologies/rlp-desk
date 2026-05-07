#!/usr/bin/env bash
# Real-LLM SV gate scenario TEMPLATE.
#
# Copy to <bug-id-or-feature>.test.sh and fill in the 4 parts.
# Header is machine-readable — keep simple bash assignments only.

# ════════════════════════════════════════════════════════════════════════
# SCENARIO HEADER (machine-readable; harness reads via grep+eval)
# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="template-do-not-run"
SCENARIO_DESCRIPTION="Template scenario — copy and rename before use"
SCENARIO_BUG_CATEGORY="d-recovery-hygiene"
SCENARIO_HISTORICAL_BUG=""
SCENARIO_COST_BUDGET_USD="2"
SCENARIO_TIMEOUT_SECONDS="600"
SCENARIO_REQUIRES="claude_cli OR codex_cli; tmux; jq"

# ════════════════════════════════════════════════════════════════════════
# scenario body — define run_scenario() returning 0 (PASS) or non-zero (FAIL)
# ════════════════════════════════════════════════════════════════════════
run_scenario() {
  # 1. SETUP
  local sandbox_dir
  sandbox_dir=$(mktemp -d -t "sv-real-llm-${SCENARIO_ID}.XXXXXX")
  trap "rm -rf '$sandbox_dir'" EXIT
  cd "$sandbox_dir"

  # 2. EXERCISE
  # ... run actual rlp-desk against the fixture ...

  # 3. ASSERT
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  # ... check final state ...

  # 4. REPORT
  if (( ASSERTIONS_FAILED == 0 )); then
    return 0
  else
    SCENARIO_FAILURE_REASON="$ASSERTIONS_FAILED assertion(s) failed; see log"
    return 1
  fi
}

# Allow direct invocation (skipped if RLP_REAL_LLM_GATE != 1).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
    echo "SKIPPED: RLP_REAL_LLM_GATE=1 to enable. Scenario: $SCENARIO_ID"
    exit 77
  fi
  echo "ERROR: this is a template — copy to a real scenario file before running"
  exit 2
fi
