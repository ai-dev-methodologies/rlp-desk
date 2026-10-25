#!/bin/zsh
# Q-01 / A-C1-02 probe: the NO-PERL signal path of tests/test_signal_deadlock.zsh must not signal a recorded pid that is not the registered process.
# usage: q01_degraded_probe.zsh [<zsh file of the test>]   (default: tests/test_signal_deadlock.zsh)
# The test is started with a PATH that has every tool except perl (so no reaper: the degraded path), with its own TMPDIR/TMUX_TMPDIR under /tmp/q01deg.*. Once a
# leader is registered, a STALE record is planted in the test's $TMP/subs for a live decoy process of ours (registration time 1 h ago: the pid "was recycled"),
# then the test gets SIGTERM. Expected: the test ends 143, the registered leaders are gone, the decoy is still alive.
# Two more decoys have a FRESH registration but an argv that is neither the harness nor the test (they must survive the argv discriminator).
# Pre-fix (raw `kill -9 <recorded pid>`) the decoy is killed. Every process created here is identified by start time + argv and signalled only while that matches.
set -uo pipefail
TEST="${1:-${0:A:h:h}/test_signal_deadlock.zsh}"
zmodload zsh/datetime
BASE=$(mktemp -d /tmp/q01deg.XXXXXX) || exit 1
mkdir -p "$BASE/tmpdir" "$BASE/tmux" "$BASE/bin"
typeset -A ID
_idstr() { ps -o lstart=,command= -p "$1" 2>/dev/null; }
_reg() { local i; for (( i = 0; i < 60; i++ )); do [[ "$(_idstr "$1")" == *"$2"* ]] && { ID[$1]=$(_idstr "$1"); return 0; }; sleep 0.05; done; return 1; }
_sig() { [[ -n "${ID[$2]:-}" && "$(_idstr "$2")" == "${ID[$2]}" ]] && kill -"$1" "$2" 2>/dev/null; }
cleanup() {
  local p f l
  for p in ${(k)ID}; do _sig 9 "$p"; done
  for f in "$BASE"/tmux/tmux-*/rlpc01_*(N); do l=${f:t}; TMUX_TMPDIR="$BASE/tmux" tmux -L "$l" kill-server >/dev/null 2>&1; done
  rm -rf "$BASE"
}
trap cleanup EXIT
for d in /opt/homebrew/bin /usr/local/bin /usr/sbin /sbin /bin /usr/bin; do
  for f in $d/*(N); do b=${f:t}; [[ "$b" == perl* || "$b" == cpan* || -e "$BASE/bin/$b" ]] || ln -s "$f" "$BASE/bin/$b"; done
done
PATH="$BASE/bin" command -v perl >/dev/null 2>&1 && { print "FAIL: perl is still reachable"; exit 1; }
sleep 600 >/dev/null 2>&1 & DECOY=$!; _reg $DECOY "sleep 600"
sleep 602 >/dev/null 2>&1 & DECOY2=$!; _reg $DECOY2 "sleep 602"   # FRESH registration, argv matches neither the harness nor the test
sleep 603 >/dev/null 2>&1 & DECOY3=$!; _reg $DECOY3 "sleep 603"   # same, recorded as a trial subshell
( export PATH="$BASE/bin" TMPDIR="$BASE/tmpdir" TMUX_TMPDIR="$BASE/tmux" C01_TRIALS_STRESS=12 C01_TRIALS_STRESSLOG=0 C01_TRIALS_STRESSDEBUG=0 C01_TRIALS_STRESSREFRESH=0 C01_PAR=3
  exec zsh "$TEST" >"$BASE/out" 2>"$BASE/err" </dev/null ) &
TP=$!; _reg $TP "${TEST:t}" || { print "FAIL: the test never showed its final argv"; exit 1; }
T=""
for (( i = 0; i < 900; i++ )); do
  for d in "$BASE"/tmpdir/rlpc01.*(N/); do [[ -n "$(echo $d/pids/*(N))" ]] && T=$d; done
  [[ -n "$T" ]] && break; sleep 0.1
done
[[ -n "$T" ]] || { print "FAIL: the test never registered a leader"; exit 1; }
LEADERS=(); for f in $T/pids/*(N); do read -r p _ < $f; [[ "$p" == <2-> ]] && LEADERS+=($p); done
print -r -- "$DECOY $(( EPOCHSECONDS - 3600 ))" > "$T/subs/zz.decoy"
print -r -- "$DECOY2 $EPOCHSECONDS" > "$T/pids/zz.decoy2"
print -r -- "$DECOY3 $EPOCHSECONDS" > "$T/subs/zz.decoy3"
grep -q "perl not found" "$BASE/err" && print "  note: the test printed its no-perl warning (degraded path active)"
[[ -n "${ID[$TP]:-}" && "$(_idstr "$TP")" == "${ID[$TP]}" ]] || { print "FAIL: the test (pid $TP) already exited or is no longer the process we started; refusing to signal"; exit 1; }
_sig TERM $TP
for (( i = 0; i < 150; i++ )); do [[ "$(ps -o stat= -p $TP 2>/dev/null | tr -d ' ')" == (|Z*) ]] && break; sleep 0.1; done
wait $TP 2>/dev/null; rc=$?
fail=0
st=dead; kill -0 $DECOY 2>/dev/null && st=alive
[[ "$st" == alive ]] && print "  ok   decoy with a stale record (pid $DECOY) is alive" || { print "  FAIL decoy with a stale record (pid $DECOY) was signalled"; fail=1; }
for d in $DECOY2 $DECOY3; do
  kill -0 $d 2>/dev/null && print "  ok   decoy with a FRESH registration but an unrelated argv (pid $d) is alive" || { print "  FAIL decoy with a fresh registration but an unrelated argv (pid $d) was signalled"; fail=1; }
done
(( rc == 143 )) && print "  ok   the test ended with 143" || { print "  FAIL the test ended with $rc, expected 143"; fail=1; }
sleep 3
gone=1; for p in $LEADERS; do kill -0 $p 2>/dev/null && [[ "$(ps -o command= -p $p 2>/dev/null)" == *rlpc01* ]] && gone=0; done
(( gone )) && print "  ok   the registered leaders (${#LEADERS}) are gone" || { print "  FAIL a registered leader is still alive"; fail=1; }
(( fail )) && print "degraded: FAIL" || print "degraded: PASS"
exit $fail
