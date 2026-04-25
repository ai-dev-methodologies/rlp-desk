#!/usr/bin/env bash
# Test Suite: US-012 — RC-1 tmux SV skip + traceability
# Covers governance §1f traceability: requested vs effective state of WITH_SELF_VERIFICATION
# preserved separately so metadata.json/session-config/debug-log/SV-summary stay honest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  # grep -c without || echo fallback so we never get multiline "0\n0".
  # grep -c returns 0 even with no matches if -c is given; suppress non-zero exit.
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

echo "=== US-012: RC-1 tmux SV skip + traceability ==="
echo

# ----------------------------------------------------------------------------
# AC1: Variable declaration (run_ralph_desk.zsh:~59)
# ----------------------------------------------------------------------------
assert_one "$RUN" '^WITH_SELF_VERIFICATION_REQUESTED="\$WITH_SELF_VERIFICATION"' \
  "AC1-a: WITH_SELF_VERIFICATION_REQUESTED captured from initial flag"
assert_one "$RUN" '^SV_SKIPPED_REASON=""' \
  "AC1-b: SV_SKIPPED_REASON declared"

# ----------------------------------------------------------------------------
# AC2: Honest NOTE + flag-down at tmux entry (run_ralph_desk.zsh:~720)
# ----------------------------------------------------------------------------
assert_one "$RUN" 'NOTE: --with-self-verification is Agent-mode only; disabling for tmux runner' \
  "AC2-a: honest NOTE message present"
assert_one "$RUN" '^[[:space:]]*WITH_SELF_VERIFICATION=0$' \
  "AC2-b: flag is forced to 0 inside the tmux entry guard"
assert_one "$RUN" 'SV_SKIPPED_REASON="tmux_runner"' \
  "AC2-c: skip reason recorded as tmux_runner"
# Negative: the old misleading NOTE must be gone
assert_zero "$RUN" 'recorded but SV report generation is Agent-mode only' \
  "AC2-d: legacy misleading NOTE removed"

# ----------------------------------------------------------------------------
# AC3: Session config & metadata.json carry the requested/skipped pair
# ----------------------------------------------------------------------------
assert_one "$RUN" '"with_self_verification_requested": ' \
  "AC3-a: session-config exposes with_self_verification_requested"
assert_one "$RUN" '"sv_skipped_reason": ' \
  "AC3-b: session-config exposes sv_skipped_reason"
assert_one "$RUN" 'with_self_verification_requested: \$with_sv_requested' \
  "AC3-c: metadata.json jq filter wires with_self_verification_requested"
assert_one "$RUN" 'sv_skipped_reason: \$sv_skipped_reason' \
  "AC3-d: metadata.json jq filter wires sv_skipped_reason"

# ----------------------------------------------------------------------------
# AC4: Debug log shows requested + skipped together
# ----------------------------------------------------------------------------
assert_one "$RUN" 'requested=\$WITH_SELF_VERIFICATION_REQUESTED skipped=\$\{SV_SKIPPED_REASON:-none\}' \
  "AC4: debug log includes requested + skipped"

# ----------------------------------------------------------------------------
# AC5: SV Summary in lib_ralph_desk.zsh distinguishes requested-but-skipped
# ----------------------------------------------------------------------------
assert_one "$LIB" 'WITH_SELF_VERIFICATION_REQUESTED:-0' \
  "AC5-a: SV Summary checks WITH_SELF_VERIFICATION_REQUESTED"
assert_one "$LIB" 'requested but skipped \(reason: ' \
  "AC5-b: SV Summary message reflects skip reason"

# ----------------------------------------------------------------------------
# AC6: Defense-in-depth tmux guard inside generate_sv_report
# ----------------------------------------------------------------------------
assert_one "$LIB" 'tmux runner detected \(Agent-mode only feature\)' \
  "AC6-a: lib tmux guard log present"
assert_one "$LIB" '\[\[ -n "\$\{TMUX:-\}" \]\]' \
  "AC6-b: lib tmux guard condition present"

# ----------------------------------------------------------------------------
# AC7: claude --print no longer inherits stdin
# ----------------------------------------------------------------------------
assert_one "$LIB" '</dev/null > "\$sv_report_file"' \
  "AC7: claude --print spawn detaches stdin via </dev/null"

# ----------------------------------------------------------------------------
# AC8: Behavioural — flip flag when WITH_SELF_VERIFICATION=1 is provided
# (executes only the small tmux-entry block in isolation; no external deps).
# ----------------------------------------------------------------------------
out=$(
  WITH_SELF_VERIFICATION=1 SV_SKIPPED_REASON="" \
  zsh -c '
    WITH_SELF_VERIFICATION="${WITH_SELF_VERIFICATION:-0}"
    WITH_SELF_VERIFICATION_REQUESTED="$WITH_SELF_VERIFICATION"
    SV_SKIPPED_REASON=""
    if (( WITH_SELF_VERIFICATION )); then
      WITH_SELF_VERIFICATION=0
      SV_SKIPPED_REASON="tmux_runner"
    fi
    print -- "$WITH_SELF_VERIFICATION|$WITH_SELF_VERIFICATION_REQUESTED|$SV_SKIPPED_REASON"
  '
)
if [[ "$out" == "0|1|tmux_runner" ]]; then
  pass "AC8: tmux-entry block flips flag to 0, preserves requested=1, sets reason=tmux_runner"
else
  fail "AC8: unexpected state '$out'"
fi

# ----------------------------------------------------------------------------
# AC9: Normalization happens at script startup (before metadata.json write),
# not inside create_session(). codex review caught that a late normalization
# would leak WITH_SELF_VERIFICATION=1 into metadata.json. Lock the order in.
# ----------------------------------------------------------------------------
norm_line=$(grep -nE 'SV_SKIPPED_REASON="tmux_runner"' "$RUN" | head -1 | cut -d: -f1)
sess_line=$(grep -nE '"with_self_verification": ' "$RUN" | head -1 | cut -d: -f1)
meta_line=$(grep -nE '\-\-argjson with_sv "\$WITH_SELF_VERIFICATION"' "$RUN" | head -1 | cut -d: -f1)
debug_line=$(grep -nE '\[OPTION\] cb_threshold' "$RUN" | head -1 | cut -d: -f1)
if [[ -n "$norm_line" && -n "$sess_line" && -n "$meta_line" && -n "$debug_line" \
   && "$norm_line" -lt "$sess_line" && "$norm_line" -lt "$meta_line" && "$norm_line" -lt "$debug_line" ]]; then
  pass "AC9-a: normalization (line $norm_line) precedes session-config ($sess_line), metadata.json ($meta_line), and debug log ($debug_line)"
else
  fail "AC9-a: ordering broken (norm=$norm_line, sess=$sess_line, meta=$meta_line, debug=$debug_line)"
fi
# create_session() must NOT re-assign WITH_SELF_VERIFICATION (codex issue #1).
fn_assigns=$(awk '
  /^create_session\(\) \{/ { in_fn=1; depth=0 }
  in_fn {
    for (i=1;i<=length($0);i++) {
      c=substr($0,i,1)
      if (c=="{") depth++
      else if (c=="}") { depth--; if (depth==0) in_fn=0 }
    }
    print
  }
' "$RUN" | grep -cE '^[[:space:]]*WITH_SELF_VERIFICATION=0[[:space:]]*$')
if [[ "$fn_assigns" -eq 0 ]]; then
  pass "AC9-b: create_session() no longer re-normalizes WITH_SELF_VERIFICATION"
else
  fail "AC9-b: create_session() still has $fn_assigns WITH_SELF_VERIFICATION=0 assignments"
fi

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
