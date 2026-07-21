#!/usr/bin/env zsh
# ④ request-j (v0.22.18) — launch-command echo verify before Enter.
#
# An interactive rc prompt (oh-my-zsh "[Y/n]" update prompt) can eat the FIRST
# pasted character, turning "/opt/homebrew/bin/codex …" into "opt/homebrew/bin/codex
# …" (leading '/' gone) so the CLI never starts. _paste_cmd_echo_verified pastes,
# then requires the command's LEADING 24-char prefix (which contains the vulnerable
# first char) to appear intact via a glob-safe grep -F, BEFORE the caller presses
# Enter. On mismatch: C-u (clear line), re-paste, up to 3 attempts; all exhausted →
# return 1 (launch-failure path).
#
# Tests: clean echo → single paste, no C-u; swallowed-first-char → re-paste (C-u)
# then success; persistent swallow → return 1 after 3 attempts; bracketed-model-id
# prefix matches literally (grep -F, not glob).
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
log(){ :; }; log_error(){ :; }; log_debug(){ :; }
ITERATION=1

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}
eval "$(_extract_fn _paste_cmd_echo_verified "$RUN")"
[[ "$(whence -w _paste_cmd_echo_verified 2>/dev/null)" == *function* ]] \
  && ok "extracted _paste_cmd_echo_verified" || no "could not extract _paste_cmd_echo_verified"

TMPDIR_T=$(mktemp -d)
REC="$TMPDIR_T/rec"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Driver: $1 cmd, then a sequence of capture-pane outputs (one per attempt; the
# LAST is reused if attempts exceed the list). The helper pipes capture-pane through
# `tail`, which runs the tmux stub in a SUBSHELL — so the per-attempt counter is
# tracked in a file (in-memory increments would not survive the subshell).
CNT="$TMPDIR_T/cnt"
_drive() {
  local cmd="$1"; shift
  local -a CAPS=("$@")
  print -r -- 0 > "$CNT"
  paste_to_pane() { print -r -- "PASTE" >> "$REC"; }
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

CMD='/opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="high"'
INTACT='user@host ~ % /opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="high"'
SWALLOWED='user@host ~ % opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="high"'

# 1) clean echo → 1 paste, 0 C-u, RC=0
: > "$REC"; out=$(_drive "$CMD" "$INTACT")
_p=$(grep -c 'PASTE' "$REC"); _cu=$(grep -c 'send-keys.*C-u' "$REC")
{ [[ "$_p" == 1 && "$_cu" == 0 && "$out" == "RC=0" ]] } \
  && ok "clean echo → single paste, no C-u, RC=0 ($out)" || no "clean echo wrong (paste=$_p cu=$_cu $out)"

# 2) swallowed first char then intact → re-paste (C-u), RC=0
: > "$REC"; out=$(_drive "$CMD" "$SWALLOWED" "$INTACT")
_p=$(grep -c 'PASTE' "$REC"); _cu=$(grep -c 'send-keys.*C-u' "$REC")
{ [[ "$_p" == 2 && "$_cu" == 1 && "$out" == "RC=0" ]] } \
  && ok "swallowed first char → C-u + re-paste, then RC=0 ($out)" || no "swallow-recover wrong (paste=$_p cu=$_cu $out)"

# 3) persistent swallow → 3 attempts then RC=1
: > "$REC"; out=$(_drive "$CMD" "$SWALLOWED")
_p=$(grep -c 'PASTE' "$REC"); _cu=$(grep -c 'send-keys.*C-u' "$REC")
{ [[ "$_p" == 3 && "$_cu" == 3 && "$out" == "RC=1" ]] } \
  && ok "persistent swallow → 3 paste attempts, RC=1 (launch failure) ($out)" || no "persistent swallow wrong (paste=$_p cu=$_cu $out)"

# 4) bracketed model id in the prefix matches LITERALLY (grep -F, not glob).
#    A pattern-based match would treat '[1m]' as a char class and FAIL on the
#    literal pane text — proving the fixed-string match.
BCMD='[1m]/opt/bin/tool run --now here-we-go extra'
BINTACT='shell$ [1m]/opt/bin/tool run --now here-we-go extra'
: > "$REC"; out=$(_drive "$BCMD" "$BINTACT")
_p=$(grep -c 'PASTE' "$REC")
{ [[ "$_p" == 1 && "$out" == "RC=0" ]] } \
  && ok "bracketed-model-id prefix matches literally (grep -F, glob-safe) ($out)" || no "bracket prefix not matched literally (paste=$_p $out)"

# --- structural: both launch functions call the helper before Enter ------------
_lwc=$(_extract_fn launch_worker_codex "$RUN")
_lwcl=$(_extract_fn launch_worker_claude "$RUN")
print -r -- "$_lwc" | grep -q '_paste_cmd_echo_verified' \
  && ok "structural: launch_worker_codex uses the echo-verify helper" || no "launch_worker_codex not wired"
print -r -- "$_lwcl" | grep -q '_paste_cmd_echo_verified' \
  && ok "structural: launch_worker_claude uses the echo-verify helper" || no "launch_worker_claude not wired"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
