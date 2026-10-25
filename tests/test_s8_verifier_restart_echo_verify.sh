#!/bin/zsh
# ============================================================================
# S-8: every launch/restart path that starts a claude/codex TUI from the shell must go through
# _paste_cmd_echo_verified (launcher file + the SHORT `source '<launcher>'` line, echo-verified
# before Enter), exactly like the first worker launches. Paths covered:
#   - launch_verifier_claude            (label verifier, default accept-set)
#   - launch_verifier_codex             (label verifier, accept-set `zsh` only: the codex trigger
#                                        shell is `bash`, see launch_worker_codex / request-m 1)
#   - launch_worker_claude 15-attempt restart (label worker-restart, default accept-set)
#   - restart_worker (claude)           (label worker-restart, default accept-set)
# restart_worker keeps safe_send_keys (bypass-warning / trust-dialog guards), which gets an optional launch label.
# Per path: (a) the pasted line is the short `source '<launcher>'` form, the launcher holds the exact
# command and the full command is never pasted; (b) a missing echo yields the same failure handling
# as the worker launches (rc 1, loud log_error, NO Enter sent after the unverified paste).
#
# Mock tmux: the fake pane echoes the last pasted `source '...'` line; SWALLOW_RE makes the echo of
# matching lines lose their first character (the rc-prompt swallow), so verification never succeeds.
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

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/s8-echo.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
REC="$TMPD/rec"; ARGLOG="$TMPD/args"; ERRLOG="$TMPD/err"
CMD='/opt/homebrew/bin/claude --model sonnet --dangerously-skip-permissions --append-system-prompt-file /x/y'
ITERATION=1
WORKER_ENGINE=claude
MAX_RESTARTS=3
WORKER_MODEL=sonnet
WORKER_EFFORT=high
typeset -gA WORKER_RESTARTS
SWALLOW_RE=""
PANE_CMD="zsh"

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}
for _fn in _paste_cmd_echo_verified launch_verifier_claude launch_verifier_codex launch_worker_claude restart_worker safe_send_keys; do
  eval "$(_extract_fn $_fn "$RUN")"
  [[ "$(whence -w $_fn 2>/dev/null)" == *function* ]] && ok "extracted $_fn" || { no "could not extract $_fn"; exit 1; }
done

# --- stubs ------------------------------------------------------------------------------------
log(){ :; }; log_debug(){ :; }
log_error(){ print -r -- "$*" >> "$ERRLOG"; }
sleep(){ :; }
_wait_pane_shell_ready(){ print -r -- "ACCEPT[${2-}]" >> "$ARGLOG"; return 0; }
wait_for_pane_ready(){ print -r -- "WAIT_READY $*" >> "$ARGLOG"; return 0; }
_claude_presubmit_guard(){ return 0; }
_codex_presubmit_guard(){ print -r -- "PRESUBMIT_ANCHOR $2" >> "$ARGLOG"; return 0; }
_codex_ready_surface(){ print -r -- "READY_ANCHOR $2" >> "$ARGLOG"; return 0; }
_dismiss_codex_update_prompt(){ return 1; }
_codex_dialog_kind(){ print -r -- none; }
check_copy_mode(){ return 0; }
build_claude_cmd(){ print -r -- "$CMD"; }
# safe_send_keys is REAL (restart_worker keeps its dialog guards); its guard helpers see a plain shell pane
_claude_trust_dialog_accept(){ return 1; }
_bottom_prompt_selection(){ print -r -- none; }
_pane_width(){ print -r -- 80; }
_pane_fg_is_shell(){ return 0; }
_log_bypass_warning_refusal(){ :; }
_claude_dialog_footer_at_bottom(){ return 1; }
paste_to_pane(){ print -r -- "PASTE $2" >> "$REC"; }
tmux() {
  case "$1" in
    display-message) print -r -- "$PANE_CMD" ;;
    capture-pane)
      local last; last=$(grep "^PASTE source '" "$REC" 2>/dev/null | tail -1); last="${last#PASTE }"
      if [[ -n "$SWALLOW_RE" && "$last" =~ $SWALLOW_RE ]]; then last="${last[2,-1]}"; fi
      print -r -- "user@host ~ % $last" ;;
    send-keys) print -r -- "KEYS ${*:4}" >> "$REC" ;;
  esac
  return 0
}

# $1 = function, $2 = SWALLOW_RE, rest = args; runs one drive in a subshell, prints RC=<n>
_drive() {
  local fn="$1"; SWALLOW_RE="$2"; shift 2
  : > "$REC"; : > "$ARGLOG"; : > "$ERRLOG"
  RUNTIME_DIR=$(mktemp -d "$TMPD/rt.XXXXXX")
  print -r -- "$RUNTIME_DIR" > "$TMPD/last_rt"
  WORKER_RESTARTS=()
  "$fn" "$@" >/dev/null 2>&1; local _rc=$?; print -r -- "${WORKER_RESTARTS[3]:-unset}" > "$TMPD/restarts"; print "RC=$_rc"
}
_rt() { print -r -- "$(<"$TMPD/last_rt")"; }
# events (REC lines) strictly after the first PASTE whose text matches $1
_events_after_paste() { awk -v re="$1" 'f{print} !f && /^PASTE / && $0 ~ re {f=1}' "$REC"; }
_pastes() { grep -c "^PASTE .*$1" "$REC"; }
_full_cmd_pasted() { grep -cF "PASTE $CMD" "$REC"; }

