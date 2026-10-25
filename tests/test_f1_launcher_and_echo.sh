#!/bin/zsh
# ============================================================================
# F1 / R2-F + S-7 (echo verification of the CURRENT line) and S-6 (launcher creation).
#
# R2-F / S-7: _paste_cmd_echo_verified used to look for the shared 24-char LEADING prefix
# of `source '<launcher>'` anywhere in the captured tail. The unique part of the line (the
# launcher filename) lies beyond that prefix, so an intact echo of a PREVIOUS launch above
# a corrupted CURRENT line (first char swallowed by an rc prompt) validated the paste and the
# corrupted line was executed. Contract now: the bottom-most non-blank rows of the capture
# must contain the ENTIRE short line, including its unique filename.
#
# S-6: the launcher was created with `noclobber`, which HANGS on a FIFO (and on a symlink to
# one). It is now created with zsh/system sysopen O_EXCL|O_CREAT mode 0600 (refuses FIFO,
# symlink, any existing path) and re-verified as a regular non-symlink file before the paste.
# A non-regular object at the launcher path is refused outright (rc 1, nothing pasted); an
# existing REGULAR file is a previous attempt's launcher and the next -k name is used.
#
# Mock tmux (the real-tmux proof is tests/test_w5_launch_echo_real_tmux.zsh).
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"; }
ERRLOG=""
log(){ :; }; log_debug(){ :; }; log_error(){ print -r -- "$*" >> "${ERRLOG:-/dev/null}"; }
ITERATION=1

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}
eval "$(_extract_fn _paste_cmd_echo_verified "$RUN")"
[[ "$(whence -w _paste_cmd_echo_verified 2>/dev/null)" == *function* ]] \
  && ok "extracted _paste_cmd_echo_verified" || { no "could not extract _paste_cmd_echo_verified"; exit 1; }
_wait_pane_shell_ready() { return 0; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/f1-launcher.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
REC="$TMPD/rec"; CNT="$TMPD/cnt"
_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# Driver: $1 = launcher dir, $2 = command, rest = capture-pane outputs per attempt (last reused).
# @LINE@ = the intact short line for THIS call's first launcher, @LINE1@ = same, first char
# swallowed, @PREV@ = an intact echo of a PREVIOUS launch (same prefix, other filename).
_drive() {
  local rt="$1" cmd="$2"; shift 2
  local -a CAPS=("$@")
  print -r -- 0 > "$CNT"
  RUNTIME_DIR="$rt"
  local _line="source '$RUNTIME_DIR/launch-worker-iter001.zsh'"
  local _prev="source '$RUNTIME_DIR/launch-worker-iter000.zsh'"
  CAPS=("${(@)CAPS//@LINE@/$_line}")
  CAPS=("${(@)CAPS//@LINE1@/${_line[2,-1]}}")
  CAPS=("${(@)CAPS//@PREV@/$_prev}")
  paste_to_pane() { print -r -- "PASTE $2" >> "$REC"; }
  tmux() {
    case "$1" in
      capture-pane)
        local n; n=$(cat "$CNT" 2>/dev/null || print 0); n=$((n + 1)); print -r -- "$n" > "$CNT"
        print -r -- "${CAPS[n]:-${CAPS[${#CAPS[@]}]}}";;
      send-keys) print -r -- "send-keys $*" >> "$REC";;
    esac
    return 0
  }
  _paste_cmd_echo_verified "%9" "$cmd"; local rc=$?
  unfunction paste_to_pane tmux
  print "RC=$rc"
}
_counts() { _p=$(grep -c '^PASTE' "$REC"); _cu=$(grep -c 'send-keys.*C-u' "$REC"); }
CMD='/opt/homebrew/bin/claude --model x --dangerously-skip-permissions'
newrt() { mktemp -d "$TMPD/rt.XXXXXX"; }

print "== R2-F: the CURRENT input row must hold the entire short line (incl. the unique filename) =="
# codex probe: an intact previous echo above a corrupted current line (first char swallowed)
: > "$REC"; out=$(_drive "$(newrt)" "$CMD" $'user@host ~ % @PREV@\nuser@host ~ % @LINE1@' $'user@host ~ % @PREV@\nuser@host ~ % @LINE@')
_counts
{ [[ "$_p" == 2 && "$_cu" == 1 && "$out" == "RC=0" ]]; } \
  && ok "R2-F probe: previous intact echo above a corrupted current line -> mismatch, C-u, re-paste, then RC=0 ($out)" \
  || no "R2-F probe: paste=$_p cu=$_cu $out (a previous echo validated the corrupted current line)"
