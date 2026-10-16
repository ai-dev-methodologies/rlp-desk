#!/bin/zsh
# ============================================================================
# F6 / R3-04: _paste_cmd_echo_verified must require the ENTIRE `source '<launcher>'` line to
# END on the bottom-most captured row (the `_ab` clause: a window is accepted only when the
# rows above its last row do not already contain the line). An intact echo with ANY later
# non-blank row below it (command output, a banner, a new prompt) is not the live input
# line: it must NOT verify. No other test pins this clause; a mutant that drops it passes
# tests/test_f1_launcher_and_echo.sh. Point RLP_TEST_RUN_SCRIPT at a mutated copy to prove
# this test kills it.
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
log(){ :; }; log_debug(){ :; }; log_error(){ :; }
ITERATION=1

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}
eval "$(_extract_fn _paste_cmd_echo_verified "$RUN")"
[[ "$(whence -w _paste_cmd_echo_verified 2>/dev/null)" == *function* ]] \
  && ok "extracted _paste_cmd_echo_verified from $RUN" || { no "could not extract _paste_cmd_echo_verified"; exit 1; }
_wait_pane_shell_ready() { return 0; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/f6-bottom-row.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
REC="$TMPD/rec"; CNT="$TMPD/cnt"
CMD='/opt/homebrew/bin/claude --model x --dangerously-skip-permissions'

# $1 = capture-pane output (every attempt sees it); @LINE@ = the intact short line.
_drive() {
  local cap="$1" rt; rt=$(mktemp -d "$TMPD/rt.XXXXXX")
  RUNTIME_DIR="$rt"
  local _line="source '$RUNTIME_DIR/launch-worker-iter001.zsh'"
  cap="${cap//@LINE@/$_line}"
  : > "$REC"
  paste_to_pane() { print -r -- "PASTE $2" >> "$REC"; }
  tmux() { case "$1" in capture-pane) print -r -- "$cap";; send-keys) print -r -- "send-keys $*" >> "$REC";; esac; return 0; }
  _paste_cmd_echo_verified "%9" "$CMD"; local rc=$?
  unfunction paste_to_pane tmux
  print "RC=$rc"
}
_pastes() { grep -c '^PASTE' "$REC"; }

print "== R3-04: the intact line is NOT on the bottom captured row -> must not verify =="
out=$(_drive $'user@host ~ % @LINE@\nbuild output: 3 files changed')
{ [[ "$out" == "RC=1" && "$(_pastes)" == 3 ]]; } \
  && ok "intact line + one later output row -> 3 attempts, RC=1 ($out, pastes=$(_pastes))" \
  || no "intact line above one later row verified or mis-retried: $out pastes=$(_pastes)"
out=$(_drive $'user@host ~ % @LINE@\nline one of output\nline two of output\nuser@host ~ %')
{ [[ "$out" == "RC=1" && "$(_pastes)" == 3 ]]; } \
  && ok "intact line + three later rows (incl. a fresh prompt) -> 3 attempts, RC=1 ($out, pastes=$(_pastes))" \
  || no "intact line above several later rows verified or mis-retried: $out pastes=$(_pastes)"
# the line wrapped over 40-col rows (real tmux leaves ZLE rows un-joined), output below it
_wrap_rows() { # $1 = full text, $2 = width -> rows joined by newlines (no separator char lost)
  local s="$1" w="$2" out="" i=1
  while (( i <= ${#s} )); do out+="${s[i,i+w-1]}"$'\n'; i=$(( i + w )); done
  print -r -- "${out%$'\n'}"
}
_wrapped_line() { print -r -- "$(_wrap_rows "user@host ~ % source '$TMPD/rt.AAAAAA/launch-worker-iter001.zsh'" 40)"; }
_drive_wrapped() { # $1 = text after the wrapped line (may be empty); runtime dir fixed so the rows match
  local cap rt="$TMPD/rt.AAAAAA"; mkdir -p "$rt"
  cap="$(_wrapped_line)"; [[ -n "$1" ]] && cap+=$'\n'"$1"
  RUNTIME_DIR="$rt"; : > "$REC"; rm -f "$rt"/launch-*(N)
  paste_to_pane() { print -r -- "PASTE $2" >> "$REC"; }
  tmux() { case "$1" in capture-pane) print -r -- "$cap";; send-keys) print -r -- "send-keys $*" >> "$REC";; esac; return 0; }
  _paste_cmd_echo_verified "%9" "$CMD"; local rc=$?
  unfunction paste_to_pane tmux
  print "RC=$rc"
}
out=$(_drive_wrapped "later row of output")
{ [[ "$out" == "RC=1" && "$(_pastes)" == 3 ]]; } \
  && ok "wrapped intact line (40-col rows) + one later row -> 3 attempts, RC=1 ($out, pastes=$(_pastes))" \
  || no "wrapped intact line above a later row verified: $out pastes=$(_pastes)"

print "== controls: the line DOES end on the bottom row -> verifies on the first paste =="
out=$(_drive $'older output\nuser@host ~ % @LINE@')
{ [[ "$out" == "RC=0" && "$(_pastes)" == 1 ]]; } \
  && ok "intact line on the bottom row -> RC=0, one paste ($out)" || no "intact bottom line rejected: $out pastes=$(_pastes)"
out=$(_drive $'user@host ~ % @LINE@                               12:00:01')
{ [[ "$out" == "RC=0" && "$(_pastes)" == 1 ]]; } \
  && ok "intact line + right prompt on the same bottom row -> RC=0 ($out)" || no "right-prompt row rejected: $out pastes=$(_pastes)"
out=$(_drive_wrapped "")
{ [[ "$out" == "RC=0" && "$(_pastes)" == 1 ]]; } \
  && ok "wrapped intact line ending on the bottom row -> RC=0, one paste ($out)" || no "wrapped bottom line rejected: $out pastes=$(_pastes)"

print ""
print "f6_echo_bottom_row: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
