#!/bin/zsh
# ============================================================================
# F-11 regression (fault injection): a Worker pane-start failure (the transient
# F6.1 "send-keys before shell ready" spawn race) must replace the pane and
# retry ONCE before BLOCKing — not terminate the campaign on a transient. Two
# consecutive start failures still BLOCK. Mirrors the inline replace+retry at
# the Worker-dispatch site in run_ralph_desk.zsh.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

typeset -g STUB_LAUNCH_FAILS=0 STUB_REPLACE=0 STUB_BLOCKED=0
launch_worker(){ if (( STUB_LAUNCH_FAILS > 0 )); then (( STUB_LAUNCH_FAILS-- )); return 1; fi; return 0; }
replace_worker_pane(){ (( STUB_REPLACE++ )); }
write_blocked_sentinel(){ STUB_BLOCKED=1; }
update_status(){ : ; }; log(){ : ; }; log_debug(){ : ; }; jq(){ print "%wfresh"; }
WORKER_PANE=%w0; worker_prompt=/tmp/p; ITERATION=1; worker_launch=x; SESSION_CONFIG=/tmp/sc

# faithful copy of the inline F-11 replace+retry (one branch; both engines identical)
worker_start_with_retry(){  # 0=started, 1=blocked
  if ! launch_worker "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
    replace_worker_pane "$WORKER_PANE" "worker"
    WORKER_PANE=$(jq -r '.panes.worker' "$SESSION_CONFIG")
    if ! launch_worker "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
      write_blocked_sentinel "Worker failed to start after replace+retry" "" "infra_failure"
      update_status "blocked" "worker_start_failed"
      return 1
    fi
  fi
  return 0
}
reset(){ STUB_LAUNCH_FAILS=$1; STUB_REPLACE=0; STUB_BLOCKED=0; WORKER_PANE=%w0; }

print -P "%F{cyan}F-11 worker pane-start replace+retry (fault injection)%f"

reset 0; worker_start_with_retry; rc=$?
[[ $rc -eq 0 && $STUB_REPLACE -eq 0 && $STUB_BLOCKED -eq 0 ]] \
  && ok "clean start → no replace, no BLOCK" || no "clean: rc=$rc replace=$STUB_REPLACE blocked=$STUB_BLOCKED"

reset 1; worker_start_with_retry; rc=$?
[[ $rc -eq 0 && $STUB_REPLACE -eq 1 && $STUB_BLOCKED -eq 0 ]] \
  && ok "1 transient start-fail → replace+retry RECOVERS (was immediate BLOCK)" \
  || no "transient: rc=$rc replace=$STUB_REPLACE blocked=$STUB_BLOCKED"

reset 2; worker_start_with_retry; rc=$?
[[ $rc -eq 1 && $STUB_REPLACE -eq 1 && $STUB_BLOCKED -eq 1 ]] \
  && ok "2 consecutive start-fails → BLOCK after one replace+retry (bounded)" \
  || no "persistent: rc=$rc replace=$STUB_REPLACE blocked=$STUB_BLOCKED"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-11 worker start retry: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-11 worker start retry: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
