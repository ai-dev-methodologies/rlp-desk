#!/bin/bash
# TDD tests for C4: /rlp-desk status detailed report
set -uo pipefail

RUN="${RUN:-src/commands/rlp-desk.md}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== C4: Status Detail Tests ==="

# AC1: status section shows current iteration and phase
test_ac1_iteration_display() {
  if grep -q 'iteration\|Iteration' "$RUN" | head -1 && \
     grep -A20 '## `status' "$RUN" | grep -qi 'iteration'; then
    pass "AC1-1: status displays iteration number"
  else
    fail "AC1-1: status does not display iteration"
  fi
}

# AC2: status shows verified US list
test_ac2_verified_us() {
  if grep -A20 '## `status' "$RUN" | grep -qi 'verified_us\|verified.*stories\|verified.*US'; then
    pass "AC2-1: status displays verified US"
  else
    fail "AC2-1: status does not display verified US"
  fi
}

# AC3: status shows consecutive failures
test_ac3_failures() {
  if grep -A20 '## `status' "$RUN" | grep -qi 'consecutive\|failure'; then
    pass "AC3-1: status displays consecutive failures"
  else
    fail "AC3-1: status does not display failures"
  fi
}

# AC4: status shows worker/verifier models
test_ac4_models() {
  if grep -A20 '## `status' "$RUN" | grep -qi 'worker_model\|verifier_model\|model'; then
    pass "AC4-1: status displays models"
  else
    fail "AC4-1: status does not display models"
  fi
}

# AC5: status shows last result
test_ac5_last_result() {
  if grep -A20 '## `status' "$RUN" | grep -qi 'last_result\|last.*result\|verdict'; then
    pass "AC5-1: status displays last result"
  else
    fail "AC5-1: status does not display last result"
  fi
}

# AC6: status shows elapsed time
test_ac6_elapsed() {
  if grep -A30 '## `status' "$RUN" | grep -qi 'elapsed\|time\|updated_at'; then
    pass "AC6-1: status displays elapsed/time info"
  else
    fail "AC6-1: status does not display time info"
  fi
}

test_ac1_iteration_display
test_ac2_verified_us
test_ac3_failures
test_ac4_models
test_ac5_last_result
test_ac6_elapsed

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $(( FAIL > 0 ? 1 : 0 ))
