#!/bin/zsh
# Q-01 acceptance: when tests/test_signal_deadlock.zsh is killed from OUTSIDE it must leave no leader process, no tmux server it created
# and no temp byte behind within LIMIT seconds. One scenario per way the test can be killed:
#   TERM INT HUP   the signal goes to the test pid only (its traps run the cleanup)
#   PIPE           the reader of the test's stdout dies; the test gets SIGPIPE on its next stdout write
#   KILL           SIGKILL of the test pid only (no trap can run: the out-of-group reaper does the cleanup)
#   PGKILL         SIGKILL of the test's whole process group (what `npm run test:zsh`'s perl runner does on timeout: `kill 9,-$p`)
#   KILLTREE       SIGKILL of the test pid and of its direct children except the reaper (the trial subshells): the leaders and tmux servers are orphaned live
#                  (without a supervisor a leader would run on until its own 45 s loop ends)
#   NORMAL         control: no kill; the test finishes by itself and its reaper must not linger
# Each scenario runs the test with its own TMPDIR and TMUX_TMPDIR (inside one scratch dir /tmp/q01acc.*), so every temp byte and every tmux
# socket of the run lives under that dir, and the dir is checked by path (never by name patterns that could match someone else's processes).
# Observation is by recorded identity only: the pid and label files the test records, plus the command lines that contain the scratch dir.
# A RED run cleans up what it observes (same identities) so it leaves no residue itself.
# Knobs: Q01_LIMIT_S (bound after the kill, default 15), Q01_MODES (default "TERM INT HUP PIPE KILL PGKILL KILLTREE NORMAL CLEANUPSAFE PADDEDPS"), Q01_READY_S (default 90).
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
TEST="$SCRIPT_DIR/test_signal_deadlock.zsh"
LIMIT_S=${Q01_LIMIT_S:-15}
READY_S=${Q01_READY_S:-90}
MODES=(${=Q01_MODES:-TERM INT HUP PIPE KILL PGKILL KILLTREE NORMAL CLEANUPSAFE PADDEDPS})
[[ -f "$TEST" ]] || { print -u2 "FAIL: $TEST not found"; exit 1; }
for _t in perl tmux ps; do command -v $_t >/dev/null 2>&1 || { print -u2 "FAIL: $_t not installed"; exit 1; }; done
zmodload zsh/datetime

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

typeset -g ACC="" TPID="" RPID="" SNAP_REAPER=""
typeset -ga SNAP_PIDS SNAP_LEADERS SNAP_LABELS SNAP_UP
typeset -gA KNOWN
typeset -g TCMD=""   # the test's own argv, captured once at launch

