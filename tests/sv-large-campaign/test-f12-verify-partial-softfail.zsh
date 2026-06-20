#!/bin/zsh
# ============================================================================
# F-12 regression: a malformed verify_partial signal (empty verified_acs — a
# fresh-context Worker formatting slip) must be a SOFT-FAIL bounded by the
# consecutive-failure circuit breaker, NOT a terminal mission_abort. One slip
# costs an iteration; only repeated malforming (>= CB threshold) blocks.
# Mirrors the decision applied at the verify_partial branch in run_ralph_desk.zsh.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

# Mirror of the F-12 decision: returns retry | block | verify
f12_decide(){
  local vp_count=$1 cf=$2 thresh=$3
  if [[ "$vp_count" -eq 0 ]]; then
    (( cf++ ))
    if (( cf >= thresh )); then print "block"; else print "retry"; fi
  else
    print "verify"
  fi
}

print -P "%F{cyan}F-12 verify_partial malformed soft-fail regression%f"

[[ "$(f12_decide 3 0 6)" == verify ]] \
  && ok "valid verify_partial (count>0) → proceeds to verify (unchanged)" \
  || no "valid partial misrouted: $(f12_decide 3 0 6)"

[[ "$(f12_decide 0 0 6)" == retry ]] \
  && ok "first malformed slip → soft-fail RETRY (was terminal mission_abort)" \
  || no "first slip not retried: $(f12_decide 0 0 6)"

[[ "$(f12_decide 0 4 6)" == retry ]] \
  && ok "malformed below CB threshold → still retry (bounded, not infinite)" \
  || no "below-threshold not retried: $(f12_decide 0 4 6)"

[[ "$(f12_decide 0 5 6)" == block ]] \
  && ok "malformed reaching CB threshold (6th) → BLOCK (breaker still protects)" \
  || no "CB not enforced: $(f12_decide 0 5 6)"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-12 verify_partial soft-fail: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-12 verify_partial soft-fail: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
