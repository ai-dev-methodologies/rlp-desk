#!/bin/zsh
# ============================================================================
# F-13 regression: the circuit-breaker counter (consecutive_failures) must be
# restored from status.json on relaunch. Previously only verified_us was read
# back, so a crash-looping campaign reset its CB to 0 every relaunch and could
# evade the breaker. Mirrors the restore snippet added to run_ralph_desk.zsh.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

# Mirror of the run_ralph_desk.zsh F-13 restore logic.
restore_cf(){
  local sf="$1" cf
  cf=$(jq -r '.consecutive_failures // 0' "$sf" 2>/dev/null)
  if [[ "$cf" == <-> && "$cf" -gt 0 ]]; then print "$cf"; else print 0; fi
}

print -P "%F{cyan}F-13 CB-counter restore regression%f"
D=$(mktemp -d)

print '{"verified_us":["US-001","US-002"],"consecutive_failures":3}' > "$D/status.json"
[[ "$(restore_cf "$D/status.json")" == 3 ]] \
  && ok "restores consecutive_failures=3 from a crash-looped status.json (CB no longer evadable)" \
  || no "did not restore consecutive_failures (got '$(restore_cf "$D/status.json")')"

print '{"verified_us":["US-001"],"consecutive_failures":0}' > "$D/status.json"
[[ "$(restore_cf "$D/status.json")" == 0 ]] \
  && ok "consecutive_failures=0 stays 0 (no spurious CB on a healthy relaunch)" \
  || no "0 not preserved"

print '{"verified_us":["US-001"]}' > "$D/status.json"
[[ "$(restore_cf "$D/status.json")" == 0 ]] \
  && ok "missing field → 0 (graceful)" \
  || no "missing field not handled"

print 'not json' > "$D/status.json"
[[ "$(restore_cf "$D/status.json")" == 0 ]] \
  && ok "corrupt status.json → 0 (no crash)" \
  || no "corrupt json not handled"

# --- structural guard (the ACTUAL F-13 fix): the CB restore must NOT be nested
# under `if [[ "$VERIFY_MODE" = "per-us" ]]`, or a batch-mode relaunch skips it
# entirely and the circuit breaker resets to 0 (evadable). The logic cases above
# can't see placement; this asserts the enclosing STATUS_FILE guard sits at
# function-body indent (2 spaces), not nested (4+). ---
RUN="${0:A:h:h:h}/src/scripts/run_ralph_desk.zsh"
if [[ -f "$RUN" ]]; then
  cf_line=$(grep -n 'restored_consecutive_failures_from_status' "$RUN" | head -1 | cut -d: -f1)
  guard_line=$(grep -n 'if \[\[ -f "\$STATUS_FILE" \]\]; then' "$RUN" \
                 | awk -F: -v c="$cf_line" '$1 < c {l=$1} END{print l+0}')
  indent=$(awk -v n="$guard_line" 'NR==n{match($0,/^ */);print RLENGTH}' "$RUN")
  [[ "$indent" == 2 ]] \
    && ok "CB restore runs at function-body scope (batch-safe, not nested under per-us)" \
    || no "CB restore nested under per-us (STATUS_FILE guard indent=$indent, want 2)"
else
  no "structural guard: run_ralph_desk.zsh not found at $RUN"
fi

rm -rf "$D"
print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-13 CB-counter restore: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-13 CB-counter restore: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
