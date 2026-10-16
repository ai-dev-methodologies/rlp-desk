#!/bin/zsh
# ============================================================================
# W1 / TRUST-F + N-1 + bypass diagnostic.
#
# TRUST-F: safe_send_keys, auto_dismiss_prompts (generic branch) and the shell-mode
# wait_for_pane_ready loop pressed Enter whenever "Do you want to" appeared ANYWHERE in
# the captured window — including stale worker prose above a DIFFERENT, default-No
# dialog (the claude bypass-permissions warning, cursor on "1. No, exit"). N-1: the -J
# capture in auto_dismiss_prompts widened that window on narrow panes.
#
# Contract under test: the Enter-to-approve decision is bound to the BOTTOM-MOST prompt
# block on screen and is pressed only when that block's selected option (the line with
# the cursor marker) is an accept option. A decline/exit selection, or a picker whose
# selection cannot be identified, never gets Enter: the existing refuse/BLOCK path runs
# with a log_error. A genuine permission prompt (cursor on Yes) is approved as before.
#
# Bypass-permissions warning (owner decision 2026-10-15, supersedes the 2026-10-14 auto-accept): accepting
# it persists skipDangerousModePermissionPrompt in the user's global Claude settings, so rlp-desk NEVER
# answers it — not even in a pane it launched itself with the bypass flag. The POSITIVELY identified
# warning (heading bound to the dialog block + exactly its "No, exit" / "Yes, I accept" options + confirm
# footer) gets NO key at all and ONE specific, actionable log_error (what it is, why it is refused, accept
# it once in a manual claude session started with the bypass flag, re-run); every call site keeps its
# existing refuse/BLOCK flow. A lookalike is refused as an unrecognized dialog.
#
# Drives the REAL functions extracted from run_ralph_desk.zsh against a fake tmux whose
# pane is a small state machine (an Enter on a default-No dialog EXITS claude, so a wrong
# key is observable as pane state, not only as a recorded key).
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
zmodload zsh/datetime

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # override only for mutation checks
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"; }

_extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RUN"; }
TMP_LIB=$(mktemp -t w1-prompt-binding.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
{
  _extract_fn wait_for_pane_ready
  _extract_fn safe_send_keys
  _extract_fn launch_worker_claude
  _extract_fn launch_verifier_claude
  _extract_fn restart_worker
  sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d'
} > "$TMP_LIB"
for f in wait_for_pane_ready safe_send_keys auto_dismiss_prompts _claude_presubmit_guard restart_worker; do
  grep -q "^${f}()" "$TMP_LIB" || { print -u2 "FAIL: $f not extracted"; exit 1; }
done

# --- mocks -------------------------------------------------------------------
typeset -ga KEYS LOGS ERRS BLOCKS
typeset -g STATE="ready" NARROW=0 STALE_N=0 STALE_KIND=short LAUNCH_TO="" PANE_CMD="" PANE_W=0 WRAP_AT=80   # PANE_W = what tmux reports (#{pane_width}); WRAP_AT = where the fixture is Ink-wrapped
sleep() { command sleep 0.01; }
log() { LOGS+=("$*"); }
log_debug() { LOGS+=("DEBUG $*"); }
log_error() { ERRS+=("$*"); }
write_blocked_sentinel() { BLOCKS+=("$*"); }
_dismiss_codex_update_prompt() { return 1; }
_validate_int_knob() { :; }
check_copy_mode() { return 0; }
paste_to_pane() { KEYS+=("PASTE@$STATE"); }
_paste_cmd_echo_verified() { KEYS+=("LAUNCH_PASTE"); return 0; }
build_claude_cmd() { print -r -- "DISABLE_OMC=1 claude --model m --dangerously-skip-permissions"; }
typeset -gA WORKER_RESTARTS
WORKER_ENGINE=claude; WORKER_MODEL=m; WORKER_EFFORT=high; MAX_RESTARTS=3

typeset -g BYP_VARIANT=full
_bypass_dialog() { # $1 = cursor on: no (default) | yes | none ; BYP_VARIANT: full|nohead|nofoot|extra|noaccept|prefix|remind|stale_head_delete|cancel|acceptmem
  local _c="${1:-no}" _yes_lbl="Yes, I accept" _no_lbl="No, exit"
  [[ "$BYP_VARIANT" == prefix ]] && _yes_lbl="Yes, I accept deleting all project files"
  [[ "$BYP_VARIANT" == acceptmem ]] && _yes_lbl="Yes, accept and remember"
  [[ "$BYP_VARIANT" == cancel ]] && _no_lbl="Cancel"
  if [[ "$BYP_VARIANT" != nohead ]]; then
    print -r -- " WARNING: Claude Code running in Bypass Permissions mode"
    print -r -- " By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode."
  fi
  [[ "$BYP_VARIANT" == stale_head_delete ]] && print -r -- " Delete project permanently?"
  [[ "$BYP_VARIANT" == remind ]] && print -r -- "   Remind me later"
  case "$_c" in
    no)   print -r -- " ❯ 1. $_no_lbl"; [[ "$BYP_VARIANT" == noaccept ]] || print -r -- "   2. $_yes_lbl" ;;
    yes)  print -r -- "   1. $_no_lbl"; print -r -- " ❯ 2. $_yes_lbl" ;;
    none) print -r -- "   1. $_no_lbl"; print -r -- "   2. $_yes_lbl" ;;
  esac
  [[ "$BYP_VARIANT" == extra ]] && print -r -- "   3. Yes, and remember this choice"
  [[ "$BYP_VARIANT" == nofoot ]] || print -r -- " Enter to confirm · Esc to cancel"
}
# R2-03: the real warning (title, 3 body paragraphs, docs link, the two options, footer), Ink-wrapped at PANE_W.
_real_bypass_dialog() {
  local W=${PANE_W:-80} _t _b1 _b2 _b3 _bl
  _t="WARNING: Claude Code running in Bypass Permissions mode"
  _b1="In Bypass Permissions mode, Claude Code will not ask for your approval before running potentially dangerous commands."
  _b2="This mode should only be used in a sandboxed container/VM that has restricted internet access and can easily be restored if damaged."
  _b3="By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode."
  _bl="https://docs.anthropic.com/s/claude-code-security"
  print -r -- "$_t" | LC_ALL=en_US.UTF-8 fold -s -w $W; print ""
  print -r -- "$_b1" | LC_ALL=en_US.UTF-8 fold -s -w $W; print ""
  print -r -- "$_b2" | LC_ALL=en_US.UTF-8 fold -s -w $W; print ""
  print -r -- "$_b3" | LC_ALL=en_US.UTF-8 fold -s -w $W; print ""
  print -r -- "$_bl" | LC_ALL=en_US.UTF-8 fold -s -w $W; print ""
  print -r -- " ❯ 1. No, exit"; print -r -- "   2. Yes, I accept"; print ""
  print -r -- " Enter to confirm · Esc to cancel"
}
# R2-02: a real permission prompt whose option 2 wraps (Ink word-wrap, continuation indented to the option text).
_WRAP_OPT2="Yes, and don't ask again for npm run test commands in /Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk"
_ink_opt() { # $1 width, $2 prefix, $3 text
  local W=$1 pre="$2" txt="$3" ind line w first=1
  ind=$(printf '%*s' ${#pre} '')
  line="$pre"
  for w in ${=txt}; do
    if (( first )); then line+="$w"; first=0
    elif (( ${#line} + 1 + ${#w} <= W )); then line+=" $w"
    else print -r -- "$line"; line="$ind$w"; fi
  done
  print -r -- "$line"
}
_wrapped_prompt() { # $1 = width
  print -r -- "● Write(test.json)"; print -r -- " Do you want to create test.json?"; print -r -- " ❯ 1. Yes"
  _ink_opt $1 "   2. " "$_WRAP_OPT2"
  print -r -- "   3. No, and tell Claude what to do differently (esc)"; print ""; print -r -- " Esc to cancel · Tab to amend"
}
_claude_box() {
  print -r -- " ▐▛███▛█   Claude Code v2.1.296"
  print -r -- "────────────────────────────────────────────────────────────────────────────────────"
  print -r -- "❯ Try \"refactor <filepath>\""
  print -r -- "────────────────────────────────────────────────────────────────────────────────────"
  print -r -- "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
}
# Stale worker prose that quotes a permission-prompt question, then STALE_N long worker
# lines (each wraps to 3+ rows on a 40-col pane).
_stale_prose() {
  local _i
  case "$STALE_KIND" in
    short) print -r -- "● The previous permission prompt said: Do you want to create test.json?" ;;
    wrapsplit) print -r -- "● Earlier the worker asked me: Do you want to create test.json?" ;;   # "Do you want to" straddles col 40
    hardsplit) print -r -- "● Earlier the worker asked: Do you want"; print -r -- "to create test.json?" ;;
  esac
  for (( _i = 0; _i < STALE_N; _i++ )); do
    print -r -- "● worker note $_i: the quick brown fox jumps over the lazy dog and keeps running through the long field until it reaches the far fence and stops"
  done
}
_perm() { # $1 = which option holds the cursor: 1|2|3|none
  print -r -- "● Write(test.json)"
  print -r -- " Do you want to create test.json?"
  local -a _o=("Yes" "Yes, allow all edits during this session (shift+tab)" "No, and tell Claude what to do differently (esc)")
  local _k
  for _k in 1 2 3; do
    if [[ "$1" == "$_k" ]]; then print -r -- " ❯ $_k. ${_o[_k]}"; else print -r -- "   $_k. ${_o[_k]}"; fi
  done
  print -r -- ""
  if [[ "$1" == none ]]; then print -r -- " Enter to confirm · Esc to cancel"; else print -r -- " Esc to cancel · Tab to amend"; fi
}

_emit() { if (( NARROW )) && [[ "$*" != *" -J"* ]]; then LC_ALL=en_US.UTF-8 fold -w 40; else cat; fi; }
tmux() {
  local sub="$1"
  case "$sub" in
    capture-pane)
      { case "$STATE" in
        stale_bypass) _stale_prose; _bypass_dialog ;;
        stale_bypass_yes) _stale_prose; _bypass_dialog yes ;;
        bypass)       _bypass_dialog ;;
        bypass_yes)   _bypass_dialog yes ;;
        bypass_none)  _bypass_dialog none ;;
        bypass_real)  _real_bypass_dialog ;;
        stale_bypass_real) _stale_prose; _real_bypass_dialog ;;
        stale_ui_bypass) _claude_box; _bypass_dialog ;;
        perm_yes)     _perm 1 ;;
        perm_yes_and) print -r -- " Do you want to proceed?"; print -r -- " ❯ 1. Yes"; print -r -- "   2. Yes, and don't ask again for npm run test commands in /tmp/proj"; print -r -- "   3. No, and tell Claude what to do differently (esc)" ;;
        stale_perm_yes) _stale_prose; _perm 1 ;;
        perm_no)      _perm 3 ;;
        perm_nocursor) _perm none ;;
        perm_wrap)    _wrapped_prompt $WRAP_AT ;;
        perm_wrap_trail) _wrapped_prompt $WRAP_AT | sed "/Esc to cancel/d"; print -r -- "Status: waiting for input" ;;
        r2e_aligned)  print -r -- " Do you want to proceed?"; print -r -- " ❯ 1. Yes"; print -r -- "   2. No"; print -r -- "      Status: waiting for input" ;;
        m13_two_cursors) print -r -- "Do you want to proceed?"; print -r -- "❯ 1. No"; print -r -- "❯ 2. Yes" ;;
        m13_two_cursors_yes) print -r -- "Do you want to proceed?"; print -r -- "❯ 1. Yes"; print -r -- "❯ 2. Yes, allow all edits"; print -r -- "  3. No" ;;
        perm_blank)   print -r -- " Do you want to create test.json?"; print -r -- ""; print -r -- " ❯ 1. Yes"; print -r -- "   2. Yes, allow all edits during this session (shift+tab)"; print -r -- "   3. No, and tell Claude what to do differently (esc)"; print -r -- ""; print -r -- " Esc to cancel · Tab to amend" ;;
        perm_blank_nofoot) print -r -- " Do you want to create test.json?"; print -r -- ""; print -r -- " ❯ 1. Yes"; print -r -- "   2. No" ;;
        r2a_trail_no) print -r -- "Do you want to proceed?"; print -r -- "  1. Yes"; print -r -- "❯ 2. No"; print -r -- "Status: waiting for input" ;;
        r2a_trail_yes) print -r -- "Do you want to proceed?"; print -r -- "❯ 1. Yes"; print -r -- "  2. No"; print -r -- "Status: waiting for input" ;;
        r2a_stale_menu) print -r -- "Previous result: Do you want to create old.txt?"; print -r -- "Security settings"; print -r -- "❯ 1. Yes, enable"; print -r -- "  2. No, keep disabled"; print -r -- "Esc to cancel" ;;
        r2a_stale_direct) print -r -- "Previous result: Do you want to create old.txt?"; print -r -- "❯ 1. Yes"; print -r -- "  2. No"; print -r -- "Esc to cancel" ;;
        r2a_two_blank) print -r -- "Do you want to proceed?"; print -r -- ""; print -r -- ""; print -r -- "❯ 1. Yes"; print -r -- "  2. No" ;;
        r2a_unnumbered) print -r -- "Do you want to proceed? (y/n)"; print -r -- "❯ Destroy workspace"; print -r -- "  Open settings"; print -r -- "Esc to cancel" ;;
        shell_stale)  print -r -- "Do you want to create old.txt?"; print -r -- "❯ 1. Yes"; print -r -- "  2. No"; print -r -- "Esc to cancel"; print -r -- "kyjin@host rlp-desk % " ;;
        shell_stale_byp) _bypass_dialog; print -r -- "kyjin@host rlp-desk % " ;;
        ready)        _claude_box ;;
        *)            print -r -- "kyjin@host rlp-desk % " ;;
      esac; } | _emit "$@" ;;
    display-message)
      if [[ "$*" == *pane_current_command* ]]; then
        if [[ -n "$PANE_CMD" ]]; then print -r -- "$PANE_CMD"
        else case "$STATE" in exited|starting) print zsh ;; *) print claude.exe ;; esac; fi
      elif [[ "$*" == *pane_width* ]]; then print -r -- "$PANE_W"
      else print -- 0; fi ;;
    send-keys)
      local key="${@: -1}"; [[ "$key" == "C-m" ]] && key="Enter"
      if [[ "$*" == *"/exit"* ]]; then KEYS+=("EXIT"); return 0; fi
      KEYS+=("$key")
      case "$STATE:$key" in
        stale_bypass:Enter|bypass:Enter|bypass_none:Enter|stale_ui_bypass:Enter|perm_no:Enter|perm_nocursor:Enter) STATE="exited" ;;
        bypass_yes:Enter|stale_bypass_yes:Enter|bypass_real:Enter) STATE="ready" ;;   # Enter on a warning with the cursor on Yes ACCEPTS it (observable)
        perm_yes:Enter|perm_yes_and:Enter|stale_perm_yes:Enter|perm_blank:Enter|perm_blank_nofoot:Enter|perm_wrap:Enter) STATE="ready" ;;
        perm_wrap_trail:Enter|r2e_aligned:Enter|m13_two_cursors:Enter|m13_two_cursors_yes:Enter) STATE="exited" ;;
        bypass:Escape|bypass_yes:Escape|bypass_none:Escape|stale_bypass:Escape|stale_bypass_yes:Escape) STATE="exited" ;;   # Esc on the warning = cancel = exit claude
        starting:Enter)    [[ -n "$LAUNCH_TO" ]] && STATE="$LAUNCH_TO" ;;   # the shell runs the pasted launch command
        bypass:Down)       STATE="bypass_yes" ;;   # a Down on the warning moves the cursor onto Yes (observable)
        stale_bypass:Down) STATE="stale_bypass_yes" ;;
      esac ;;
  esac
  return 0
}

