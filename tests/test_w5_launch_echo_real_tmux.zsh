#!/usr/bin/env zsh
# W5 — launch-command echo verify on REAL tmux (isolated -L socket, `zsh -f` pane).
#
# Background (r19-trust-echo.md Part 2): _paste_cmd_echo_verified used to paste the whole
# ~350-460 char worker launch command into the pane's interactive zsh and verify the echo
# by reading the screen. Real tmux does NOT soft-wrap-join ZLE-drawn rows (so `capture-pane
# -J` cannot rebuild the line), hence on narrow/short panes the check failed:
#   (a) rows needed > the tail window (tail -10)  -> prefix row cut off  (40x24)
#   (b) rows needed > pane height                 -> ZLE truncates the line, nothing
#       can recover it (40x8).
# W5 design: write the command to a 0600 per-launch launcher file and paste the SHORT line
# `source '<launcher>'`; the echo check runs on that short line, so geometry stops mattering.
#
# This test drives the REAL paste_to_pane / _wait_pane_shell_ready / _paste_cmd_echo_verified
# (extracted from run_ralph_desk.zsh) against a real tmux pane. The "launch command" is a
# ~460 char fake whose execution is observable (writes a marker file with a known payload;
# no claude/codex is involved). Assertions per geometry:
#   E  echo-verify returns 0
#   M  the marker file holds the exact payload (the full command ran intact)
#   L  exactly one launcher file exists, mode 0600
#   B  the launcher bytes are the exact command (+ one trailing newline)
# Part 1b repeats the matrix at narrow widths with a ~37-char shell prompt (prompt+prefix straddle a row).
# Part 2 checks a swallowed first character on the short line is still detected (real tmux:
# the pane's shell is a stand-in for an rc `[Y/n]` prompt that eats the first typed key).
#
# SKIPs (exit 0) when tmux is not installed. Never touches the default tmux server: every
# tmux call goes through the `tmux` wrapper below, pinned to a private -L socket.
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_W5_RUN:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # RLP_W5_RUN: point at another copy (e.g. git show HEAD:...) to reproduce RED
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found"; exit 1; }

if ! command -v tmux >/dev/null 2>&1; then
  print "SKIP: tmux is not installed — the W5 real-tmux echo test needs a real tmux; nothing was run (exit 0)"
  exit 0
fi

PASS=0; FAIL=0; E_FAIL=0; M_FAIL=0; L_FAIL=0; B_FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/rlpw5.XXXXXX") || exit 1
SOCK="rlpw5-$$"
LOGF="$TMPD/leader.log"; : > "$LOGF"
log(){ print -r -- "$*" >> "$LOGF"; }
log_error(){ print -r -- "ERROR $*" >> "$LOGF"; }
log_debug(){ print -r -- "DEBUG $*" >> "$LOGF"; }
# Every tmux call (ours and the extracted functions') is pinned to the private socket.
tmux() { command tmux -L "$SOCK" "$@"; }
_cleanup() {
  command tmux -L "$SOCK" kill-server >/dev/null 2>&1
  [[ -n "${SOCKPATH:-}" && "${SOCKPATH:t}" == "$SOCK" ]] && rm -f "$SOCKPATH"   # kill-server leaves the (dead) socket file behind
  rm -rf "$TMPD"
}
trap _cleanup EXIT

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}
for _f in paste_to_pane _wait_pane_shell_ready _paste_cmd_echo_verified; do
  eval "$(_extract_fn $_f "$RUN")"
  [[ "$(whence -w $_f 2>/dev/null)" == *function* ]] || { print -u2 "FAIL: could not extract $_f"; exit 1; }
done
ok "extracted the real paste_to_pane / _wait_pane_shell_ready / _paste_cmd_echo_verified"

_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# Realistic runtime dir depth (the launcher path length is what the pasted line carries).
ITERATION=7
RUNTIME_DIR="$TMPD/project/.rlp-desk/logs/some-campaign-slug/runtime"
LOGS_DIR="${RUNTIME_DIR:h}"
mkdir -p "$RUNTIME_DIR"