: > "$REC"; out=$(_drive "$(newrt)" "$CMD" $'user@host ~ % @PREV@\nuser@host ~ % @LINE1@')
_counts
{ [[ "$_p" == 3 && "$_cu" == 3 && "$out" == "RC=1" ]]; } \
  && ok "R2-F persistent corruption under a previous intact echo -> 3 attempts, RC=1 ($out)" \
  || no "R2-F persistent: paste=$_p cu=$_cu $out"
: > "$REC"; out=$(_drive "$(newrt)" "$CMD" $'user@host ~ % @PREV@\nuser@host ~ % @LINE@')
_counts
{ [[ "$_p" == 1 && "$_cu" == 0 && "$out" == "RC=0" ]]; } \
  && ok "intact current line under a previous echo of another launcher -> verified at once ($out)" \
  || no "intact current line rejected: paste=$_p cu=$_cu $out"
# the current line wrapped over several rows (real tmux does not join ZLE rows): rows tile the line
_wrap_rows() { # $1 = full text, $2 = width -> rows joined by newlines (no separator char lost)
  local s="$1" w="$2" out="" i=1
  while (( i <= ${#s} )); do out+="${s[i,i+w-1]}"$'\n'; i=$(( i + w )); done
  print -r -- "${out%$'\n'}"
}
rt=$(newrt)
_L="source '$rt/launch-worker-iter001.zsh'"
_PRV="source '$rt/launch-worker-iter000.zsh'"
: > "$REC"; out=$(_drive "$rt" "$CMD" "$(_wrap_rows "$_PRV" 40)"$'\n'"$(_wrap_rows "user@host ~ % $_L" 40)")
_counts
{ [[ "$_p" == 1 && "$out" == "RC=0" ]]; } && ok "wrapped current line (40-col rows, no separator) above/below a previous echo -> verified ($out)" || no "wrapped intact line rejected: paste=$_p $out"
: > "$REC"; out=$(_drive "$rt" "$CMD" "$(_wrap_rows "$_PRV" 40)"$'\n'"$(_wrap_rows "user@host ~ % ${_L[2,-1]}" 40)")
_counts
{ [[ "$_p" == 3 && "$out" == "RC=1" ]]; } && ok "wrapped CORRUPTED current line under a previous echo -> RC=1 ($out)" || no "wrapped corrupted line accepted: paste=$_p $out"
: > "$REC"; out=$(_drive "$(newrt)" "$CMD" $'user@host ~ % @LINE@                               12:00:01')
_counts
{ [[ "$_p" == 1 && "$out" == "RC=0" ]]; } && ok "a right-prompt after the line on the same row does not break verification ($out)" || no "rprompt rejected: paste=$_p $out"

print "== S-6: launcher creation refuses FIFO / symlink / non-regular objects, never hangs =="
# Runs the function in a background subshell with a watchdog: prints RC=<n>, or HANG when it does not
# finish within 5s (the old noclobber redirect blocks forever opening a FIFO for writing). On HANG the
# blocked writer is released by opening the FIFO read-write ($2) so no process is left behind.
_bg() { # $1 = runtime dir, $2 = optional FIFO path to release on HANG
  local rt="$1" outf="$TMPD/bg.out" pid i
  rm -f "$outf"; : > "$REC"
  ( RUNTIME_DIR="$rt"; paste_to_pane() { print -r -- "PASTE $2" >> "$REC"; }
    tmux() { case "$1" in capture-pane) print -r -- "user@host ~ % source '$rt/launch-worker-iter001.zsh'";; send-keys) print -r -- "send-keys $*" >> "$REC";; esac; return 0; }
    _paste_cmd_echo_verified "%9" "$CMD"; print -r -- "RC=$?" > "$outf" ) >/dev/null 2>&1 &
  pid=$!
  for i in {1..50}; do kill -0 $pid 2>/dev/null || break; command sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null
    [[ -n "${2:-}" ]] && { exec 7<>"$2" 2>/dev/null; command sleep 0.3; exec 7>&-; }
    wait $pid 2>/dev/null; print HANG
  else wait $pid 2>/dev/null; cat "$outf" 2>/dev/null || print NORC; fi
}
LF1="launch-worker-iter001.zsh"
_no_paste() { ! grep -q '^PASTE' "$REC"; }

rt=$(newrt); mkfifo "$rt/$LF1"; ERRLOG="$TMPD/err1"; : > "$ERRLOG"
out=$(_bg "$rt" "$rt/$LF1")
check "FIFO at the launcher path: refused (rc 1), no hang" "RC=1" "$out"
_no_paste && ok "FIFO: nothing was pasted" || no "FIFO: a paste happened"
[[ -p "$rt/$LF1" ]] && ok "FIFO: the object at the path is untouched" || no "FIFO: replaced"
grep -qi 'regular' "$ERRLOG" && ok "FIFO: a log_error names the refusal" || no "FIFO: silent refusal (ERR=$(<"$ERRLOG"))"

rt=$(newrt); mkfifo "$rt/real-fifo"; ln -s "$rt/real-fifo" "$rt/$LF1"; : > "$ERRLOG"
out=$(_bg "$rt" "$rt/real-fifo")
check "symlink to a FIFO at the launcher path: refused (rc 1), no hang" "RC=1" "$out"
[[ -L "$rt/$LF1" && -p "$rt/real-fifo" ]] && ok "symlink->FIFO: both objects untouched" || no "symlink->FIFO: modified"

rt=$(newrt); print -r -- "ATTACKER-TARGET-ORIGINAL" > "$rt/target"; ln -s "$rt/target" "$rt/$LF1"; : > "$ERRLOG"
out=$(_bg "$rt")
check "symlink to a regular file at the launcher path: refused (rc 1)" "RC=1" "$out"
check "symlink target was NOT written through" "ATTACKER-TARGET-ORIGINAL" "$(<"$rt/target")"
_no_paste && ok "symlink: nothing was pasted" || no "symlink: a paste happened"

rt=$(newrt); ln -s "$rt/does-not-exist" "$rt/$LF1"; : > "$ERRLOG"
out=$(_bg "$rt")
check "dangling symlink at the launcher path: refused (rc 1)" "RC=1" "$out"
[[ ! -e "$rt/does-not-exist" ]] && ok "dangling symlink: the target was not created" || no "dangling symlink: target created"

rt=$(newrt); mkdir "$rt/$LF1"; : > "$ERRLOG"
out=$(_bg "$rt")
check "directory at the launcher path: refused (rc 1)" "RC=1" "$out"

# An existing REGULAR file is a previous attempt's launcher: never overwritten, the next -k name is used.
# (The fixed mock capture only echoes the -1 line, so the verification of the -2 line fails and the
# call returns 1 after its retries; the assertions are on the files.)
rt=$(newrt); print -r -- "previous attempt launcher" > "$rt/$LF1"; : > "$ERRLOG"
_bg "$rt" >/dev/null
[[ "$(<"$rt/$LF1")" == "previous attempt launcher" ]] && ok "an existing REGULAR launcher is never overwritten" || no "existing regular launcher overwritten"
[[ -f "$rt/launch-worker-iter001-2.zsh" && "$(_mode "$rt/launch-worker-iter001-2.zsh")" == 600 ]] && ok "next unique name used (-2), mode 0600" || no "no -2 launcher / wrong mode"
[[ "$(<"$rt/launch-worker-iter001-2.zsh")" == "$CMD" ]] && ok "the new launcher holds the exact command" || no "launcher content differs"

rt=$(newrt)
out=$(_bg "$rt")
check "fresh path: launch succeeds" "RC=0" "$out"
[[ "$(_mode "$rt/$LF1")" == 600 && -f "$rt/$LF1" && ! -L "$rt/$LF1" ]] && ok "fresh launcher: regular file, mode 0600, not a symlink" || no "fresh launcher wrong type/mode"
grep -q 'sysopen' "$RUN" && ok "source creates the launcher with zsh/system sysopen" || no "source does not use sysopen"

# R2-07 / S-8: the helper's header must not list paths that paste the full command unverified now that the 15-attempt
# restart in launch_worker_claude, launch_verifier_claude / launch_verifier_codex and restart_worker all go through it.
hdr=$(awk '/^_paste_cmd_echo_verified\(\) \{/ {exit} {print}' "$RUN" | tail -40)
[[ "$hdr" != *"still paste the"* && "$hdr" != *"unverified:"* ]] \
  && ok "S-8: the launcher comment no longer lists paths that paste the full command unverified" || no "S-8: the launcher comment still lists unverified full-command paths"
[[ "$hdr" != *"is NOT pasted. Real tmux"* ]] && ok "R2-07: the unqualified 'the command is NOT pasted' claim is gone" || no "R2-07: the unqualified claim is still there"
lwc=$(_extract_fn launch_worker_claude "$RUN"); lvc=$(_extract_fn launch_verifier_claude "$RUN"); lvx=$(_extract_fn launch_verifier_codex "$RUN"); rw=$(_extract_fn restart_worker "$RUN")
print -r -- "$lwc" | grep -q 'paste_to_pane "$pane_id" "$worker_launch"' && no "S-8: launch_worker_claude's restart path still pastes the full command" || ok "S-8: launch_worker_claude's restart path no longer pastes the full command"
print -r -- "$lvc" | grep -q 'paste_to_pane "$pane_id" "$verifier_launch"' && no "S-8: launch_verifier_claude still pastes the full command" || ok "S-8: launch_verifier_claude no longer pastes the full command"
print -r -- "$lvx" | grep -q 'paste_to_pane "$pane_id" "$verifier_launch"' && no "S-8: launch_verifier_codex still pastes the full command" || ok "S-8: launch_verifier_codex no longer pastes the full command"
print -r -- "$rw" | grep -qE 'safe_send_keys "\$pane_id" "\$\(build_claude_cmd[^)]*\)" worker-restart' && ok "S-8: restart_worker sends the launch through safe_send_keys with the worker-restart launch label" || no "S-8: restart_worker does not pass the worker-restart launch label"
for _f in lwc lvc lvx; do print -r -- "${(P)_f}" | grep -q '_paste_cmd_echo_verified' && ok "S-8: $_f goes through _paste_cmd_echo_verified" || no "S-8: $_f does not use _paste_cmd_echo_verified"; done

# R1-04: the launcher name must stay unique for MORE than 200 launches with one label in one iteration
# (the whole sequential final verify runs in a single ITERATION and every verifier launch uses label
# `verifier`); no linear probe from -2 each time, no cap.
rt=$(newrt); RUNTIME_DIR="$rt"; ERRLOG="$TMPD/r104.err"; : > "$ERRLOG"
sleep() { :; }
paste_to_pane() { _LASTP="$2"; }
tmux() { case "$1" in capture-pane) print -r -- "user@host ~ % $_LASTP";; esac; return 0; }
_bad=0; _t0=$SECONDS
for (( _n = 1; _n <= 260; _n++ )); do _paste_cmd_echo_verified "%9" "$CMD" "" verifier || (( _bad++ )); done
unfunction sleep paste_to_pane tmux
_nfiles=$(ls "$rt" | wc -l | tr -d ' ')
{ (( _bad == 0 && _nfiles == 260 )); } \
  && ok "R1-04: 260 launches with one label in one iteration all succeed, 260 distinct launchers ($(( SECONDS - _t0 ))s)" \
  || no "R1-04: failures=$_bad launchers=$_nfiles err=$(tail -1 "$ERRLOG")"
