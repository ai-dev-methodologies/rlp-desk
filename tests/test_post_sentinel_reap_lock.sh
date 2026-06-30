#!/usr/bin/env zsh
# Bug #7 post-sentinel race — deterministic invariant proof (no real-LLM).
#
# The real-LLM scenario bug-07-post-sentinel-race.test.sh depends on a live worker
# producing an iter-signal so the leader reaps the worker pane and locks the sentinel.
# That dependency makes its A1/A2 flaky/unreachable when the worker prompt is stale.
# This test pins the SAME invariant deterministically, on the REAL leader functions:
#
#   _kill_pane_process (the reaper the leader calls at run_ralph_desk.zsh:3838 on worker
#   signal) + _lock_sentinel (chmod 0444) → the sentinel file is FROZEN: mode 0444 and a
#   subsequent write fails, so a lingering worker TUI cannot rewrite it (the 1m43s mtime
#   drift Bug #7 closed). Real tmux pane on a private -L socket (no operator-server touch).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
SOCK="b7lock-$$"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

command -v tmux >/dev/null 2>&1 || { print "SKIP: tmux not available"; exit 0; }
cleanup(){ command tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# Route bare `tmux` (incl. those inside _kill_pane_process) to a private socket.
tmux(){ command tmux -L "$SOCK" "$@"; }

# shellcheck source=src/scripts/lib_ralph_desk.zsh
source "$LIB" 2>/dev/null
# Stub the leader log helpers (the lib's own deref $DEBUG under set -u) + readiness poll.
log(){ :; }; log_debug(){ :; }
wait_for_pane_ready(){ command tmux -L "$SOCK" list-panes 2>/dev/null >/dev/null; return 0; }

tmux new-session -d -s reap "sleep 100" 2>/dev/null
PANE_ID=$(tmux display-message -t reap -p '#{pane_id}' 2>/dev/null)
if [[ -z "$PANE_ID" ]]; then
  print "SKIP: tmux present but cannot create a session (sandboxed runner?) — substrate unavailable"
  exit 0
fi
ok "real tmux pane created ($PANE_ID on -L $SOCK)"

D=$(mktemp -d)
SENT="$D/iter-signal.json"
print '{"status":"verify","us_id":"US-001"}' > "$SENT"

# 1) Reaper kills the (real) producer pane. _kill_pane_process is fail-open + returns 0;
#    what matters here is the LOCK that follows, mirroring run:3838-3839 (reap then lock).
_kill_pane_process "$PANE_ID" worker
ok "_kill_pane_process invoked on the real worker pane (reaper ran)"

# 2) Lock the sentinel (Bug #7 Fix-Q/R: chmod 0444 so the TUI cannot rewrite it).
_lock_sentinel "$SENT"
mode=$(stat -f %Lp "$SENT" 2>/dev/null || stat -c %a "$SENT")
[[ "$mode" == "444" ]] && ok "sentinel locked to 0444 after reap" \
  || no "sentinel NOT locked (mode=$mode, expected 444)"

# 3) FROZEN: a write to the locked sentinel must FAIL (the invariant Bug #7 closed). If the
#    filesystem honors 0444, the redirect errors and the content/mtime stay frozen.
mtime_before=$(stat -f %m "$SENT" 2>/dev/null || stat -c %Y "$SENT")
if print 'TAMPER' >> "$SENT" 2>/dev/null; then
  # FS did not honor chmod (rare — e.g. running as root / some mounts). Don't false-FAIL the
  # invariant; record as INFO so the test stays meaningful where chmod IS honored.
  [[ "$(stat -f %Lp "$SENT" 2>/dev/null || stat -c %a "$SENT")" == "444" ]] \
    && print "  INFO sentinel is 0444 but FS allowed the write (root/permissive mount) — freeze not enforceable here" \
    || no "sentinel write SUCCEEDED against a non-0444 file (lock absent)"
else
  ok "write to the locked sentinel FAILED (frozen — TUI cannot rewrite it)"
  mtime_after=$(stat -f %m "$SENT" 2>/dev/null || stat -c %Y "$SENT")
  [[ "$mtime_before" == "$mtime_after" ]] && ok "sentinel mtime unchanged after blocked write (frozen)" \
    || no "sentinel mtime advanced despite lock ($mtime_before -> $mtime_after)"
  grep -q TAMPER "$SENT" && no "TAMPER leaked into the locked sentinel" || ok "sentinel content intact (no TAMPER)"
fi

rm -rf "$D"
print ""
if (( FAIL == 0 )); then print "post-sentinel-reap-lock: $PASS/$((PASS+FAIL)) PASS"; else print "post-sentinel-reap-lock: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
