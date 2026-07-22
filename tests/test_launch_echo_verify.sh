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
# The helper now calls _wait_pane_shell_ready first — stub it no-op for the echo drives
# (it consumes no capture counter and adds no sleep); the REAL one is tested below.
_wait_pane_shell_ready() { return 0; }

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

# 5) request-k ① REGRESSION: fresh pane draws the echo at the TOP with trailing blank
#    rows. A raw `tail -10` would see only blanks → _tail="" → false mismatch → launch
#    failure (the shipped-0.22.18 bug). The blank-line filter must recover the echo.
#    Fixture: intact echo on row 1 + 14 trailing blank rows (models a 34-row pane).
REGR=$'user@host ~ % /opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="high"\n\n\n\n\n\n\n\n\n\n\n\n\n\n'
: > "$REC"; out=$(_drive "$CMD" "$REGR")
_p=$(grep -c 'PASTE' "$REC"); _cu=$(grep -c 'send-keys.*C-u' "$REC")
{ [[ "$_p" == 1 && "$_cu" == 0 && "$out" == "RC=0" ]] } \
  && ok "REGRESSION(k①): echo-at-top + 10+ trailing blank rows → verified on attempt 1 ($out)" \
  || no "blank-tail regression NOT fixed (paste=$_p cu=$_cu $out) — raw tail -10 saw only blanks"
# guard the fix is present in source (blank-line filter before tail)
grep -q "grep -v '\^\[\[:space:\]\]\*\$' | tail -10" "$RUN" \
  && ok "REGRESSION(k①): source strips blank lines before tail -10" || no "blank-line filter missing from source"

# --- request-k/-m companion: _wait_pane_shell_ready (real) --------------------
# request-m ①: readiness is now PROCESS-based (#{pane_current_command} ∈ zsh/bash)
# AND content-based (non-blank). The tmux stubs must answer BOTH display-message
# and capture-pane.
eval "$(_extract_fn _wait_pane_shell_ready "$RUN")"
[[ "$(whence -w _wait_pane_shell_ready 2>/dev/null)" == *function* ]] \
  && ok "extracted real _wait_pane_shell_ready" || no "could not extract _wait_pane_shell_ready"
# ready: shell owns the pane (current_command=zsh) AND non-blank text → rc=0 fast.
_ready_out=$( RLP_SHELL_READY_TIMEOUT_S=2
  tmux() { case "$1" in
    display-message) print -r -- "zsh";;
    capture-pane) print -r -- "user@host ~ %";; esac; return 0; }
  _wait_pane_shell_ready "%9"; print "rc=$?"; unfunction tmux )
[[ "$_ready_out" == "rc=0" ]] \
  && ok "shell-ready: shell current_command + non-blank text → ready (rc=0)" || no "shell-ready did not detect ready pane ($_ready_out)"
# request-m ① REUSED-PANE: the pane is full of the previous process's output
# (capture-pane always non-blank), but the previous process (codex/node) still
# owns the foreground for a few ticks before the shell reclaims it. The wait MUST
# HOLD until current_command becomes zsh — NOT return early on the stale content.
_DMCNT="$TMPDIR_T/dmcnt"; print -r -- 0 > "$_DMCNT"
_reuse_out=$( RLP_SHELL_READY_TIMEOUT_S=5
  tmux() { case "$1" in
    display-message)
      local n; n=$(cat "$_DMCNT" 2>/dev/null || print 0); n=$((n + 1)); print -r -- "$n" > "$_DMCNT"
      # first 3 polls: previous worker process still owns the pane; then shell.
      (( n <= 3 )) && print -r -- "node" || print -r -- "zsh";;
    capture-pane) print -r -- "STALE OUTPUT from previous run";;   # always non-blank
    esac; return 0; }
  _wait_pane_shell_ready "%9"; print "rc=$?"; unfunction tmux )
_dmpolls=$(cat "$_DMCNT")
{ [[ "$_reuse_out" == "rc=0" ]] && (( _dmpolls >= 4 )) } \
  && ok "shell-ready(m①): reused pane w/ stale output HOLDS until shell reclaims it (rc=0 after $_dmpolls polls, no premature ready)" \
  || no "shell-ready(m①): reused-pane hold wrong (out=$_reuse_out polls=$_dmpolls)"
# not-ready: process never returns to the shell → times out, FAILS OPEN (rc=1).
_to_out=$( RLP_SHELL_READY_TIMEOUT_S=1
  tmux() { case "$1" in
    display-message) print -r -- "codex";;                        # never the shell
    capture-pane) print -r -- "busy output";; esac; return 0; }
  _t0=$(date +%s); _wait_pane_shell_ready "%9"; _rc=$?; _t1=$(date +%s)
  unfunction tmux; print "rc=$_rc dt=$(( _t1 - _t0 ))" )
{ [[ "$_to_out" == "rc=1"* ]] && [[ "${_to_out##*dt=}" -le 3 ]] } \
  && ok "shell-ready: non-shell current_command → fail-open rc=1, bounded by RLP_SHELL_READY_TIMEOUT_S ($_to_out)" \
  || no "shell-ready timeout not bounded/fail-open ($_to_out)"