[[ -f "$rt/launch-verifier-iter001.zsh" && "$(_mode "$rt/launch-verifier-iter001.zsh")" == 600 ]] \
  && ok "R1-04: the first launcher keeps the plain launch-<label>-iterNNN.zsh name, mode 0600" || no "R1-04: first launcher name/mode changed"

# A-C2-03 / R2-04: a launcher that was CREATED but could not be WRITTEN (ulimit -f 0, ENOSPC, EIO) is not a
# collision: no endless loop of empty launchers, the half-made file is removed, rc 1 with a loud error.
_extract_fn _paste_cmd_echo_verified "$RUN" > "$TMPD/fn.zsh"
rt=$(newrt)
# the child reports on stdout only: under ulimit -f 0 it cannot write any regular file itself
cat > "$TMPD/wfail.zsh" <<WF
log(){ :; }; log_debug(){ :; }; log_error(){ print -r -- "ERR \$*"; }
_wait_pane_shell_ready(){ return 0; }
paste_to_pane(){ print -r -- "PASTE \$2"; }
tmux(){ return 0; }
sleep(){ :; }
source "$TMPD/fn.zsh"
RUNTIME_DIR="$rt"; ITERATION=1
trap "" XFSZ
ulimit -f 0
_paste_cmd_echo_verified "%9" "$CMD" "" verifier; print "RC=\$?"
WF
wout=$(perl -e 'alarm 20; exec @ARGV' /bin/zsh -f "$TMPD/wfail.zsh" 2>&1); _wrc=$?
_left=$(ls "$rt" | wc -l | tr -d ' ')
{ [[ "$wout" == *"RC=1"* ]] && (( _wrc == 0 )); } \
  && ok "R2-04: write failure under ulimit -f 0 -> rc 1 promptly (no endless loop)" \
  || no "R2-04: out='${wout:0:200}' shell-rc=$_wrc (142 = killed by the 20 s alarm)"
{ (( _left == 0 )); } && ok "R2-04: no leftover empty launcher files" || no "R2-04: $_left leftover launcher file(s)"
[[ "$wout" != *PASTE* ]] && ok "R2-04: nothing pasted after the failed launcher write" || no "R2-04: pasted after a failed write"
[[ "$wout" == *"ERR   launch launcher: could not write"* ]] && ok "R2-04: loud log_error" || no "R2-04: no log_error: ${wout:0:200}"

print ""
print "f1_launcher_and_echo: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
