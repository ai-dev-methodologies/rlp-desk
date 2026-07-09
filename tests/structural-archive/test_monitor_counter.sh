#!/bin/zsh
# v0.14.3 P0-5 unit test (BOS Bug Report #5):
# main polling loop's MONITOR_FAILURE_COUNT branch must NOT write a BLOCKED
# sentinel until the 3-strike circuit breaker fires. The pre-fix code wrote
# BLOCKED unconditionally at counter 1/3, halting the campaign on the first
# transient worker-dead detection between iterations.
#
# This test grep-asserts the source shape of the branch in run_ralph_desk.zsh
# rather than dispatching the runner end-to-end, because the branch sits deep
# inside the main loop (~L3000) and lifting it out for source-extraction is
# error-prone. The shape check is sufficient: the dead-code unconditional
# write_blocked_sentinel/update_status/return-1 sequence must be absent.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

PASS=0
FAIL=0

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label  (cond: $cond)"
    (( FAIL++ ))
  fi
}

# ---------------------------------------------------------------------------
# Shape assertions on the worker-dead branch
# ---------------------------------------------------------------------------

# The 3-strike escalation MUST still be present (regression guard).
assert "MONITOR_FAILURE_COUNT >= 3 escalation present" \
  "grep -q 'MONITOR_FAILURE_COUNT >= 3' '$RUN_SCRIPT'"

assert "3-strike branch writes 'monitor_failures' BLOCKED sentinel" \
  "grep -q '3 consecutive monitor failures' '$RUN_SCRIPT'"

# The dead-code unconditional BLOCKED write at counter 1/3 MUST be gone.
assert "no unconditional 'Worker process dead/stuck' BLOCKED before 3-strike" \
  "! grep -q 'Worker process dead/stuck (poll failed)' '$RUN_SCRIPT'"

assert "no unconditional update_status blocked worker_dead in retry path" \
  "! grep -q 'update_status \"blocked\" \"worker_dead\"' '$RUN_SCRIPT'"

# The 1/3 path MUST log a retry intent (not BLOCKED).
assert "1/3 strike logs 'will retry' intent" \
  "grep -q 'will retry' '$RUN_SCRIPT'"

# Counter reset on success MUST still be present.
assert "MONITOR_FAILURE_COUNT=0 reset on signal success" \
  "grep -q 'MONITOR_FAILURE_COUNT=0' '$RUN_SCRIPT'"

# v0.14.3 P0-5 banner / commit anchor (regression guard).
assert "v0.14.3 P0-5 fix marker present in source" \
  "grep -q 'v0.14.3 P0-5' '$RUN_SCRIPT'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print ""
print "=== summary: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