# structural: the helper is called before the first paste, and is env-tunable.
_pv=$(_extract_fn _paste_cmd_echo_verified "$RUN")
print -r -- "$_pv" | grep -q '_wait_pane_shell_ready' \
  && ok "structural: echo-verify calls _wait_pane_shell_ready before pasting" || no "shell-ready wait not wired into echo-verify"
grep -q 'RLP_SHELL_READY_TIMEOUT_S' "$RUN" \
  && ok "structural: shell-ready wait is env-tunable (RLP_SHELL_READY_TIMEOUT_S)" || no "shell-ready timeout not env-tunable"
# request-m ①: process-based readiness predicate present in source.
grep -q "pane_current_command" "$RUN" \
  && ok "structural(m①): readiness predicate uses #{pane_current_command}" || no "process-based readiness missing from source"
# request-m ①: retry interval raised 0.15→0.8s (3 retries no longer burn inside 1s).
print -r -- "$_pv" | grep -qE 'sleep 0\.8' \
  && ok "structural(m①): paste retry interval is 0.8s (was 0.15s)" || no "retry interval not raised to 0.8s"

# --- request-m ① (HIGH): the DEFAULT timeout knob is 8, not dead 6 --------------
# Every case above passes RLP_SHELL_READY_TIMEOUT_S explicitly; this exercises the
# UNSET default the way production does — sourcing the canonical knob block. Guards
# the HIGH: the 8s raise was dead code while the knob at the top still pinned 6.
eval "$(_extract_fn _validate_int_knob "$RUN")"
_knob_lines=$(grep -E 'RLP_SHELL_READY_TIMEOUT_S="\$\{RLP_SHELL_READY_TIMEOUT_S:-[0-9]+\}"|_validate_int_knob RLP_SHELL_READY_TIMEOUT_S' "$RUN")
_def_to=$(
  unset RLP_SHELL_READY_TIMEOUT_S
  eval "$_knob_lines"
  print -r -- "$RLP_SHELL_READY_TIMEOUT_S" )
[[ "$_def_to" == "8" ]] \
  && ok "request-m①(HIGH): unset RLP_SHELL_READY_TIMEOUT_S → canonical knob yields 8 (not dead 6)" \
  || no "default timeout is $_def_to, expected 8 (dead-code raise regression)"
# structural: no stale 6-default for this knob remains anywhere in source.
if grep -qE 'RLP_SHELL_READY_TIMEOUT_S:-6|_validate_int_knob RLP_SHELL_READY_TIMEOUT_S 6' "$RUN"; then
  no "request-m①(HIGH): a stale ':-6' / 'knob 6' default for RLP_SHELL_READY_TIMEOUT_S still present"
else
  ok "request-m①(HIGH): no stale 6-default remains for RLP_SHELL_READY_TIMEOUT_S"
fi

# --- request-m ① (MEDIUM): codex launch passes a zsh-only accept-set -----------
_lwc_src=$(_extract_fn launch_worker_codex "$RUN")
print -r -- "$_lwc_src" | grep -qE '_paste_cmd_echo_verified "\$pane_id" "\$worker_launch" zsh' \
  && ok "request-m①(MED): codex worker launch passes zsh-only accept (excludes the bash trigger)" \
  || no "codex launch does not pass a zsh-only accept-set"
# claude keeps the default (no explicit accept arg → zsh|bash).
_lwcl_src=$(_extract_fn launch_worker_claude "$RUN")
print -r -- "$_lwcl_src" | grep -qE '_paste_cmd_echo_verified "\$pane_id" "\$worker_launch"( zsh)?; then' \
  && print -r -- "$_lwcl_src" | grep -qvE '_paste_cmd_echo_verified "\$pane_id" "\$worker_launch" zsh' \
  && ok "request-m①(MED): claude worker launch keeps the default accept-set (zsh|bash)" \
  || no "claude launch accept-set wrong"
# behavioral: with accept=zsh, a pane whose current_command is `bash` is NOT ready
# (the codex trigger case); with the default zsh|bash it IS ready.
_zex=$( RLP_SHELL_READY_TIMEOUT_S=1
  tmux() { case "$1" in display-message) print -r -- "bash";; capture-pane) print -r -- "x";; esac; return 0; }
  _wait_pane_shell_ready "%9" "zsh"; print "rc=$?"; unfunction tmux )
[[ "$_zex" == "rc=1" ]] \
  && ok "request-m①(MED): accept=zsh HOLDS on a bash current_command (codex trigger not misread as ready)" \
  || no "accept=zsh wrongly accepted bash ($_zex)"
_bok=$( RLP_SHELL_READY_TIMEOUT_S=2
  tmux() { case "$1" in display-message) print -r -- "bash";; capture-pane) print -r -- "x";; esac; return 0; }
  _wait_pane_shell_ready "%9"; print "rc=$?"; unfunction tmux )
[[ "$_bok" == "rc=0" ]] \
  && ok "request-m①(MED): default accept-set (zsh|bash) accepts bash (claude idle-shell case)" \
  || no "default accept-set rejected bash ($_bok)"

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
