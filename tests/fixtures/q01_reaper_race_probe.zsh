#!/bin/zsh
# Q-01 / B-H2-04 probe: does the reaper leave orphans when a recorded process is FORKING at the moment the test dies?
# usage: q01_reaper_race_probe.zsh [--legacy] [<zsh file holding _REAPER_PL> [<trials>]]   (defaults: tests/test_signal_deadlock.zsh, 20)
#   --legacy writes the old one-field pid record (to run the probe against the pre-fix reaper)
# Per trial: a fake "test" (sleep 600, ours) with a real reaper started on a scratch $TMP/rlpc01.T<n>; one registered "leader" (zsh whose argv carries
# $TMP/harness.zsh, started in its OWN process group by perl setpgrp, so the group id is unique to this trial of this probe instance) forks 400 `sleep` children
# in a loop; ~20-150 ms later the fake test is SIGKILLed; once the reaper has exited, the members of that process group still alive are the orphans (ppid 1).
# Signal discipline: every process this probe creates is identified when it is created (start time + argv, `ps -o lstart=,command=`) and is signalled later only
# while that identity still matches; processes that finished are retired per trial (identity dropped) and are never signalled again. No process-group kill: the
# leader's children carry an argv no other process has, `sleep 700.<probe pid><trial>` (the token is unique to this probe instance and trial), so a survivor is
# recognised by its exact argv and re-verified immediately before it is killed; a recycled pid or pgid can never match. Concurrent probe instances cannot see or
# kill each other's processes. It is a probe, not a gate: it prints "orphans: <total> in <trials with orphans> of <trials> trials".
set -uo pipefail
LEGACY=0; [[ "${1:-}" == --legacy ]] && { LEGACY=1; shift; }
SRC="${1:-${0:A:h:h}/test_signal_deadlock.zsh}"; N="${2:-20}"
zmodload zsh/datetime
PL=$(sed -n "/^read -r -d '' _REAPER_PL <<'PERL'\$/,/^PERL\$/p" "$SRC" | sed '1d;$d')
[[ -n "$PL" ]] || PL=$(<"$SRC")   # a bare perl file (the saved pre-fix reaper) is accepted too
BASE=$(mktemp -d /tmp/q01probe.XXXXXX) || exit 1
typeset -A ID
_idstr() { ps -o lstart=,command= -p "$1" 2>/dev/null; }
_reg() {   # <pid> <expected argv substring>: remember the identity once the process shows its final argv
  local i; for (( i = 0; i < 60; i++ )); do [[ "$(_idstr "$1")" == *"$2"* ]] && { ID[$1]=$(_idstr "$1"); return 0; }; sleep 0.05; done; return 1
}
_sig() { [[ -n "${ID[$2]:-}" && "$(_idstr "$2")" == "${ID[$2]}" ]] && kill -"$1" "$2" 2>/dev/null; }   # <signal> <pid>
cleanup() { local p; for p in ${(k)ID}; do _sig 9 "$p"; done; rm -rf "$BASE"; }
trap cleanup EXIT
_survivors() { ps -axww -o pid= -o command= | awk -v c="sleep $1" '{ p = $1; $1 = ""; sub(/^ /, ""); if ($0 == c) print p }'; }   # <token>: pids whose argv is exactly `sleep <token>`
total=0; bad=0
for (( n = 1; n <= N; n++ )); do
  T="$BASE/rlpc01.T$n"; mkdir -p "$T/pids" "$T/subs" "$T/labels"
  TOK=700.$(printf '%d%04d' $$ $n)   # unique to this probe instance and trial
  sleep 600 >/dev/null 2>&1 & FAKE=$!; _reg $FAKE "sleep 600"
  perl -e "$PL" -- $FAKE "$T" </dev/null >/dev/null 2>&1 &!
  for (( i = 0; i < 100; i++ )); do [[ -s "$T/reaper.ready" ]] && break; sleep 0.05; done
  RP=$(<"$T/reaper.ready"); _reg $RP "perl -e"
  perl -e 'setpgrp(0,0); exec @ARGV or die' zsh -fc 'zmodload zsh/system zsh/datetime
    if (( $3 )); then print -r -- $sysparams[pid] > "$2"; else print -r -- "$sysparams[pid] $EPOCHSECONDS" > "$2"; fi
    for (( i = 0; i < 400; i++ )); do sleep $4 & done; wait' zsh "$T/harness.zsh" "$T/pids/L" $LEGACY "$TOK" </dev/null >/dev/null 2>&1 &
  LP=$!; _reg $LP "zsh -fc"
  sleep $(( (RANDOM % 130 + 20) / 1000.0 ))
  _sig 9 $FAKE; wait $FAKE 2>/dev/null; unset "ID[$FAKE]"   # our own child, killed on purpose and reaped here: retire it
  for (( i = 0; i < 100; i++ )); do kill -0 $RP 2>/dev/null || break; sleep 0.1; done
  kill -0 $RP 2>/dev/null && _sig 9 $RP   # the reaper should have exited by itself; this only fires on a hung reaper, and only if it is still the same process
  unset "ID[$RP]"
  left=($(_survivors $TOK))
  if (( ${#left} )); then
    (( ++bad )); (( total += ${#left} ))
    for p in $left; do [[ "$(ps -o command= -p "$p" 2>/dev/null)" == "sleep $TOK" ]] && kill -9 "$p" 2>/dev/null; done   # re-verified argv, right before the kill
  fi
  _sig 9 $LP; wait $LP 2>/dev/null; unset "ID[$LP]"   # the leader is normally gone already (identity mismatch: no signal)
  rm -rf "$T"   # retire this trial
done
print "orphans: $total in $bad of $N trials ($SRC)"