typeset -gA LAST_AUTO_APPROVE_TS PANE_PROMPT_STUCK_SINCE PANE_DISMISS_FAILED_COUNT PANE_VERIFIER_TRACE_LOGGED
source "$TMP_LIB"

AUDIT_DIR=$(mktemp -d -t w1-audit.XXXXXX)
trap 'rm -f "$TMP_LIB"; rm -rf "$AUDIT_DIR"' EXIT
LOGS_DIR="$AUDIT_DIR"; ITERATION=3; WORKER_PANE="%t"; VERIFIER_PANE="%v"
_reset() { KEYS=(); LOGS=(); ERRS=(); BLOCKS=(); LAST_AUTO_APPROVE_TS=(); NARROW=0; STALE_N=0; STALE_KIND=short; PANE_CMD=""; PANE_W=0; WRAP_AT=80; LAUNCH_TO=""; BYP_VARIANT=full; WORKER_RESTARTS=(); STATE="$1"; }
_keys() { print -r -- "${(j:,:)KEYS}"; }
_has_enter() { [[ ",$(_keys)," == *",Enter,"* ]]; }

# $1=label; runs all three Enter-capable call shapes on the CURRENT fixture and asserts no key at all
# reaches the pane. $2 = state to set before each shape.
_assert_no_enter_all_shapes() {
  local label="$1" st="$2" nw="${3:-0}" sn="${4:-0}" sk="${5:-short}" pw="${6:-0}"
  _reset "$st"; NARROW=$nw; STALE_N=$sn; STALE_KIND=$sk; PANE_W=$pw
  safe_send_keys "%t" "do the thing"; local rc=$?
  { ! _has_enter && [[ "$(_keys)" != *PASTE* ]] && (( rc != 0 )) && [[ "$STATE" != exited ]]; } \
    && ok "$label safe_send_keys: no Enter, no paste, refused (rc=$rc)" || no "$label safe_send_keys keys=$(_keys) rc=$rc state=$STATE"
  (( ${#ERRS[@]} >= 1 )) && ok "$label safe_send_keys: refusal logged" || no "$label safe_send_keys: silent refusal"
  _reset "$st"; NARROW=$nw; STALE_N=$sn; STALE_KIND=$sk; PANE_W=$pw
  auto_dismiss_prompts "%t"
  { ! _has_enter && [[ "$STATE" != exited ]]; } && ok "$label auto_dismiss_prompts: no Enter" || no "$label auto_dismiss_prompts keys=$(_keys) state=$STATE"
  (( ${#ERRS[@]} >= 1 && ${#BLOCKS[@]} >= 1 )) && ok "$label auto_dismiss_prompts: log_error + BLOCKED sentinel" || no "$label auto_dismiss_prompts errs=${#ERRS[@]} blocks=${#BLOCKS[@]}"
  _reset "$st"; NARROW=$nw; STALE_N=$sn; STALE_KIND=$sk; PANE_W=$pw
  wait_for_pane_ready "%t" 1
  { ! _has_enter && [[ "$STATE" != exited ]]; } && ok "$label wait_for_pane_ready (shell mode): no Enter" || no "$label wait_for_pane_ready keys=$(_keys) state=$STATE"
  # a wording split by a hard newline never matches the shell-mode "Do you want to" test at all, so that
  # branch (and its refusal log) is not entered; the assertion that matters there is: no Enter.
  if [[ "$sk" == hardsplit ]] || (( ${#ERRS[@]} >= 1 )); then ok "$label wait_for_pane_ready (shell mode): refusal logged (or wording never matched)"; else no "$label wait_for_pane_ready: silent"; fi
  _reset "$st"; NARROW=$nw; STALE_N=$sn; STALE_KIND=$sk; PANE_W=$pw
  wait_for_pane_ready "%t" 1 claude
  { ! _has_enter && [[ "$STATE" != exited ]]; } && ok "$label wait_for_pane_ready (claude mode): no Enter" || no "$label wait_for_pane_ready claude keys=$(_keys) state=$STATE"
}

print "== (a) r19 F-1 reproducer: stale 'Do you want to create test.json?' above the bypass dialog =="
_assert_no_enter_all_shapes "(a)" stale_bypass 0 0 short

print "== (b) r19 F-3: 40-col pane, short stale line, N long worker lines, bypass dialog =="
for N in 0 1 2 3 4 6 9; do
  _assert_no_enter_all_shapes "(b) N=$N" stale_bypass 1 $N short
done

print "== (c) stale wording split across a wrap boundary / a hard newline above a default-No dialog =="
_assert_no_enter_all_shapes "(c1) soft wrap, narrow pane" stale_bypass 1 0 wrapsplit
_assert_no_enter_all_shapes "(c2) hard newline split" stale_bypass 0 0 hardsplit

print "== (d) real permission prompt, cursor on Yes: Enter IS sent (regression guard) =="
_reset perm_yes
safe_send_keys "%t" "do the thing"
check "(d) safe_send_keys: Enter before the paste" "Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,2]}}"
_reset perm_yes
auto_dismiss_prompts "%t"
check "(d) auto_dismiss_prompts: Enter" "Enter" "$(_keys)"
check "(d) auto_dismiss_prompts: pane moved on (approved)" "ready" "$STATE"
_reset perm_yes
wait_for_pane_ready "%t" 3
check "(d) wait_for_pane_ready (shell mode): Enter then ready" "Enter" "$(_keys)"
check "(d) wait_for_pane_ready: pane approved" "ready" "$STATE"
_reset perm_yes_and
auto_dismiss_prompts "%t"
check "(d) 'Do you want to proceed?' with '❯ 1. Yes' + a 'Yes, and ...' option: Enter" "Enter" "$(_keys)"
_reset perm_yes_and
safe_send_keys "%t" "x"
check "(d) same via safe_send_keys: Enter first" "Enter" "${KEYS[1]}"
_reset stale_perm_yes; STALE_N=2; NARROW=1
auto_dismiss_prompts "%t"
check "(d) stale wording above a genuine Yes prompt on a narrow pane: Enter" "Enter" "$(_keys)"
(( ${#ERRS[@]} == 0 )) && ok "(d) no refusal logged for a genuine prompt" || no "(d) unexpected errors: ${(j:|:)ERRS}"

print "== (e) permission prompt whose cursor sits on No / no identifiable cursor: no Enter =="
_assert_no_enter_all_shapes "(e) cursor on 3. No" perm_no
_assert_no_enter_all_shapes "(e2) options without any cursor (unknown selection)" perm_nocursor

print "== OWN-1: the bypass-permissions warning is identified and REFUSED — never answered, with one specific actionable message =="
_check_bypass_msg() { # $1=label ; exactly ONE log_error names the warning and carries every actionable fact
  local m="${(j:|:)ERRS}" n=0 e
  for e in "${ERRS[@]}"; do [[ "$e" == *"bypass-permissions warning"* ]] && n=$((n+1)); done
  (( n == 1 )) && ok "$1: exactly one bypass-permissions log_error" || no "$1: $n bypass-permissions log_errors (ERRS=$m)"
  [[ "$m" == *"will not accept"* && "$m" == *"skipDangerousModePermissionPrompt"* && "$m" == *"manual claude session"* && "$m" == *"--dangerously-skip-permissions"* && "$m" == *"re-run"* ]] \
    && ok "$1: message names the refusal, skipDangerousModePermissionPrompt, the one-time manual acceptance with the bypass flag, and re-run" || no "$1: message lacks an actionable fact (ERRS=$m)"
}
_no_dialog_key() { [[ ",$(_keys)," != *",Down,"* && ",$(_keys)," != *",Enter,"* && ",$(_keys)," != *",Escape,"* ]]; }
for ST in bypass bypass_yes bypass_none stale_bypass stale_ui_bypass; do
  _reset $ST
  safe_send_keys "%t" "x"; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "[$ST] safe_send_keys: refused, no keys" || no "[$ST] safe_send_keys rc=$rc keys=$(_keys)"
  _check_bypass_msg "[$ST] safe_send_keys"
  _reset $ST
  auto_dismiss_prompts "%t"
  [[ -z "$(_keys)" ]] && ok "[$ST] auto_dismiss_prompts: no keys" || no "[$ST] auto_dismiss_prompts keys=$(_keys)"
  _check_bypass_msg "[$ST] auto_dismiss_prompts"
  (( ${#BLOCKS[@]} >= 1 )) && [[ "${(j:|:)BLOCKS}" == *"bypass-permissions"* ]] && ok "[$ST] auto_dismiss_prompts: BLOCKED sentinel names the bypass warning" || no "[$ST] sentinel not specific (${(j:|:)BLOCKS})"
  { [[ "${(j:|:)BLOCKS}" == *"manual claude session"* && "${(j:|:)BLOCKS}" == *"--dangerously-skip-permissions"* && "${(j:|:)BLOCKS}" == *"skipDangerousModePermissionPrompt"* && "${(j:|:)BLOCKS}" == *"re-run"* && "${(j:|:)BLOCKS}" != *"without bypass"* ]]; } && ok "[$ST] auto_dismiss_prompts: BLOCKED reason is actionable (one-time manual acceptance with the bypass flag, no impossible 'run without bypass')" || no "[$ST] BLOCKED reason not actionable (${(j:|:)BLOCKS})"
  _reset $ST
  _t0=$EPOCHREALTIME
  wait_for_pane_ready "%t" 5 claude; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "[$ST] wait_for_pane_ready (claude): not ready, no keys" || no "[$ST] wait claude rc=$rc keys=$(_keys)"
  (( EPOCHREALTIME - _t0 < 2.5 )) && ok "[$ST] wait_for_pane_ready (claude): refuses at once (identified dialog, not a 5s timeout)" || no "[$ST] wait claude took $(( EPOCHREALTIME - _t0 ))s"
  _check_bypass_msg "[$ST] wait_for_pane_ready (claude)"
  _reset $ST
  _claude_presubmit_guard "%t" test; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "[$ST] presubmit guard: refused, no keys" || no "[$ST] presubmit rc=$rc keys=$(_keys)"
  _check_bypass_msg "[$ST] presubmit guard"
done
_reset perm_no
safe_send_keys "%t" "x"
[[ "${(j:|:)ERRS}" != *"bypass-permissions"* ]] && ok "a non-bypass declined dialog does NOT claim to be the bypass warning" || no "false bypass message on a permission prompt"

print "== OWN-1: a pane rlp-desk launched ITSELF with the bypass flag gets the same refusal (the 2026-10-14 auto-accept is gone) =="
for LF in launch_worker_claude launch_verifier_claude; do
  _reset starting; LAUNCH_TO=bypass
  $LF "%t" "/tmp/prompt.md" 1 "DISABLE_OMC=1 claude --model 'x' --dangerously-skip-permissions --add-dir /tmp"; rc=$?
  (( rc != 0 )) && ok "OWN-1[$LF] launch with the bypass flag: fails loudly (rc=$rc), the warning is not answered" || no "OWN-1[$LF] rc=0 keys=$(_keys) state=$STATE"
  _nE=${#${(M)KEYS:#Enter}}
  { (( _nE == 1 )) && [[ ",$(_keys)," != *",Down,"* && ",$(_keys)," != *",Escape,"* ]]; } && ok "OWN-1[$LF] only the launch's own Enter was sent (no Down, no Escape, no Enter to the warning)" || no "OWN-1[$LF] keys=$(_keys)"
  [[ "$STATE" == bypass ]] && ok "OWN-1[$LF] claude still on the untouched warning (not accepted, not exited)" || no "OWN-1[$LF] state=$STATE"
  _check_bypass_msg "OWN-1[$LF]"
done
_reset bypass
restart_worker "%t" 1 /tmp/trigger.sh; rc=$?
{ ! _has_enter && [[ ",$(_keys)," != *",Down,"* && ",$(_keys)," != *",Escape,"* ]] && [[ "$STATE" == bypass ]]; } && ok "OWN-1 restart_worker while a warning is on screen: nothing pressed on it, it stays untouched" || no "OWN-1 restart keys=$(_keys) state=$STATE"
_reset bypass_real; PANE_W=80
wait_for_pane_ready "%t" 5 claude; rc=$?
{ (( rc != 0 )) && [[ -z "$(_keys)" ]] && [[ ! -e "$AUDIT_DIR/bypass-accept.log" ]]; } && ok "OWN-1 no bypass-accept.log is ever written (the audit machinery is gone)" || no "OWN-1 audit file present or keys sent (rc=$rc keys=$(_keys))"

print "== R2-03: the real full-body warning (title, 3 paragraphs, link) at several pane widths is identified in every call shape =="
for PW in 120 80 60 40 30; do
  for ST in bypass_real stale_bypass_real; do
    _reset $ST; PANE_W=$PW
    safe_send_keys "%t" "x"; rc=$?
    (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "[$ST w=$PW] safe_send_keys: refused, no keys" || no "[$ST w=$PW] safe_send_keys rc=$rc keys=$(_keys)"
    _check_bypass_msg "[$ST w=$PW] safe_send_keys"
    _reset $ST; PANE_W=$PW
    auto_dismiss_prompts "%t"
    [[ -z "$(_keys)" ]] && (( ${#BLOCKS[@]} >= 1 )) && [[ "${(j:|:)BLOCKS}" == *"bypass-permissions"* ]] && ok "[$ST w=$PW] auto_dismiss_prompts: no keys, BLOCKED names the warning" || no "[$ST w=$PW] auto_dismiss keys=$(_keys) blocks=${(j:|:)BLOCKS}"
    _check_bypass_msg "[$ST w=$PW] auto_dismiss_prompts"
    _reset $ST; PANE_W=$PW
    wait_for_pane_ready "%t" 3 claude; rc=$?
    (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "[$ST w=$PW] wait_for_pane_ready (claude): not ready, no keys" || no "[$ST w=$PW] wait claude rc=$rc keys=$(_keys)"
    _check_bypass_msg "[$ST w=$PW] wait_for_pane_ready (claude)"
  done
done

print "== negatives: lookalikes are refused (no key); only a dialog without the heading is never called the bypass warning =="
_lookalike_all_shapes() { # $1=label $2=state $3=variant $4=pane command override $5=claim: no = must not be called the bypass warning, any = either name is fine
  local label="$1" st="$2" var="${3:-full}" claim="${5:-any}"
  _reset "$st"; BYP_VARIANT=$var; PANE_CMD="${4:-}"
  safe_send_keys "%t" "x"; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "$label safe_send_keys: refused, no keys" || no "$label safe_send_keys rc=$rc keys=$(_keys)"
  if [[ "$claim" == no ]]; then
    [[ "${(j:|:)ERRS}" != *"bypass-permissions warning"* ]] && ok "$label safe_send_keys: not claimed to be the bypass warning" || no "$label safe_send_keys claims the bypass warning: ${(j:|:)ERRS}"
  fi
  _reset "$st"; BYP_VARIANT=$var; PANE_CMD="${4:-}"
  auto_dismiss_prompts "%t"
  [[ -z "$(_keys)" && "$STATE" != exited ]] && ok "$label auto_dismiss_prompts: no keys" || no "$label auto_dismiss_prompts keys=$(_keys)"
  (( ${#BLOCKS[@]} >= 1 )) && ok "$label auto_dismiss_prompts: BLOCKED (refuse path)" || no "$label auto_dismiss_prompts: no sentinel"
  _reset "$st"; BYP_VARIANT=$var; PANE_CMD="${4:-}"
  wait_for_pane_ready "%t" 1 claude; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "$label wait_for_pane_ready (claude): not ready, no keys" || no "$label wait claude rc=$rc keys=$(_keys)"
  _reset "$st"; BYP_VARIANT=$var; PANE_CMD="${4:-}"
  _claude_presubmit_guard "%t" test; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "$label presubmit guard: refused, no keys" || no "$label presubmit rc=$rc keys=$(_keys)"
}
_lookalike_all_shapes "AN2 partial: options + footer but NO warning heading" bypass nohead "" no
_lookalike_all_shapes "AN3 partial: heading + options but NO confirm footer" bypass nofoot
_lookalike_all_shapes "AN4 unknown: extra third option" bypass extra
_lookalike_all_shapes "AN5 partial: 'No, exit' only, no accept option" bypass noaccept
_lookalike_all_shapes "AN6 option label PREFIX: 'Yes, I accept deleting all project files'" bypass prefix
_lookalike_all_shapes "AN7 extra 'Remind me later' option above the expected options" bypass remind
_lookalike_all_shapes "AN8 stale bypass heading, then a 'Delete project permanently?' menu with the same labels" bypass stale_head_delete "" no
# R2-08z / M08: a different decline or accept label is not the exact warning — still refused (heading-bound backstop) ...
_lookalike_all_shapes "M08a decline label 'Cancel' (not 'No, exit')" bypass cancel
_lookalike_all_shapes "M08b accept label 'Yes, accept and remember' (not 'Yes, I accept')" bypass acceptmem
# ... but the positive identification (the immediate refusal in claude mode) needs BOTH exact labels: dropping the
# "No, exit" requirement makes the Cancel variant fail fast like the real warning, so the timing tells them apart.
print "== R2-08z / M08: the immediate refusal needs the exact labels (a different label waits for the timeout) =="
_reset bypass; _t0=$EPOCHREALTIME
wait_for_pane_ready "%t" 4 claude; rc=$?
(( rc != 0 && EPOCHREALTIME - _t0 < 2 )) && ok "M08 control: the exact warning is refused at once" || no "M08 control: rc=$rc took $(( EPOCHREALTIME - _t0 ))s"
for V in cancel acceptmem; do
  _reset bypass; BYP_VARIANT=$V; _t0=$EPOCHREALTIME
  wait_for_pane_ready "%t" 4 claude; rc=$?
  (( rc != 0 && EPOCHREALTIME - _t0 >= 2.9 )) && [[ -z "$(_keys)" ]] && ok "M08[$V]: not the exact warning => no immediate refusal (waited $(( EPOCHREALTIME - _t0 ))s), still no key" || no "M08[$V]: rc=$rc took $(( EPOCHREALTIME - _t0 ))s keys=$(_keys)"
done
# AN9: the dialog text printed while the pane foreground is a SHELL (a lookalike printed by a command, or stale
# scrollback) is not a live dialog — nothing is pressed; a shell shows no dialog, so safe_send_keys pastes normally.
for FGS in zsh:bypass bash:bypass_yes; do
  _FG=${FGS%%:*}; _ST=${FGS##*:}
  _reset $_ST; PANE_CMD=$_FG
  safe_send_keys "%t" "x"; rc=$?
  { [[ "${KEYS[1]:-}" == PASTE@* ]] && [[ ",$(_keys)," != *",Down,"* ]] ; } && ok "AN9[$_FG] safe_send_keys: the lookalike is not answered (first key is the paste, so no Enter/Down before it)" || no "AN9[$_FG] safe_send_keys keys=$(_keys) state=$STATE"
  _reset $_ST; PANE_CMD=$_FG
  auto_dismiss_prompts "%t"
  [[ -z "$(_keys)" ]] && ok "AN9[$_FG] auto_dismiss_prompts: no keys" || no "AN9[$_FG] auto_dismiss keys=$(_keys)"
  _reset $_ST; PANE_CMD=$_FG
  wait_for_pane_ready "%t" 1 claude; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "AN9[$_FG] wait_for_pane_ready (claude): not ready, no keys" || no "AN9[$_FG] wait claude rc=$rc keys=$(_keys)"
  _reset $_ST; PANE_CMD=$_FG
  _claude_presubmit_guard "%t" test; rc=$?
  (( rc != 0 )) && [[ -z "$(_keys)" ]] && ok "AN9[$_FG] presubmit guard: refused, no keys" || no "AN9[$_FG] presubmit rc=$rc keys=$(_keys)"
done

print "== R2-A: a picker that is not an active identified dialog never gets Enter (all call shapes) =="
_assert_no_enter_all_shapes "(R2-A1) output after the options, cursor on No" r2a_trail_no
_assert_no_enter_all_shapes "(R2-A1b) output after the options, cursor on Yes" r2a_trail_yes
_assert_no_enter_all_shapes "(R2-A2) stale 'Previous result' question + heading above a selected-Yes menu" r2a_stale_menu
_assert_no_enter_all_shapes "(R2-A2b) stale 'Previous result' question directly above the menu" r2a_stale_direct
_assert_no_enter_all_shapes "(R2-A3) two blank lines between question and options" r2a_two_blank
_assert_no_enter_all_shapes "(R2-A4) wording + unnumbered unknown picker + footer" r2a_unnumbered

print "== R2-A/R2-G parity: genuine prompts still get Enter (incl. ONE blank line between question and options) =="
for ST in perm_blank perm_blank_nofoot; do
  _reset $ST; safe_send_keys "%t" "do the thing"
  check "($ST) safe_send_keys: Enter before the paste" "Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,2]}}"
  _reset $ST; auto_dismiss_prompts "%t"
  check "($ST) auto_dismiss_prompts: Enter" "Enter" "$(_keys)"
  _reset $ST; wait_for_pane_ready "%t" 3
  check "($ST) wait_for_pane_ready (shell mode): Enter" "Enter" "$(_keys)"
done
_reset perm_yes; safe_send_keys "%t" "x"
check "(positive) the claude permission prompt (1. Yes / 2. Yes, allow all edits (shift+tab) / 3. No ... (esc)) + footer: Enter then paste" "Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,2]}}"

print "== R2-02: a real permission prompt whose option wraps (word-wrap evidence from #{pane_width}) still gets Enter =="
for PW in 80 60; do
  _reset perm_wrap; PANE_W=$PW; WRAP_AT=$PW
  safe_send_keys "%t" "do the thing"
  check "(R2-02 w=$PW) safe_send_keys: Enter before the paste" "Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,2]}}"
  _reset perm_wrap; PANE_W=$PW; WRAP_AT=$PW
  auto_dismiss_prompts "%t"
  check "(R2-02 w=$PW) auto_dismiss_prompts: Enter" "Enter" "$(_keys)"
  (( ${#ERRS[@]} == 0 && ${#BLOCKS[@]} == 0 )) && ok "(R2-02 w=$PW) no refusal logged for a genuine wrapped prompt" || no "(R2-02 w=$PW) refusal: ${(j:|:)ERRS} ${(j:|:)BLOCKS}"
  _reset perm_wrap; PANE_W=$PW; WRAP_AT=$PW
  wait_for_pane_ready "%t" 3
  check "(R2-02 w=$PW) wait_for_pane_ready (shell mode): Enter then ready" "Enter" "$(_keys)"
done
print "== R2-02 negatives: no word-wrap evidence => the frozen rule stands (refuse, never Enter) =="
_assert_no_enter_all_shapes "(R2-02n1) wrapped prompt but pane_width unavailable" perm_wrap 0 0 short 0
_assert_no_enter_all_shapes "(R2-02n2) wrapped-looking prompt on a pane far wider than the rows (no wrap evidence)" perm_wrap 0 0 short 400
_assert_no_enter_all_shapes "(R2-02n3) wrapped prompt followed by other output" perm_wrap_trail 0 0 short 80
_assert_no_enter_all_shapes "(R2-E) aligned output after a SHORT option row is not a wrapped option" r2e_aligned 0 0 short 80
print "== R2-08z / M13: two cursor-marked options are never approved (all call shapes) =="
_assert_no_enter_all_shapes "(M13a) cursors on 1. No and 2. Yes" m13_two_cursors
_assert_no_enter_all_shapes "(M13b) cursors on 1. Yes and 2. Yes, allow all edits" m13_two_cursors_yes

print "== follow-up: a SHELL in the foreground cannot be showing a claude/codex dialog (stale scrollback never blocks) =="
_no_refusal() { (( ${#ERRS[@]} == 0 && ${#BLOCKS[@]} == 0 )); }
for ST in shell_stale shell_stale_byp; do
  for FG in zsh bash sh fish; do
    _reset $ST; PANE_CMD=$FG
    safe_send_keys "%t" "do the thing"; rc=$?
    { (( rc == 0 )) && [[ "${KEYS[1]:-}" == PASTE@* ]] && _no_refusal; } && ok "[$ST fg=$FG] safe_send_keys: pastes normally, no Enter before the paste, no refusal" || no "[$ST fg=$FG] safe_send_keys rc=$rc keys=$(_keys) errs=${(j:|:)ERRS}"
    _reset $ST; PANE_CMD=$FG
    wait_for_pane_ready "%t" 3; rc=$?
    { (( rc == 0 )) && ! _has_enter && _no_refusal && [[ "${(j:|:)LOGS}" == *"is ready."* ]] && [[ "${(j:|:)LOGS}" != *"timeout"* ]]; } && ok "[$ST fg=$FG] wait_for_pane_ready (shell mode): ready at once, no fail-open timeout, no Enter, no refusal" || no "[$ST fg=$FG] wait shell rc=$rc keys=$(_keys) errs=${(j:|:)ERRS} logs=${(j:|:)LOGS}"
    _reset $ST; PANE_CMD=$FG
    wait_for_pane_ready "%t" 1 claude; rc=$?
    { (( rc != 0 )) && [[ -z "$(_keys)" ]] && [[ "${(j:|:)ERRS}" != *"permission-prompt"* && "${(j:|:)ERRS}" != *"bypass-permissions warning is on screen"* ]]; } && ok "[$ST fg=$FG] wait_for_pane_ready (claude mode): not ready (claude is not running), no keys, no dialog refusal" || no "[$ST fg=$FG] wait claude rc=$rc keys=$(_keys) errs=${(j:|:)ERRS}"
    _reset $ST; PANE_CMD=$FG
    auto_dismiss_prompts "%t"
    { [[ -z "$(_keys)" ]] && _no_refusal; } && ok "[$ST fg=$FG] auto_dismiss_prompts: no Enter, no refusal, no BLOCKED sentinel" || no "[$ST fg=$FG] auto_dismiss keys=$(_keys) errs=${(j:|:)ERRS} blocks=${(j:|:)BLOCKS}"
  done
done
print "== follow-up: the SAME capture with a non-shell foreground still refuses (frozen rule) =="
for FG in claude node; do
  _reset shell_stale; PANE_CMD=$FG
  safe_send_keys "%t" "x"; rc=$?
  { (( rc != 0 )) && ! _has_enter && [[ "$(_keys)" != *PASTE* ]] && (( ${#ERRS[@]} >= 1 )); } && ok "[fg=$FG] safe_send_keys refuses (no Enter, no paste, logged)" || no "[fg=$FG] safe_send_keys rc=$rc keys=$(_keys) errs=${#ERRS[@]}"
  _reset shell_stale; PANE_CMD=$FG
  auto_dismiss_prompts "%t"
  { ! _has_enter && (( ${#BLOCKS[@]} >= 1 )); } && ok "[fg=$FG] auto_dismiss_prompts blocks (no Enter)" || no "[fg=$FG] auto_dismiss keys=$(_keys) blocks=${#BLOCKS[@]}"
  _reset shell_stale; PANE_CMD=$FG
  wait_for_pane_ready "%t" 1
  { ! _has_enter && (( ${#ERRS[@]} >= 1 )); } && ok "[fg=$FG] wait_for_pane_ready (shell mode) refuses (no Enter, logged)" || no "[fg=$FG] wait shell keys=$(_keys) errs=${#ERRS[@]}"
done

print ""
print "w1_prompt_binding: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
