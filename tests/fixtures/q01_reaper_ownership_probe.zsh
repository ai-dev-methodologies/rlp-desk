#!/bin/zsh
# Q-01 / A-C1-01, A-C1-02, R1-06, A-C2-02 probe: the reaper may signal only processes it can prove are ours.
# usage: q01_reaper_ownership_probe.zsh [--legacy] [<zsh file holding _REAPER_PL>]   (default: tests/test_signal_deadlock.zsh)
#   --legacy writes the old one-field pid records (for running the probe against the pre-fix reaper)
# Scenario (all processes are created here and identified by start time + argv; nothing else is touched): a fake test (sleep 600) with a real reaper on a scratch $T.
#   control   a REGISTERED leader (record "<pid> <epoch>" in $T/pids, argv carries $T/harness.zsh) with a child sleep  -> must be reaped (both gone)
#   decoy A   NOT registered, argv carries $T/harness.zsh and the string test_signal_deadlock (an editor viewing the file, another run)  -> must survive
#   decoy B   a child of decoy A                                                                                         -> must survive
#   decoy C   pid-reuse stand-in: a live process recorded in $T/pids with a registration time of 1 h ago, i.e. it started AFTER the registrant died -> must survive
#   decoy D   the same for $T/subs                                                                                       -> must survive
# Cleanup signals a pid only while its identity (start time + argv captured at creation) still matches; pids expected dead are never signalled again, and children
# are never found through `pgrep -P` of a pid that may have been recycled (they are registered individually when created).
# Prints one line per item and "ownership: PASS|FAIL"; exit status 0 on PASS.
set -uo pipefail
LEGACY=0; [[ "${1:-}" == --legacy ]] && { LEGACY=1; shift; }
SRC="${1:-${0:A:h:h}/test_signal_deadlock.zsh}"
zmodload zsh/system zsh/datetime
PL=$(sed -n "/^read -r -d '' _REAPER_PL <<'PERL'\$/,/^PERL\$/p" "$SRC" | sed '1d;$d'); [[ -n "$PL" ]] || PL=$(<"$SRC")
BASE=$(mktemp -d /tmp/q01own.XXXXXX) || exit 1
T="$BASE/rlpc01.OWN"; mkdir -p "$T/pids" "$T/subs" "$T/labels"
typeset -A ID
_idstr() { ps -o lstart=,command= -p "$1" 2>/dev/null; }
_reg() { local i; for (( i = 0; i < 60; i++ )); do [[ "$(_idstr "$1")" == *"$2"* ]] && { ID[$1]=$(_idstr "$1"); return 0; }; sleep 0.05; done; return 1; }
_sig() { [[ -n "${ID[$2]:-}" && "$(_idstr "$2")" == "${ID[$2]}" ]] && kill -"$1" "$2" 2>/dev/null; }   # <signal> <pid>
cleanup() { local p; for p in ${(k)ID}; do _sig 9 "$p"; done; rm -rf "$BASE"; }
trap cleanup EXIT
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" != Z* ]]; }
rec() {   # <file> <pid> <epoch>
  if (( LEGACY )); then print -r -- "$2" > "$1"; else print -r -- "$2 $3" > "$1"; fi
}
sleep 600 >/dev/null 2>&1 & FAKE=$!; _reg $FAKE "sleep 600"
perl -e "$PL" -- $FAKE "$T" </dev/null >/dev/null 2>&1 &!
for (( i = 0; i < 100; i++ )); do [[ -s "$T/reaper.ready" ]] && break; sleep 0.05; done
RP=$(<"$T/reaper.ready"); _reg $RP "perl -e"
# control: registers itself (pid + its own clock) like a real leader does, then keeps a child sleeping
zsh -fc 'zmodload zsh/system zsh/datetime; print -r -- "$sysparams[pid] $EPOCHSECONDS" > "$2"; sleep 300 & wait' zsh "$T/harness.zsh" "$T/pids/L.raw" >/dev/null 2>&1 & LP=$!
# decoy A (+ its child B): same look, never registered
zsh -fc 'sleep 301 & print -r -- $! > "$2"; wait' zsh "$T/harness.zsh" "$T/decoyB" test_signal_deadlock >/dev/null 2>&1 & DA=$!
# decoys C and D: live processes recorded with a stale registration time (1 h ago)
zsh -fc 'sleep 302 & wait' zsh "$T/harness.zsh" >/dev/null 2>&1 & DC=$!
zsh -fc 'sleep 303 & wait' zsh "$T/harness.zsh" >/dev/null 2>&1 & DD=$!
for (( i = 0; i < 100; i++ )); do [[ -s "$T/pids/L.raw" && -s "$T/decoyB" ]] && break; sleep 0.05; done
read -r LPID LEP < "$T/pids/L.raw"; rm -f "$T/pids/L.raw"
DB=$(<"$T/decoyB")
_reg $LP "zsh -fc"; _reg $DA "zsh -fc"; _reg $DC "zsh -fc"; _reg $DD "zsh -fc"
LKID=$(pgrep -P "$LP" | head -1); DCK=$(pgrep -P "$DC" | head -1); DDK=$(pgrep -P "$DD" | head -1)   # each parent's identity is registered above
[[ -n "$LKID" ]] && _reg $LKID "sleep 300"; _reg $DB "sleep 301"; [[ -n "$DCK" ]] && _reg $DCK "sleep 302"; [[ -n "$DDK" ]] && _reg $DDK "sleep 303"
rec "$T/pids/L" "$LPID" "$LEP"
rec "$T/pids/C" "$DC" $(( EPOCHSECONDS - 3600 ))
rec "$T/subs/D" "$DD" $(( EPOCHSECONDS - 3600 ))
sleep 0.5
_sig 9 $FAKE; wait $FAKE 2>/dev/null; unset "ID[$FAKE]"
for (( i = 0; i < 150; i++ )); do kill -0 $RP 2>/dev/null || break; sleep 0.1; done
fail=0
chk() {   # <name> <pid> <expect alive|dead>
  local st=dead; alive "$2" && st=alive
  [[ "$st" == "$3" ]] && print "  ok   $1 (pid $2) is $st, expected $3" || { print "  FAIL $1 (pid $2) is $st, expected $3"; fail=1; }
}
chk "control leader (registered)" $LPID dead
[[ -n "${LKID:-}" ]] && chk "control leader's child" $LKID dead
chk "decoy A (argv has \$T/ and test_signal_deadlock, unregistered)" $DA alive
chk "decoy B (child of decoy A)" $DB alive
chk "decoy C (stale registration in pids/)" $DC alive
chk "decoy D (stale registration in subs/)" $DD alive
chk "reaper itself exited" $RP dead
(( fail )) && print "ownership: FAIL" || print "ownership: PASS"
exit $fail
