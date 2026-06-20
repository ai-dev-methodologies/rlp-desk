#!/bin/zsh
# ============================================================================
# F-10 / F-11 regression (fault injection): the Verifier poll-failure path must
# get the same 3-strike replace+re-dispatch breaker the Worker has ("Bug Report
# #5"), NOT an immediate terminal BLOCK. A single transient verifier death (API
# blip / pane-spawn race) must replace+retry; only 3 consecutive failures BLOCK.
#
# This is a faithful copy of the retry loop applied inline at the Verifier-poll
# site in run_ralph_desk.zsh. Faults are injected by stubbing poll_for_signal to
# fail a configurable number of times (rc) before succeeding.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

# ---- fault-injection stubs ----
typeset -g STUB_POLL_FAILS=0 STUB_POLL_RC=1 STUB_REPLACE=0 STUB_REDISPATCH=0 STUB_BLOCKED=0
poll_for_signal(){ if (( STUB_POLL_FAILS > 0 )); then (( STUB_POLL_FAILS-- )); return $STUB_POLL_RC; fi; return 0; }
replace_worker_pane(){ (( STUB_REPLACE++ )); }
launch_verifier_claude(){ (( STUB_REDISPATCH++ )); return 0; }
launch_verifier_codex(){ (( STUB_REDISPATCH++ )); return 0; }
write_blocked_sentinel(){ STUB_BLOCKED=1; }
update_status(){ : ; }; log(){ : ; }; log_error(){ : ; }; log_debug(){ : ; }
jq(){ print "%vfresh"; }

VERIFIER_ENGINE=claude; ITERATION=1
VERDICT_FILE=/tmp/x; VERIFIER_HEARTBEAT=/tmp/x; VERIFIER_PANE=%v0
verifier_launch="claude"; verifier_prompt=/tmp/p; SESSION_CONFIG=/tmp/sc

# ---- function under test: faithful copy of the inline F-10 retry loop ----
# (returns 0=verdict obtained, 1=blocked after 3 strikes, 2=poll rc==2 early-return)
verifier_poll_with_retry(){
  local _vpoll_strike=0 _vpoll_ok=0
  while (( _vpoll_strike < 3 )); do
    # direct rc capture (faithful to the inline fix: $? after if-fi is the
    # if-statement status, not poll's rc). rc 0=verdict 1=timeout 2=hard-fail.
    poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier"
    local verifier_poll_rc=$?
    if (( verifier_poll_rc == 0 )); then _vpoll_ok=1; break; fi
    if (( verifier_poll_rc == 2 )); then return 2; fi
    (( _vpoll_strike++ ))
    update_status "verifier" "poll_failed"
    (( _vpoll_strike >= 3 )) && break
    replace_worker_pane "$VERIFIER_PANE" "verifier"
    VERIFIER_PANE=$(jq -r '.panes.verifier' "$SESSION_CONFIG")
    if [[ "$VERIFIER_ENGINE" = "codex" ]]; then
      launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"
    else
      launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch" || true
    fi
  done
  if (( ! _vpoll_ok )); then
    write_blocked_sentinel "Verifier process dead/stuck after 3 retries." "" "infra_failure"
    update_status "blocked" "verifier_dead"
    return 1
  fi
  return 0
}

reset(){ STUB_POLL_FAILS=$1; STUB_POLL_RC=${2:-1}; STUB_REPLACE=0; STUB_REDISPATCH=0; STUB_BLOCKED=0; VERIFIER_PANE=%v0; }

print -P "%F{cyan}F-10 verifier poll 3-strike retry (fault injection)%f"

reset 0; verifier_poll_with_retry; rc=$?
[[ $rc -eq 0 && $STUB_BLOCKED -eq 0 && $STUB_REPLACE -eq 0 ]] \
  && ok "clean poll → success, no retry, no BLOCK" || no "clean: rc=$rc blocked=$STUB_BLOCKED replace=$STUB_REPLACE"

reset 2 1; verifier_poll_with_retry; rc=$?
[[ $rc -eq 0 && $STUB_BLOCKED -eq 0 && $STUB_REPLACE -eq 2 && $STUB_REDISPATCH -eq 2 ]] \
  && ok "2 transient poll-fails → RECOVERS (was immediate BLOCK): 2 replace+re-dispatch, no BLOCK" \
  || no "transient: rc=$rc blocked=$STUB_BLOCKED replace=$STUB_REPLACE redispatch=$STUB_REDISPATCH"

reset 3 1; verifier_poll_with_retry; rc=$?
[[ $rc -eq 1 && $STUB_BLOCKED -eq 1 ]] \
  && ok "3 consecutive poll-fails → BLOCK after 3 strikes (breaker honored, not evaded)" \
  || no "3fail: rc=$rc blocked=$STUB_BLOCKED"

reset 1 2; verifier_poll_with_retry; rc=$?
[[ $rc -eq 2 && $STUB_BLOCKED -eq 0 && $STUB_REPLACE -eq 0 ]] \
  && ok "poll rc==2 → early return, no retry/BLOCK (original semantics preserved)" \
  || no "rc2: rc=$rc blocked=$STUB_BLOCKED replace=$STUB_REPLACE"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-10 verifier poll retry: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-10 verifier poll retry: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