# ~460-char fake launch command. Runs in the pane's interactive zsh; writes PAYLOAD to MARK.
_make_cmd() {   # $1 payload  $2 marker path  -> prints the command
  local head="W5_PAD='" tail="'; print -r -- '$1' > '$2'"
  local pad_len=$(( 460 - ${#head} - ${#tail} ))
  local pad=""
  while (( ${#pad} < pad_len )); do pad+="--flag-$((RANDOM % 900 + 100))=value "; done
  print -r -- "${head}${pad[1,pad_len]}${tail}"
}

_start_pane() {   # $1 W  $2 H  $3 shell command for the pane
  command tmux -L "$SOCK" kill-server >/dev/null 2>&1
  command tmux -L "$SOCK" -f /dev/null new-session -d -s w5 -x "$1" -y "$2" "$3" || return 1
  PANE=$(tmux list-panes -t w5 -F '#{pane_id}' | head -1)
  SOCKPATH=$(tmux display-message -p -t w5 "#{socket_path}" 2>/dev/null)
}

_wait_file() {   # $1 file, up to ~8s
  local i
  for i in {1..40}; do [[ -s "$1" ]] && return 0; sleep 0.2; done
  return 1
}

# One geometry: $1 WxH, $2 pane shell command, $3 table tag. Appends a row to TABLE.
_geo_case() {
  local _g="$1" _shell="$2" _tag="$3" W H rc m="-" l="-" mode="-" b="-" MARK PAYLOAD CMD _geo
  W=${_g%x*}; H=${_g#*x}; unset _LAUNCH_ECHO_LINE
  rm -f "$RUNTIME_DIR"/launch-*(N)
  : > "$LOGF"
  _start_pane "$W" "$H" "$_shell" || { no "$_tag $_g: could not start the tmux pane"; return; }
  _geo=$(tmux display-message -p -t "$PANE" '#{pane_width}x#{pane_height}')
  [[ "$_geo" == "$_g" ]] || { no "$_tag $_g: pane geometry is $_geo, not $_g"; return; }

  MARK="$TMPD/marker-$_tag-$_g"; PAYLOAD="W5-PAYLOAD-$_tag-$_g-$$"
  CMD=$(_make_cmd "$PAYLOAD" "$MARK"); rm -f "$MARK"
  RLP_SHELL_READY_TIMEOUT_S=8
  _paste_cmd_echo_verified "$PANE" "$CMD" "" worker; rc=$?
  if (( rc == 0 )); then
    tmux send-keys -t "$PANE" C-m
    _wait_file "$MARK"
  fi
  # E
  if (( rc == 0 )); then ok "$_tag $_g E: echo-verify rc=0"; else no "$_tag $_g E: echo-verify rc=$rc (cmd len ${#CMD})"; E_FAIL=$((E_FAIL+1)); fi
  # M
  if [[ -s "$MARK" && "$(<"$MARK")" == "$PAYLOAD" ]]; then m=ok; ok "$_tag $_g M: marker holds the exact payload (full command ran intact)"
  else m=FAIL; no "$_tag $_g M: marker missing/wrong (got '$( [[ -f $MARK ]] && <"$MARK" )')"; M_FAIL=$((M_FAIL+1)); fi
  # L
  typeset -a LF; LF=("$RUNTIME_DIR"/launch-*(N))
  if (( ${#LF} == 1 )) && [[ "$(_mode "${LF[1]}")" == 600 ]]; then l=ok; mode=600; ok "$_tag $_g L: exactly one launcher, mode 0600 (${LF[1]:t})"
  else l=FAIL; mode="$( (( ${#LF} )) && _mode "${LF[1]}")"; no "$_tag $_g L: launcher files=${#LF} mode=${mode:-none}"; L_FAIL=$((L_FAIL+1)); fi
  # B
  if (( ${#LF} >= 1 )) && [[ "$(<"${LF[1]}")" == "$CMD" ]] && (( $(wc -c < "${LF[1]}") == ${#CMD} + 1 )); then b=ok; ok "$_tag $_g B: launcher bytes == exact command (+ newline)"
  else b=FAIL; no "$_tag $_g B: launcher content differs from the command"; B_FAIL=$((B_FAIL+1)); fi
  TABLE+=("$_tag $_g|cmd_len=${#CMD}|pasted=${${_LAUNCH_ECHO_LINE:+${#_LAUNCH_ECHO_LINE}}:-full-cmd}|E:rc=$rc|M:$m|L:$l(mode=$mode)|B:$b")
  tmux send-keys -t "$PANE" 'exit' C-m 2>/dev/null
  sleep 0.2
}

print "== Part 1: ~460-char launch command across pane geometries (real tmux, zsh -f, short prompt) =="
typeset -a GEOS=(80x24 80x10 120x30 40x24 40x8 220x60)
typeset -a TABLE
for _g in "${GEOS[@]}"; do _geo_case "$_g" 'zsh -f' short; done

# A long shell prompt (~37 visible chars, e.g. cwd + git branch) at a narrow width pushes the
# 24-char verified prefix across a ZLE row boundary; the echo check must still find it.
mkdir -p "$TMPD/zd"; print -r -- "PROMPT='~/dev/own/some-project-dir (main) ❯ '" > "$TMPD/zd/.zshrc"
print ""
print "== Part 1b: long prompt (~37 chars) at narrow widths (real tmux, interactive zsh) =="
for _g in 40x24 40x8 60x24; do _geo_case "$_g" "env ZDOTDIR=$TMPD/zd zsh -i" longprompt; done

print ""
print "GEOMETRY TABLE (real tmux $(command tmux -V | head -1))"
for _r in "${TABLE[@]}"; do print "  $_r"; done
print "assertion-class failures: E(echo rc)=$E_FAIL M(marker)=$M_FAIL L(launcher file)=$L_FAIL B(launcher bytes)=$B_FAIL"


# ---------------------------------------------------------------------------------------
print ""
print "== Part 2: a swallowed first character on the short line is still detected (real tmux) =="
# The pane's shell is a stand-in for an rc `[Y/n]` update prompt: it prints a question and eats
# the FIRST typed key, then hands over to a plain interactive zsh (the rest of the paste
# arrives as typeahead -> echoed line starts with the second character). The first paste
# must therefore mismatch, be cleared (C-u) and re-pasted; the second paste is intact.
rm -f "$RUNTIME_DIR"/launch-*(N); : > "$LOGF"
_start_pane 120 30 "zsh -f -c 'print -n \"Update zsh? [Y/n] \"; read -k1 -s _x; exec zsh -f'" || no "swallow: pane start failed"
MARK="$TMPD/marker-swallow"; PAYLOAD="W5-SWALLOW-$$"; rm -f "$MARK"
CMD=$(_make_cmd "$PAYLOAD" "$MARK")
RLP_SHELL_READY_TIMEOUT_S=8
_paste_cmd_echo_verified "$PANE" "$CMD" "" worker; rc=$?
if (( rc == 0 )); then tmux send-keys -t "$PANE" C-m; _wait_file "$MARK"; fi
_nmis=$(grep -c 'launch paste echo mismatch' "$LOGF")
if (( rc == 0 && _nmis >= 1 )) && grep -q 'echoed intact after [2-3] paste attempt' "$LOGF"; then
  ok "swallow: first-char swallow detected on the short line (mismatches=$_nmis), re-pasted, then rc=0"
else
  no "swallow: expected >=1 mismatch then rc=0 (rc=$rc mismatches=$_nmis)"
fi
if [[ -s "$MARK" && "$(<"$MARK")" == "$PAYLOAD" ]]; then ok "swallow: the command that finally ran is intact (marker payload exact)"
else no "swallow: marker missing/wrong after the recovered paste"; fi
tmux send-keys -t "$PANE" 'exit' C-m 2>/dev/null; sleep 0.2

# Persistent swallow: the shell never echoes what is typed (every paste lost) -> 3 attempts, rc=1,
# the Enter must NOT be sent by the caller (we do not send it here either); no marker.
rm -f "$RUNTIME_DIR"/launch-*(N); : > "$LOGF"
_start_pane 120 30 "zsh -f -c 'print -n \"Update zsh? [Y/n] \"; while read -k1 -s _x; do :; done'" || no "swallow(persistent): pane start failed"
MARK="$TMPD/marker-persist"; rm -f "$MARK"
CMD=$(_make_cmd "W5-PERSIST-$$" "$MARK")
RLP_SHELL_READY_TIMEOUT_S=8
_paste_cmd_echo_verified "$PANE" "$CMD" "" worker; rc=$?
if (( rc == 1 )) && [[ ! -e "$MARK" ]]; then ok "swallow(persistent): every paste lost -> rc=1, command never ran"
else no "swallow(persistent): expected rc=1 and no marker (rc=$rc)"; fi
tmux send-keys -t "$PANE" C-c 2>/dev/null

# ---------------------------------------------------------------------------------------
print ""
print "== Part 3 (R2-F / S-7): an intact PREVIOUS launcher echo above a swallowed CURRENT paste (real tmux) =="
# The pane already shows the echo of an earlier launch (`source '<runtime>/launch-worker-iter006.zsh'`, which
# shares the first 24 characters with the current line) and then an rc `[Y/n]` prompt that eats the first
# typed key. The old prefix-only check was satisfied by the PREVIOUS echo, pressed Enter on the corrupted
# `ource ...` line, and the launch never ran. The current input row must hold the ENTIRE current line
# (unique filename included): the first paste must mismatch, be cleared (C-u), re-pasted intact, and run.
rm -f "$RUNTIME_DIR"/launch-*(N); : > "$LOGF"
PREV_LINE="source '$RUNTIME_DIR/launch-worker-iter006.zsh'"
cat > "$TMPD/swallow-prev.zsh" <<SWEOF
print -r -- "kyjin@host ~ % $PREV_LINE"
print -r -- "(previous launch output)"
print -n "Update zsh? [Y/n] "
read -k1 -s _x
exec zsh -f
SWEOF
_start_pane 120 30 "zsh -f $TMPD/swallow-prev.zsh" || no "prev-echo: pane start failed"
MARK="$TMPD/marker-prevecho"; PAYLOAD="W5-PREVECHO-$$"; rm -f "$MARK"
CMD=$(_make_cmd "$PAYLOAD" "$MARK")
RLP_SHELL_READY_TIMEOUT_S=8
_paste_cmd_echo_verified "$PANE" "$CMD" "" worker; rc=$?
if (( rc == 0 )); then tmux send-keys -t "$PANE" C-m; _wait_file "$MARK"; fi
_nmis=$(grep -c 'launch paste echo mismatch' "$LOGF")
if (( rc == 0 && _nmis >= 1 )) && grep -q 'echoed intact after [2-3] paste attempt' "$LOGF"; then
  ok "prev-echo: the previous launcher echo did NOT validate the corrupted current paste (mismatches=$_nmis), re-pasted, rc=0"
else
  no "prev-echo: expected >=1 mismatch then rc=0 (rc=$rc mismatches=$_nmis) — a previous echo validated the swallowed paste"
fi
if [[ -s "$MARK" && "$(<"$MARK")" == "$PAYLOAD" ]]; then ok "prev-echo: the command that finally ran is intact (marker payload exact)"
else no "prev-echo: marker missing/wrong — the corrupted line was executed"; fi
tmux send-keys -t "$PANE" 'exit' C-m 2>/dev/null; sleep 0.2

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