# ===== 1. launch_verifier_claude =============================================================
print "== launch_verifier_claude =="
PANE_CMD=zsh
out=$(_drive launch_verifier_claude "" %9 /x/prompt.md 1 "$CMD"); rt=$(_rt)
LINE="source '$rt/launch-verifier-iter001.zsh'"
{ [[ "$out" == "RC=0" ]] && [[ "$(grep -m1 '^PASTE ' "$REC")" == "PASTE $LINE" ]]; } \
  && ok "pasted line is the short source '<launcher>' form ($out)" || no "first paste is not the short source line: $out / $(grep -m1 '^PASTE ' "$REC")"
{ [[ -f "$rt/launch-verifier-iter001.zsh" && "$(<"$rt/launch-verifier-iter001.zsh")" == "$CMD" ]]; } \
  && ok "launcher holds the exact command" || no "launcher missing or wrong content"
[[ "$(_full_cmd_pasted)" == 0 ]] && ok "the full command is never pasted" || no "the full command was pasted"
grep -qx 'ACCEPT\[\]' "$ARGLOG" && ok "default shell-ready accept-set (claude pane)" || no "accept-set not default: $(<"$ARGLOG")"
out=$(_drive launch_verifier_claude "launch-verifier" %9 /x/prompt.md 1 "$CMD")
{ [[ "$out" == "RC=1" && "$(_pastes "source '")" == 3 ]]; } \
  && ok "missing echo -> 3 paste attempts, rc 1 ($out)" || no "missing echo not handled: $out pastes=$(_pastes "source '")"
_events_after_paste "source '" | grep -q 'C-m' && no "Enter was sent after an unverified paste" || ok "no Enter after the unverified paste"
grep -q 'WAIT_READY' "$ARGLOG" && no "launch continued (wait_for_pane_ready) after a failed echo" || ok "launch aborts before waiting for the claude TUI"
grep -q 'Verifier claude launch command failed to echo intact' "$ERRLOG" \
  && ok "loud log_error names the verifier launch" || no "no verifier log_error: $(<"$ERRLOG")"

# ===== 2. launch_verifier_codex ==============================================================
print "== launch_verifier_codex =="
PANE_CMD=codex
out=$(_drive launch_verifier_codex "" %9 /x/prompt.md 1 "$CMD"); rt=$(_rt)
LINE="source '$rt/launch-verifier-iter001.zsh'"
{ [[ "$out" == "RC=0" ]] && [[ "$(grep -m1 '^PASTE ' "$REC")" == "PASTE $LINE" ]]; } \
  && ok "pasted line is the short source '<launcher>' form ($out)" || no "first paste is not the short source line: $out / $(grep -m1 '^PASTE ' "$REC")"
{ [[ -f "$rt/launch-verifier-iter001.zsh" && "$(<"$rt/launch-verifier-iter001.zsh")" == "$CMD" ]]; } \
  && ok "launcher holds the exact command" || no "launcher missing or wrong content"
[[ "$(_full_cmd_pasted)" == 0 ]] && ok "the full command is never pasted" || no "the full command was pasted"
grep -qx 'ACCEPT\[zsh\]' "$ARGLOG" && ok "zsh-only shell-ready accept-set (codex trigger shell is bash)" || no "accept-set not zsh: $(<"$ARGLOG")"
{ grep -qxF "READY_ANCHOR $LINE" "$ARGLOG" && grep -qxF "PRESUBMIT_ANCHOR $LINE" "$ARGLOG"; } \
  && ok "codex ready/presubmit anchors use the echoed source line, not the full command" \
  || no "codex anchors are not the source line: $(<"$ARGLOG")"
out=$(_drive launch_verifier_codex "launch-verifier" %9 /x/prompt.md 1 "$CMD")
{ [[ "$out" == "RC=1" && "$(_pastes "source '")" == 3 ]]; } \
  && ok "missing echo -> 3 paste attempts, rc 1 ($out)" || no "missing echo not handled: $out pastes=$(_pastes "source '")"
_events_after_paste "source '" | grep -q 'C-m' && no "Enter was sent after an unverified paste" || ok "no Enter after the unverified paste"
grep -q 'READY_ANCHOR' "$ARGLOG" && no "launch continued past a failed echo" || ok "launch aborts before the codex ready wait"
grep -q 'Verifier codex launch command failed to echo intact' "$ERRLOG" \
  && ok "loud log_error names the verifier launch" || no "no verifier log_error: $(<"$ERRLOG")"

# ===== 3. launch_worker_claude: 15-attempt restart ===========================================
print "== launch_worker_claude 15-attempt restart =="
PANE_CMD=zsh
out=$(_drive launch_worker_claude "" %9 /x/prompt.md 1 "$CMD"); rt=$(_rt)
RLINE="source '$rt/launch-worker-restart-iter001.zsh'"
{ [[ "$out" == "RC=0" ]] && grep -qxF "PASTE $RLINE" "$REC"; } \
  && ok "restart pastes the short source '<launcher>' form ($out)" || no "restart did not paste the short source line: $out"
{ [[ -f "$rt/launch-worker-restart-iter001.zsh" && "$(<"$rt/launch-worker-restart-iter001.zsh")" == "$CMD" ]]; } \
  && ok "restart launcher holds the exact command" || no "restart launcher missing or wrong content"
[[ "$(_full_cmd_pasted)" == 0 ]] && ok "the full command is never pasted (first launch and restart)" || no "the full command was pasted"
[[ "$(grep -c '^ACCEPT\[\]$' "$ARGLOG")" == 2 ]] && ok "both launches use the default accept-set (claude pane)" || no "accept-sets: $(grep ACCEPT "$ARGLOG" | tr '\n' ' ')"
out=$(_drive launch_worker_claude "worker-restart" %9 /x/prompt.md 1 "$CMD"); rt=$(_rt); RLINE="source '$rt/launch-worker-restart-iter001.zsh'"
{ [[ "$out" == "RC=1" && "$(_pastes "launch-worker-restart")" == 3 ]]; } \
  && ok "restart: missing echo -> 3 paste attempts, rc 1 ($out)" || no "restart missing echo not handled: $out pastes=$(_pastes "launch-worker-restart")"
_events_after_paste "launch-worker-restart" | grep -q 'C-m' && no "Enter was sent after the unverified restart paste" || ok "no Enter after the unverified restart paste"
[[ "$(tail -1 "$REC" | grep -c 'KEYS C-u')" == 1 && "$(grep '^PASTE ' "$REC" | tail -1)" == "PASTE $RLINE" ]] \
  && ok "no instruction re-sent after the failed restart" || no "something was pasted after the failed restart"
grep -q 'Worker claude restart launch command failed to echo intact' "$ERRLOG" \
  && ok "loud log_error names the worker restart" || no "no restart log_error: $(<"$ERRLOG")"

# ===== 4. restart_worker (claude) ============================================================
print "== restart_worker =="
PANE_CMD=zsh
out=$(_drive restart_worker "" %9 3 /x/trigger.sh); rt=$(_rt)
RLINE="source '$rt/launch-worker-restart-iter001.zsh'"
{ [[ "$out" == "RC=0" ]] && [[ "$(grep '^PASTE ' "$REC" | head -1)" == "PASTE $RLINE" ]]; } \
  && ok "restart_worker pastes the short source '<launcher>' form ($out)" || no "restart_worker did not paste the short source line: $out / $(grep '^PASTE ' "$REC" | head -1)"
{ [[ -f "$rt/launch-worker-restart-iter001.zsh" && "$(<"$rt/launch-worker-restart-iter001.zsh")" == "$CMD" ]]; } \
  && ok "launcher holds the exact command" || no "launcher missing or wrong content"
[[ "$(_events_after_paste "source '" | head -1)" == "KEYS C-m" ]] && ok "Enter follows the verified paste" || no "Enter does not follow the verified paste: $(_events_after_paste "source '" | head -2 | tr '\n' ' ')"
[[ "$(_full_cmd_pasted)" == 0 && "$(grep -c "^PASTE " "$REC")" == 1 ]] && ok "full command not sent (one paste: the short source line)" || no "full command still sent: $(grep "^PASTE " "$REC")"
grep -qx 'ACCEPT\[\]' "$ARGLOG" && ok "default shell-ready accept-set (claude pane)" || no "accept-set not default: $(<"$ARGLOG")"
[[ "$(<"$TMPD/restarts")" == 1 ]] && ok "restart counter advanced" || no "restart counter: $(<"$TMPD/restarts")"
out=$(_drive restart_worker "launch-worker-restart" %9 3 /x/trigger.sh)
{ [[ "$out" == "RC=1" && "$(_pastes "source '")" == 3 ]]; } \
  && ok "missing echo -> 3 paste attempts, rc 1 ($out)" || no "missing echo not handled: $out pastes=$(_pastes "source '")"
_events_after_paste "source '" | grep -q 'C-m' && no "Enter was sent after an unverified paste" || ok "no Enter after the unverified paste"
grep -q 'Worker restart launch command was refused or failed to echo intact' "$ERRLOG" \
  && ok "loud log_error names the worker restart" || no "no restart log_error: $(<"$ERRLOG")"

print ""
print "s8_verifier_restart_echo_verify: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
