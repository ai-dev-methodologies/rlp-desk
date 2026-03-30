#!/bin/bash
# TDD tests for sequential final verify (Phase 1: final verify timeout fix)
# AC1: final verify with US_LIST loops through each US individually
# AC2: full test suite runs after all per-US pass
# AC3: single US failure stops final verify with specific fail verdict
set -uo pipefail

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== Sequential Final Verify Tests ==="

# --- AC1: run_sequential_final_verify function exists ---
test_ac1_function_exists() {
  if grep -q 'run_sequential_final_verify()' "$RUN"; then
    pass "AC1-1: run_sequential_final_verify function exists"
  else
    fail "AC1-1: run_sequential_final_verify function not found"
  fi
}

test_ac1_loops_us_list() {
  # Function should iterate through US_LIST
  local fn_body
  fn_body=$(awk '/^run_sequential_final_verify\(\)/,/^}/' "$RUN")
  if echo "$fn_body" | grep -q 'US_LIST\|us_list'; then
    pass "AC1-2: function references US_LIST for iteration"
  else
    fail "AC1-2: function does not reference US_LIST"
  fi
}

test_ac1_calls_scoped_verifier() {
  local fn_body
  fn_body=$(awk '/^run_sequential_final_verify\(\)/,/^}/' "$RUN")
  if echo "$fn_body" | grep -q 'write_verifier_trigger\|launch_verifier\|run_single_verifier'; then
    pass "AC1-3: function dispatches scoped verifier per US"
  else
    fail "AC1-3: function does not dispatch scoped verifier"
  fi
}

# --- AC2: integration check after per-US pass ---
test_ac2_test_suite_after_perus() {
  local fn_body
  fn_body=$(awk '/^run_sequential_final_verify\(\)/,/^}/' "$RUN")
  if echo "$fn_body" | grep -q 'VERIFICATION_CMD\|test.*suite\|integration.*check\|run.*tests'; then
    pass "AC2-1: function runs integration check after per-US"
  else
    fail "AC2-1: no integration check after per-US verification"
  fi
}

# --- AC3: single US failure stops with specific verdict ---
test_ac3_fail_stops_loop() {
  local fn_body
  fn_body=$(awk '/^run_sequential_final_verify\(\)/,/^}/' "$RUN")
  if echo "$fn_body" | grep -q 'fail\|FAIL\|return 1'; then
    pass "AC3-1: function handles individual US failure"
  else
    fail "AC3-1: no failure handling in sequential verify"
  fi
}

test_ac3_fail_reports_specific_us() {
  local fn_body
  fn_body=$(awk '/^run_sequential_final_verify\(\)/,/^}/' "$RUN")
  if echo "$fn_body" | grep -qE 'failed.*us|fail.*US-|us_id.*fail|FAILED_US'; then
    pass "AC3-2: failure reports specific US that failed"
  else
    fail "AC3-2: failure does not report specific US"
  fi
}

# --- AC1 integration: main loop calls sequential function for ALL ---
test_ac1_main_calls_sequential() {
  # The main loop should call run_sequential_final_verify when signal_us_id == ALL
  if grep -A5 'signal_us_id.*==.*ALL\|signal_us_id.*=.*"ALL"' "$RUN" | grep -q 'run_sequential_final_verify'; then
    pass "AC1-4: main loop calls run_sequential_final_verify for ALL"
  else
    fail "AC1-4: main loop does not call run_sequential_final_verify for ALL"
  fi
}

# Run all tests
test_ac1_function_exists
test_ac1_loops_us_list
test_ac1_calls_scoped_verifier
test_ac2_test_suite_after_perus
test_ac3_fail_stops_loop
test_ac3_fail_reports_specific_us
test_ac1_main_calls_sequential

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $(( FAIL > 0 ? 1 : 0 ))