_idstr() { ps -o lstart=,command= -p "$1" 2>/dev/null; }   # identity of a process: start time + argv at one moment
_alive() {   # a zombie is dead
  local s; kill -0 "$1" 2>/dev/null || return 1
  s=$(ps -o stat= -p "$1" 2>/dev/null); s=${s// /}
  [[ -n "$s" && "$s" != Z* ]]
}
_num() { [[ "$1" == <1-> ]] && (( $1 > 1 )); }

_snapshot() {   # what the test has recorded so far, under this scenario's TMPDIR only
  local d f p r c l
  SNAP_PIDS=(); SNAP_LEADERS=(); SNAP_LABELS=(); SNAP_UP=(); SNAP_REAPER=""
  for d in "$ACC"/tmpdir/*(N/); do
    for f in "$d"/pids/*(N) "$d"/subs/*(N); do
      p=$(<"$f") 2>/dev/null; r=${p#* }; p=${p%% *}; _num "$p" && _alive "$p" || continue   # records are "<pid> <registration time>"
      [[ "$r" == <-> && -z "${KNOWN[$p]:-}" ]] && { KNOWN[$p]=$r; print -r -- "$p $r" >> "$ACC/ids/reg"; }
      SNAP_PIDS+=($p $(pgrep -P "$p" 2>/dev/null))
      [[ "$f" == */pids/* ]] && SNAP_LEADERS+=($p)
    done
    for f in "$d"/labels/*(N); do
      l=$(<"$f") 2>/dev/null; [[ "$l" == rlpc01_* ]] || continue
      SNAP_LABELS+=($l)
      tmux -L "$l" list-sessions >/dev/null 2>&1 && SNAP_UP+=($l)
    done
    if [[ -f "$d/reaper.ready" ]]; then p=$(<"$d/reaper.ready") 2>/dev/null; _num "$p" && SNAP_REAPER=$p; fi
  done
  SNAP_PIDS=(${(u)SNAP_PIDS}); SNAP_LEADERS=(${(u)SNAP_LEADERS}); SNAP_LABELS=(${(u)SNAP_LABELS})
}

_ps_scan() {   # pids whose command line contains the scratch dir or one of the observed labels
  local ln p cmd l
  ps -axww -o pid= -o command= 2>/dev/null | while read -r p cmd; do   # `read` also strips the padding of low pids
    [[ "$p" == $$ ]] && continue
    [[ "$cmd" == "ps -axww"* ]] && continue
    if [[ "$cmd" == *"$ACC/"* ]]; then print -r -- $p; continue; fi
    for l in $SNAP_LABELS; do [[ "$cmd" == *"$l"* ]] && { print -r -- $p; break; }; done
  done
}

_residue() {   # one line per item still alive / still on disk; empty output = clean
  local p l names f cmd
  for p in $SNAP_PIDS $TPID $SNAP_REAPER; do
    [[ -n "$p" ]] && _alive "$p" && print -r -- "process $p alive: $(ps -o command= -p $p 2>/dev/null | cut -c1-90)"
  done
  for p in $(_ps_scan); do print -r -- "process $p mentions the scratch dir/label: $(ps -o command= -p $p 2>/dev/null | cut -c1-90)"; done
  for l in $SNAP_LABELS; do tmux -L "$l" list-sessions >/dev/null 2>&1 && print -r -- "tmux server $l still answers"; done
  for p in $(pgrep -x tmux 2>/dev/null); do   # a server whose socket was unlinked is found through its open files, never through ls
    names=$(lsof -a -p "$p" -U -Fn 2>/dev/null)
    for l in $SNAP_LABELS; do [[ "$names" == *"/$l"* ]] && print -r -- "tmux server pid $p holds a socket of $l"; done
  done
  for f in "$ACC"/tmux/**/*(N^/); do print -r -- "tmux socket file left: $f"; done
  for f in "$ACC"/tmpdir/*(N); do print -r -- "temp entry left: $f"; done
}

# --- Signal discipline of this harness: a signal goes to a pid only after its identity is verified at that moment. Identities are captured when we create a process
# (`$ACC/ids/tpid`, `ids/rpid`: start time + argv) or read from the test's own registration records ("<pid> <registration time>": the live process must have started
# no later than that time + 2 s, otherwise the pid was recycled). `_ps_scan` (a command-line substring scan) only feeds `_residue`, i.e. diagnostics, never a kill list. ---
_same_id() { [[ "$1" == <2-> && -s "$2" && "$(_idstr "$1")" == "$(<"$2")" ]]; }   # <pid> <identity file>
_etime_secs() { local e="${1// /}" d=0 s=0 x; [[ "$e" == *-* ]] && { d=${e%%-*}; e=${e#*-}; }; for x in ${(s.:.)e}; do s=$(( s * 60 + 10#$x )); done; print -r -- $(( d * 86400 + s )); }
_reg_pids() {   # <pids|subs|all>: registered pids that pass BOTH checks from one `ps` call: started no later than the registration (+2 s of ps resolution), and the argv
                # names this run: a leader (pids/) runs `<run dir>/harness.zsh` or still carries the test's own argv (fork before exec), a trial subshell (subs/) carries the test's argv
  local f p r line et cmd kind; local -a files
  [[ -z "$TCMD" && -s "$ACC/ids/tcmd" ]] && TCMD=$(<"$ACC/ids/tcmd")
  files=(); [[ "$1" == all ]] && files=("$ACC"/ids/reg(N)); [[ "$1" != subs ]] && files+=("$ACC"/tmpdir/*/pids/*(N)); [[ "$1" != pids ]] && files+=("$ACC"/tmpdir/*/subs/*(N))
  for f in $files; do
    kind=${f:h:t}; [[ "$f" == "$ACC/ids/reg" ]] && kind=any
    while read -r p r; do
      [[ "$p" == <2-> && "$r" == <-> ]] || continue
      line=$(ps -o etime= -o command= -p "$p" 2>/dev/null); [[ -n "$line" ]] || continue
      read -r et cmd <<< "$line"   # ps pads etime; `read` splits without EXTENDED_GLOB (a bare ${x## #} trims nothing)
      (( EPOCHSECONDS - $(_etime_secs "$et") <= r + 2 )) || continue
      case "$kind" in
        pids) [[ "$cmd" == *"${f:h:h}/harness.zsh"* || ( -n "$TCMD" && "$cmd" == "$TCMD" ) ]] || continue ;;
        subs) [[ -n "$TCMD" && "$cmd" == "$TCMD" ]] || continue ;;
        *)    [[ "$cmd" == *"$ACC/tmpdir/"*"/harness.zsh"* || ( -n "$TCMD" && "$cmd" == "$TCMD" ) ]] || continue ;;
      esac
      print -r -- $p
    done < "$f"
  done | sort -un
}
_owned() {   # verified registered pids and their descendants, computed from ONE ps snapshot
  local snap ln p q grew; local -A pp own
  snap=$(ps -axww -o pid= -o ppid= 2>/dev/null)
  for ln in ${(f)snap}; do pp[${${=ln}[1]}]=${${=ln}[2]}; done
  for p in $(_reg_pids all); do [[ -n "${pp[$p]:-}" && "$p" != $$ ]] && own[$p]=1; done
  for (( grew = 1; grew; )); do
    grew=0
    for q in ${(k)pp}; do [[ -z "${own[$q]:-}" && "$q" != $$ && -n "${own[${pp[$q]}]:-}" ]] && { own[$q]=1; grew=1; }; done
  done
  print -r -- ${(k)own}
}
_tsig() { _same_id "$TPID" "$ACC/ids/tpid" && kill "$@"; }   # signal the test (or its group) only while the pid is still the process we launched
_acc_cleanup() {   # by verified identities only
  local i p l
  [[ -n "$ACC" && -d "$ACC" ]] || return 0
  for (( i = 0; i < 3; i++ )); do
    _snapshot
    # the test's process group only while the test pid is still the unreaped group leader we launched; then the pid itself
    _same_id "$TPID" "$ACC/ids/tpid" && { kill -9 -- -$TPID 2>/dev/null; kill -9 "$TPID" 2>/dev/null; }
    _same_id "${RPID:-}" "$ACC/ids/rpid" && kill -9 "$RPID" 2>/dev/null
    for p in $(_owned); do kill -9 "$p" 2>/dev/null; done
    for l in $SNAP_LABELS; do tmux -L "$l" kill-server >/dev/null 2>&1; done
    sleep 0.3
  done
  for l in $SNAP_LABELS; do tmux -L "$l" kill-server >/dev/null 2>&1; done
  [[ -n "$TPID" ]] && ! _alive "$TPID" && wait "$TPID" 2>/dev/null   # never block on a live pid
  rm -rf "$ACC"; sleep 0.2; rm -rf "$ACC"
  ACC=""; TPID=""; RPID=""; TCMD=""; KNOWN=(); unset TMUX_TMPDIR
}
if [[ "${1:-}" == --cleanup ]]; then   # clean child started by _acc_sig: <scratch dir> <test pid> <reader pid> <exit status>
  ACC="$2"; TPID="$3"; RPID="$4"; export TMUX_TMPDIR="$ACC/tmux"
  _acc_cleanup; exit "${5:-0}"
fi
# A signal handler must not fork (zsh runs it inside the signal context; a fork with redirections or a pipe there can deadlock on a stdio lock, the C-01 class):
# it execs a fresh zsh that does the cleanup from normal context. The EXIT trap is for the normal end only and is disarmed before the exec.
SELF="${0:A}"
_acc_sig() {   # <signal number>
  trap - EXIT INT TERM HUP
  [[ -n "$ACC" ]] && exec zsh -f "$SELF" --cleanup "$ACC" "${TPID:-}" "${RPID:-}" $(( 128 + $1 ))
  exit $(( 128 + $1 ))
}
trap '_acc_sig 2' INT
trap '_acc_sig 15' TERM
trap '_acc_sig 1' HUP
trap '_acc_cleanup' EXIT

_idsave() {   # <pid> <file> <glob for the final argv>: wait until the argv matches (a forked shell shows its parent's argv until it execs), then store start time + argv
  local i c; for (( i = 0; i < 100; i++ )); do c=$(ps -o command= -p "$1" 2>/dev/null); [[ -n "$c" && "$c" == $~3 ]] && { _idstr "$1" > "$2"; return 0; }; sleep 0.05; done; return 1
}

_launch() {   # <mode>: starts the test the way the npm runner does (own process group, default signal dispositions)
  local mode="$1" out="$ACC/out"
  if [[ "$mode" == PIPE ]]; then
    mkfifo "$ACC/fifo"; cat <>"$ACC/fifo" >/dev/null & RPID=$!   # <> so the open does not block before the exec (the identity below needs the final argv)
    _idsave "$RPID" "$ACC/ids/rpid" "cat"
    out="$ACC/fifo"
  fi
  ( export TMPDIR="$ACC/tmpdir" TMUX_TMPDIR="$ACC/tmux" C01_TRIALS_STRESS=12 C01_TRIALS_STRESSLOG=0 C01_TRIALS_STRESSDEBUG=0 C01_TRIALS_STRESSREFRESH=0 C01_PAR=3
    [[ "$mode" == PIPE ]] && export C01_PROGRESS=1
    exec perl -e 'setpgrp(0,0); $SIG{$_}="DEFAULT" for qw(INT HUP TERM PIPE QUIT); exec @ARGV or die "exec: $!"' zsh "$TEST" >"$out" 2>"$ACC/err" </dev/null ) &
  TPID=$!
  _idsave "$TPID" "$ACC/ids/tpid" "zsh */test_signal_deadlock.zsh"   # after the perl exec chain the argv names the test
  TCMD=$(ps -o command= -p "$TPID" 2>/dev/null); print -r -- "$TCMD" > "$ACC/ids/tcmd"
}

_run_scenario() {
  local mode="$1" t0 t1 elapsed res rc exp sig
  local -A signo=(TERM 15 INT 2 HUP 1 PIPE 13 KILL 9 PGKILL 9 KILLTREE 9 NORMAL 0)
  ACC=$(mktemp -d /tmp/q01acc.XXXXXX) || { no "$mode: cannot create the scratch dir"; return; }   # short path: unix socket paths are limited to ~104 bytes
  mkdir -p "$ACC/tmpdir" "$ACC/tmux" "$ACC/ids"; KNOWN=(); TCMD=""
  export TMUX_TMPDIR="$ACC/tmux"   # this process looks at the scenario's servers, never at the default socket dir
  print "[$mode] launching $TEST (scratch $ACC)"
  _launch "$mode"
  t0=$EPOCHREALTIME
  if [[ "$mode" == NORMAL ]]; then
    while _alive "$TPID" && (( EPOCHREALTIME - t0 < 300 )); do sleep 0.2; done
    _alive "$TPID" && { no "$mode: the test did not finish within 300 s"; _acc_cleanup; return; }
    wait "$TPID" 2>/dev/null; rc=$?
    print "  [$mode] test finished by itself, exit status $rc"
    _snapshot   # nothing is recorded any more; the scan below goes by the scratch dir
  else
    while (( EPOCHREALTIME - t0 < READY_S )); do
      _snapshot
      (( ${#SNAP_LEADERS} && ${#SNAP_UP} )) && break
      _alive "$TPID" || break
      sleep 0.02
    done
    if ! (( ${#SNAP_LEADERS} && ${#SNAP_UP} )); then
      local _alive_s=no _rc=running; _alive "$TPID" && _alive_s=yes
      _alive "$TPID" || { wait "$TPID" 2>/dev/null; _rc=$?; }
      no "$mode: the test never reached the state 'a leader and an answering tmux server exist' after $(printf %.1f $(( EPOCHREALTIME - t0 ))) s (test alive=$_alive_s, exit status=$_rc; snapshot: ${#SNAP_LEADERS} live leader(s), ${#SNAP_UP} answering server(s), ${#SNAP_LABELS} label(s); tmpdir entries: $(print -r -- "$ACC"/tmpdir/*(N:t) | head -c 200))"$'\n'"      inner stdout (first 5 lines): $(head -5 "$ACC/out" 2>/dev/null | head -c 600 | tr '\n' '|')"$'\n'"      inner stderr (first 5 lines): $(head -5 "$ACC/err" 2>/dev/null | head -c 600 | tr '\n' '|')"
      _acc_cleanup; return
    fi
    print "  [$mode] observed ${#SNAP_LEADERS} leader(s), ${#SNAP_UP} answering tmux server(s), ${#SNAP_PIDS} recorded pid(s) incl. children, reaper=${SNAP_REAPER:-none}; applying the kill"
    case "$mode" in
      TERM|INT|HUP) _tsig -$mode "$TPID" ;;
      KILL)         _tsig -9 "$TPID" ;;
      PGKILL)       _tsig -9 -- -$TPID ;;
      KILLTREE)     local -a kids; kids=($(_reg_pids subs)); (( ${#kids} )) || no "KILLTREE: no registered trial subshell was selected (the kill list would silently degrade to a plain KILL)"; _tsig -9 $TPID $kids ;;   # the test and its registered trial subshells (not the reaper)
      PIPE)         _same_id "$RPID" "$ACC/ids/rpid" && kill "$RPID" ;;
    esac
  fi
  t1=$EPOCHREALTIME
  while true; do
    res=$(_residue)
    [[ -z "$res" ]] && break
    (( EPOCHREALTIME - t1 > LIMIT_S )) && break
    sleep 0.25
  done
  elapsed=$(printf %.1f $(( EPOCHREALTIME - t1 )))
  if [[ -z "$res" ]]; then
    ok "$mode: no leader, no tmux server, no temp byte, no reaper left ${elapsed}s after the kill (limit ${LIMIT_S}s; observed pids: ${SNAP_PIDS[*]}; labels: ${SNAP_LABELS[*]})"
  else
    no "$mode: residue ${LIMIT_S}s after the kill:"$'\n'"$(print -r -- "$res" | sed 's/^/      /')"
  fi
  if [[ "$mode" != NORMAL ]]; then   # the test reports the signal it died of (128+n) once the cleanup is done
    while _alive "$TPID" && (( EPOCHREALTIME - t1 < LIMIT_S )); do sleep 0.1; done   # deadline polling from the kill, never an immediate check (B-H2-05)
    if _alive "$TPID"; then no "$mode: the test process itself is still alive after ${LIMIT_S}s"
    else
      wait "$TPID" 2>/dev/null; rc=$?; exp=$(( 128 + ${signo[$mode]} ))
      (( rc == exp )) && ok "$mode: the test ended with status $rc (128+${signo[$mode]})" || no "$mode: the test ended with status $rc, expected $exp"
    fi
  fi
  _acc_cleanup
}

# CLEANUPSAFE: the harness's own cleanup must signal only what it launched or what is registered with a matching identity. Decoys it must NOT touch: a process whose
# argv mentions the scratch dir (a developer's `tail -f <scratch>/err`), a live process behind a STALE registration (a recycled pid), and a TPID whose recorded identity
# does not match (the test pid was reaped and recycled). Controls it MUST end: a freshly registered leader, and a TPID whose recorded identity matches.
_run_cleanupsafe() {
  local d1 d2 d3 d4 d5 ctrl ctpid now p fail=0 st
  typeset -A cid
  _cid() { local i; for (( i = 0; i < 60; i++ )); do [[ "$(_idstr "$1")" == *"$2"* ]] && { cid[$1]=$(_idstr "$1"); return 0; }; sleep 0.05; done; return 1; }
  ACC=$(mktemp -d /tmp/q01acc.XXXXXX) || { no "CLEANUPSAFE: cannot create the scratch dir"; return; }
  mkdir -p "$ACC/tmpdir/rlpc01.FAKE/pids" "$ACC/tmpdir/rlpc01.FAKE/subs" "$ACC/tmpdir/rlpc01.FAKE/labels" "$ACC/tmux" "$ACC/ids"
  export TMUX_TMPDIR="$ACC/tmux"; : > "$ACC/err"
  print "[CLEANUPSAFE] decoys and controls (scratch $ACC)"
  tail -f "$ACC/err" >/dev/null 2>&1 & d1=$!; _cid $d1 "tail -f"
  sleep 311 & d2=$!; _cid $d2 "sleep 311"
  sleep 312 & d3=$!; _cid $d3 "sleep 312"
  zsh -fc 'sleep 313 & wait' zsh "$ACC/tmpdir/rlpc01.FAKE/harness.zsh" >/dev/null 2>&1 & ctrl=$!; _cid $ctrl "zsh -fc"   # a leader-shaped control: argv names this run's harness
  sleep 315 & d4=$!; _cid $d4 "sleep 315"   # fresh registration in pids/, argv matches neither the harness nor the test
  sleep 316 & d5=$!; _cid $d5 "sleep 316"   # fresh registration in subs/, argv is not the test's
  sleep 314 & ctpid=$!; _cid $ctpid "sleep 314"
  now=$EPOCHSECONDS
  print -r -- "$d2 $(( now - 3600 ))" > "$ACC/tmpdir/rlpc01.FAKE/pids/stale"
  print -r -- "$ctrl $now" > "$ACC/tmpdir/rlpc01.FAKE/pids/ctrl"
  print -r -- "$d4 $now" > "$ACC/tmpdir/rlpc01.FAKE/pids/fresh-wrong-argv"
  print -r -- "$d5 $now" > "$ACC/tmpdir/rlpc01.FAKE/subs/fresh-wrong-argv"
  # run 1: TPID is a recycled-pid stand-in (recorded identity does not match the live process)
  TPID=$d3; print -r -- "bogus identity" > "$ACC/ids/tpid"
  _acc_cleanup
  for p in $d1 $d2 $d3 $d4 $d5; do _alive $p && print "  ok   decoy $p ($(ps -o command= -p $p | cut -c1-30)) survived the harness cleanup" || { print "  FAIL decoy $p was signalled by the harness cleanup"; fail=1; }; done
  _alive $ctrl && { print "  FAIL the registered leader $ctrl survived the cleanup"; fail=1; } || print "  ok   the registered leader $ctrl was ended"
  # run 2: TPID with a matching recorded identity must be ended
  ACC=$(mktemp -d /tmp/q01acc.XXXXXX); mkdir -p "$ACC/tmpdir" "$ACC/tmux" "$ACC/ids"; export TMUX_TMPDIR="$ACC/tmux"
  TPID=$ctpid; print -r -- "${cid[$ctpid]}" > "$ACC/ids/tpid"
  _acc_cleanup
  _alive $ctpid && { print "  FAIL the test pid $ctpid (matching identity) survived the cleanup"; fail=1; } || print "  ok   the test pid $ctpid (matching identity) was ended"
  for p in ${(k)cid}; do [[ "$(_idstr $p)" == "${cid[$p]}" ]] && kill -9 $p 2>/dev/null; done   # our own decoys, identity-checked
  (( fail )) && no "CLEANUPSAFE: the harness cleanup signalled a process it does not own, or missed one it owns" || ok "CLEANUPSAFE: the harness cleanup left unrelated and stale-registered processes alone and ended the registered ones"
  unset TMUX_TMPDIR
}

# PADDEDPS: `ps` pads its columns (procps pads etime to ~11 characters, BSD ps right-aligns it, and pids are padded in `ps -axww -o pid=` output), and a bare
# `${x## #}` trims nothing without EXTENDED_GLOB. A stub `ps` that emits such padding must still let the harness select a leader and a trial subshell registered 30 s
# earlier (so the start-time check works on the parsed etime and the argv compare works on the parsed command), reject records whose argv matches neither form, and
# let `_ps_scan` read a padded low pid. The same table drives the no-perl `--degraded-cleanup` mode of the test, which really kills the selected (real) processes.
_run_paddedps() {
  local lead sub wl ws now reg pad p fail=0 got real_ps want
  typeset -A cid
  _cid() { local i; for (( i = 0; i < 60; i++ )); do [[ "$(_idstr "$1")" == *"$2"* ]] && { cid[$1]=$(_idstr "$1"); return 0; }; sleep 0.05; done; return 1; }
  ACC=$(mktemp -d /tmp/q01acc.XXXXXX) || { no "PADDEDPS: cannot create the scratch dir"; return; }
  pad="$ACC/tmpdir/rlpc01.PAD"
  mkdir -p "$pad/pids" "$pad/subs" "$ACC/stubbin" "$ACC/ids" "$ACC/tmux"; export TMUX_TMPDIR="$ACC/tmux"; KNOWN=(); TCMD="zsh tests/test_signal_deadlock.zsh"
  print "[PADDEDPS] stub ps with Linux-style and BSD-style padding (scratch $ACC)"
  sleep 321 & lead=$!;  _cid $lead "sleep 321"   # real processes; the stub ps reports the argv/etime a real leader / subshell would show
  sleep 322 & sub=$!;   _cid $sub "sleep 322"
  sleep 323 & wl=$!;    _cid $wl "sleep 323"       # wrong argv, recorded as a leader
  sleep 324 & ws=$!;    _cid $ws "sleep 324"       # wrong argv, recorded as a trial subshell
  now=$EPOCHSECONDS; reg=$(( now - 30 ))
  print -r -- "$lead $reg" > "$pad/pids/lead"; print -r -- "$sub $reg" > "$pad/subs/sub"; print -r -- "$wl $reg" > "$pad/pids/wrong"; print -r -- "$ws $reg" > "$pad/subs/wrong"
  print -r -- "$lead|lin|05:00|zsh -f $pad/harness.zsh $pad/trial.X stress" > "$ACC/table"
  print -r -- "$sub|bsd|05:00|$TCMD" >> "$ACC/table"
  print -r -- "$wl|lin|05:00|sleep 999" >> "$ACC/table"
  print -r -- "$ws|bsd|05:00|sleep 998" >> "$ACC/table"
  printf '%5s %s\n' 12 "tail -f $ACC/err" > "$ACC/scan"; printf '%5s %s\n' 4321 "unrelated" >> "$ACC/scan"
  real_ps=$(command -v ps)
  cat > "$ACC/stubbin/ps" <<STUB
#!/bin/sh
case "\$*" in
  "-o etime= -o command= -p "*)
    for a; do pid=\$a; done; line=\$(grep "^\$pid|" "$ACC/table") || exit 1
    rest=\${line#*|}; style=\${rest%%|*}; rest=\${rest#*|}; et=\${rest%%|*}; cmd=\${rest#*|}
    if [ "\$style" = lin ]; then printf '%11s %s\\n' "\$et" "\$cmd"; else printf '%8s %s\\n' "\$et" "\$cmd"; fi ;;
  "-axww -o pid= -o command=") cat "$ACC/scan" ;;
  *) exec $real_ps "\$@" ;;
esac
STUB
  chmod +x "$ACC/stubbin/ps"
  got=$(PATH="$ACC/stubbin:$PATH" _reg_pids all | tr '\n' ' '); want=$(print -l $lead $sub | sort -n | tr '\n' ' ')
  [[ "$got" == "$want" ]] && print "  ok   _reg_pids selected exactly the leader and the subshell registered 30 s earlier ($got)" || { print "  FAIL _reg_pids selected [$got], expected [$want] (padded ps output not parsed)"; fail=1; }
  got=$(PATH="$ACC/stubbin:$PATH" _ps_scan | tr '\n' ' ')
  [[ "$got" == "12 " ]] && print "  ok   _ps_scan read the padded low pid (12)" || { print "  FAIL _ps_scan returned [$got], expected [12 ] (padded pid column not parsed)"; fail=1; }
  PATH="$ACC/stubbin:$PATH" zsh -f "$TEST" --degraded-cleanup "$pad" 0 "zsh tests/test_signal_deadlock.zsh"
  for p in $lead $sub; do _alive $p && { print "  FAIL degraded cleanup did not end the registered pid $p (padded ps output not parsed)"; fail=1; } || print "  ok   degraded cleanup ended the registered pid $p"; done
  for p in $wl $ws; do _alive $p && print "  ok   degraded cleanup left the wrong-argv pid $p alone" || { print "  FAIL degraded cleanup signalled the wrong-argv pid $p"; fail=1; }; done
  for p in ${(k)cid}; do [[ "$(_idstr $p)" == "${cid[$p]}" ]] && kill -9 $p 2>/dev/null; done
  rm -rf "$ACC"; ACC=""; TCMD=""; KNOWN=(); unset TMUX_TMPDIR
  (( fail )) && no "PADDEDPS: padded ps output is not parsed correctly" || ok "PADDEDPS: Linux- and BSD-style padded ps output is parsed (selection, argv compare, scan, degraded cleanup)"
}

print "Q-01: external kill of tests/test_signal_deadlock.zsh leaves nothing behind (bound ${LIMIT_S}s)"
print "  before: tmux servers=$(pgrep -x tmux | wc -l | tr -d ' ') rlpc01 processes=$(pgrep -f 'rlpc0[1]' | wc -l | tr -d ' ')"
for m in $MODES; do
  case "$m" in CLEANUPSAFE) _run_cleanupsafe ;; PADDEDPS) _run_paddedps ;; *) _run_scenario "$m" ;; esac
done
print "  after:  tmux servers=$(pgrep -x tmux | wc -l | tr -d ' ') rlpc01 processes=$(pgrep -f 'rlpc0[1]' | wc -l | tr -d ' ')"
print ""
print "=== test_signal_deadlock_external_kill.zsh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
