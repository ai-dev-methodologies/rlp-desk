#!/usr/bin/env bash
# Test Suite: US-012 — tmux SV deprecation (v5.7 §4.7 INVERSION)
#
# v0.12.0 changed the behavior: previously, tmux-mode + --with-self-verification
# silently disabled SV (RC-1 "tmux_runner" skip) and recorded the skip in
# metadata for traceability. This was misleading; users expected SV to run.
#
# v0.12.0 (v5.7 §4.2 + §4.7) replaces silent disable with hard-reject:
# WITH_SELF_VERIFICATION=1 + zsh runner → exit 2 + migration banner pointing
# to the Node leader (which DOES support SV in tmux mode via generateSVReport).
#
# This test asserts the NEW contract:
# - Source no longer carries the silent-disable code path
# - Banner emission and exit code 2 work as designed
# - lib_ralph_desk.zsh's SV summary still tracks WITH_SELF_VERIFICATION_REQUESTED
#   for in-Agent-mode traceability (the variable still exists, the force-disable
#   does not)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  local file="$1" pat="$2" n
  n=$(grep -cE -- "$pat" "$file" 2>/dev/null) || n=0
  printf '%s' "$n"
}
assert_one() {
  local n
  n=$(_match_count "$1" "$2")
  if [[ "$n" -ge 1 ]]; then pass "$3"; else fail "$3 (matches=0)"; fi
}
assert_zero() {
  local n
  n=$(_match_count "$1" "$2")
  if [[ "$n" -eq 0 ]]; then pass "$3"; else fail "$3 (matches=$n, expected 0)"; fi
}

echo "=== US-012 (v5.7 §4.7 INVERTED): tmux SV deprecation banner ==="
echo

# ----------------------------------------------------------------------------
# AC1: WITH_SELF_VERIFICATION_REQUESTED still tracked (Agent-mode traceability)
# ----------------------------------------------------------------------------
assert_one "$RUN" '^WITH_SELF_VERIFICATION_REQUESTED="\$WITH_SELF_VERIFICATION"' \
  "AC1-a: WITH_SELF_VERIFICATION_REQUESTED still captured"
assert_one "$RUN" '^SV_SKIPPED_REASON=""' \
  "AC1-b: SV_SKIPPED_REASON variable preserved (for non-tmux skip reasons in future)"

# ----------------------------------------------------------------------------
# AC2: v5.7 §4.2 deprecation banner replaces silent disable
# ----------------------------------------------------------------------------
assert_zero "$RUN" 'SV_SKIPPED_REASON="tmux_runner"' \
  "AC2-a: silent disable removed (no more tmux_runner force-skip)"
assert_zero "$RUN" 'NOTE: --with-self-verification is Agent-mode only; disabling for tmux runner' \
  "AC2-b: misleading NOTE message removed"
assert_one "$RUN" 'require the Node leader' \
  "AC2-c: deprecation banner points to Node leader"
assert_one "$RUN" 'run_ralph_desk.zsh no longer supports them as of 0.12.0' \
  "AC2-d: banner declares 0.12.0 deprecation"
assert_one "$RUN" 'exit 2' \
  "AC2-e: hard-reject with exit 2"

# ----------------------------------------------------------------------------
# AC3: Behavioral — WITH_SELF_VERIFICATION=1 triggers exit 2 with banner
# ----------------------------------------------------------------------------
out=$(LOOP_NAME=test-slug WITH_SELF_VERIFICATION=1 zsh "$RUN" 2>&1 >/dev/null)
exit_code=$?
if [[ $exit_code -eq 2 ]]; then
  pass "AC3-a: exit code 2 when WITH_SELF_VERIFICATION=1"
else
  fail "AC3-a: expected exit 2, got $exit_code"
fi
if echo "$out" | grep -q -- "--with-self-verification"; then
  pass "AC3-b: banner echoes --with-self-verification flag for migration"
else
  fail "AC3-b: banner missing flag echo"
fi

# ----------------------------------------------------------------------------
# AC4: Behavioral — FLYWHEEL=on-fail also triggers exit 2 (Bug 3 cover)
# ----------------------------------------------------------------------------
LOOP_NAME=test-slug FLYWHEEL=on-fail zsh "$RUN" >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -eq 2 ]]; then
  pass "AC4: FLYWHEEL=on-fail also rejected with exit 2 (Bug 3)"
else
  fail "AC4: expected exit 2, got $exit_code"
fi

# ----------------------------------------------------------------------------
# AC5: Negative — non-flywheel/non-SV invocation still proceeds (notice only)
# ----------------------------------------------------------------------------
out=$(LOOP_NAME=test-slug zsh "$RUN" 2>&1 | head -3)
if echo "$out" | grep -q "deprecated as of 0.12.0"; then
  pass "AC5: backward-compat path emits non-fatal [notice] for plain invocation"
else
  fail "AC5: missing deprecation notice for plain invocation"
fi

# ----------------------------------------------------------------------------
# AC6: lib_ralph_desk.zsh SV summary still references the requested flag
#       (used in Agent mode where SV genuinely runs)
# ----------------------------------------------------------------------------
assert_one "$LIB" 'WITH_SELF_VERIFICATION_REQUESTED:-0' \
  "AC6: SV Summary checks WITH_SELF_VERIFICATION_REQUESTED"

echo
echo "Total: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
