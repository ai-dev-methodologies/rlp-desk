#!/usr/bin/env bash
# Test Suite: US-012 — tmux SV deprecation traceability (v0.14.0+ scope)
#
# History:
# - v0.12.0 introduced a hard-reject deprecation gate: WITH_SELF_VERIFICATION=1
#   in zsh runner → exit 2 + migration banner pointing to the Node leader.
# - v0.14.0 REMOVED that gate (run_ralph_desk.zsh:63-71): the zsh runner now
#   honors FLYWHEEL/FLYWHEEL_GUARD/WITH_SELF_VERIFICATION directly, with the
#   Node leader reserved for `--mode agent` (LLM-driven) only.
#
# This test asserts the v0.14.0+ contract:
# - WITH_SELF_VERIFICATION_REQUESTED is captured for traceability (governance §1f)
# - SV_SKIPPED_REASON is preserved as a variable (still useful for non-tmux skips)
# - The v5.7 §4.2 silent-disable code path stays removed (regression guard)
# - lib_ralph_desk.zsh's SV summary still tracks WITH_SELF_VERIFICATION_REQUESTED
#   for in-Agent-mode traceability
#
# Removed assertions: AC2-c/AC2-d/AC3-a/AC3-b/AC4/AC5 tested the v0.12.0 hard-reject
# gate (banner pointing to Node leader, exit 2, etc.) which was intentionally
# deleted in v0.14.0. Those assertions checked for code that is gone by design.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
# AC2: silent-disable code path stays removed (v0.12.0 cleanup, still valid)
# ----------------------------------------------------------------------------
assert_zero "$RUN" 'SV_SKIPPED_REASON="tmux_runner"' \
  "AC2-a: silent disable removed (no more tmux_runner force-skip)"
assert_zero "$RUN" 'NOTE: --with-self-verification is Agent-mode only; disabling for tmux runner' \
  "AC2-b: misleading NOTE message removed"

# AC2-c/AC2-d/AC2-e/AC3/AC4/AC5 removed in v0.14.0:
# they tested the v0.12.0 hard-reject deprecation gate that was deleted in
# v0.14.0 when zsh runner regained primary tmux mode authority
# (run_ralph_desk.zsh:63-71). Re-introduce only if the gate comes back.

# ----------------------------------------------------------------------------
# AC6: lib_ralph_desk.zsh SV summary still references the requested flag
#       (used in Agent mode where SV genuinely runs)
# ----------------------------------------------------------------------------
assert_one "$LIB" 'WITH_SELF_VERIFICATION_REQUESTED:-0' \
  "AC6: SV Summary checks WITH_SELF_VERIFICATION_REQUESTED"

echo
echo "Total: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
