#!/bin/zsh
# ============================================================================
# F5 / codex round 3 R3-A — a picker is detected INDEPENDENTLY of label classification and footer
# placement (zsh parity with the Node isPickerCursorLine / hasPickerInBottomRegion rule).
#
# Frozen rule P4: if a picker exists anywhere in the bottom region and the active-dialog checks do not
# all hold => REFUSE (`unknown`); the inline (y/n) fallback runs only when NO picker exists.
#
# Bug: _bottom_prompt_selection threw away the cursor of an UNNUMBERED label that is not Yes/No, so
#   Do you want to proceed? (y/n)
#   ❯ Destroy workspace
#     Open settings
#   Esc to cancel
#   Status: waiting for input
# had no recognized option block and no trailing footer => `none` => safe_send_keys,
# wait_for_pane_ready (shell mode) and auto_dismiss_prompts took the inline Enter branch (which
# confirms the cursor row "Destroy workspace").
#
# Picker rule: a cursor-marked line (non-empty text) counts as a picker when it is numbered or
# Yes/No-worded, OR a directly adjacent line is aligned to its text column, OR a directly adjacent line is
# also cursor-marked. A lone cursor line (`❯ hello`, an input box) is not a picker.
#
# Drives the REAL functions extracted from run_ralph_desk.zsh against a fake tmux.
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
TMP_LIB=$(mktemp -t f5-picker.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
{
  grep -m1 "^typeset -g _PROMPT_RE=" "$RUN"
  grep -m1 "^typeset -g _AFFORDANCE_RE=" "$RUN"
  grep -m1 "^typeset -g _DEFAULT_NO_RE=" "$RUN"
  grep -m1 "^typeset -g _ACTIVE_TASK_RE=" "$RUN"
  _extract_fn wait_for_pane_ready
  _extract_fn safe_send_keys
  sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d'
} > "$TMP_LIB"
for f in wait_for_pane_ready safe_send_keys auto_dismiss_prompts _bottom_prompt_selection; do
  grep -q "^${f}()" "$TMP_LIB" || { print -u2 "FAIL: $f not extracted"; exit 1; }
done

# --- mocks -------------------------------------------------------------------
typeset -ga KEYS ERRS BLOCKS
typeset -g CAP="" PANE_CMD=claude.exe
sleep() { command sleep 0.01; }
log() { :; }
log_debug() { :; }
log_error() { ERRS+=("$*"); }
write_blocked_sentinel() { BLOCKS+=("$*"); }
_dismiss_codex_update_prompt() { return 1; }
_validate_int_knob() { :; }
check_copy_mode() { return 0; }
paste_to_pane() { KEYS+=("PASTE"); }
tmux() {
  case "$1" in
    capture-pane) print -r -- "$CAP" ;;
    display-message)
      if [[ "$*" == *pane_current_command* ]]; then print -r -- "$PANE_CMD"
      elif [[ "$*" == *pane_width* ]]; then print -r -- 0
      else print -- 0; fi ;;
    send-keys) local key="${@: -1}"; [[ "$key" == "C-m" ]] && key="Enter"; KEYS+=("$key") ;;
  esac
  return 0
}
typeset -gA LAST_AUTO_APPROVE_TS PANE_PROMPT_STUCK_SINCE PANE_DISMISS_FAILED_COUNT PANE_VERIFIER_TRACE_LOGGED
source "$TMP_LIB"

NL=$'\n'
WORKER_PANE="%w"; VERIFIER_PANE="%v"; CONSENSUS_PANE=""
WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; FINAL_VERIFIER_ENGINE=claude; CONSENSUS_MODE=off; CONSENSUS_PARALLEL=0
LOGS_DIR=$(mktemp -d -t f5-logs.XXXXXX); ITERATION=1
trap 'rm -f "$TMP_LIB"; rm -rf "$LOGS_DIR"' EXIT
_reset() { KEYS=(); ERRS=(); BLOCKS=(); LAST_AUTO_APPROVE_TS=(); }
_keys() { print -r -- "${(j:,:)KEYS}"; }
_has_enter() { [[ ",$(_keys)," == *",Enter,"* ]]; }
sel() { _bottom_prompt_selection "$1" ""; }

# --- fixtures ----------------------------------------------------------------
# codex's exact counterexample (non-shell foreground)
CE_FULL="Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}  Open settings${NL}Esc to cancel${NL}Status: waiting for input"
CE_NOSTATUS="Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}  Open settings${NL}Esc to cancel"
CE_BARE="Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}  Open settings"
CE_NUMBERED="Do you want to proceed? (y/n)${NL}❯ 1. Destroy workspace${NL}  2. Open settings${NL}Esc to cancel${NL}Status: waiting for input"
CE_SIB_ABOVE="Do you want to proceed? (y/n)${NL}  Open settings${NL}❯ Destroy workspace"
CE_TWO_CURSORS="Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}❯ Open settings"
CE_BOXED="Do you want to proceed? (y/n)${NL}│ ❯ Destroy workspace   │${NL}│   Open settings       │"
CE_STATUS_ONLY="Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}  Open settings${NL}Status: waiting for input"
INPUT_BOX="Do you want to proceed? (y/n)${NL}❯ hello there"
INPUT_BOX_BLANK="Do you want to proceed? (y/n)${NL}❯ hello there${NL}${NL}  something else"
INPUT_BOX_FAR="Do you want to proceed? (y/n)${NL}❯ hello there${NL}unrelated line${NL}  something else"

# $1=label $2=pane $3=capture : all three Enter-capable call shapes REFUSE (no Enter, per-site refusal)
_assert_refuse() {
  local label="$1" pane="$2"; CAP="$3"
  _reset; safe_send_keys "$pane" "do the thing"; local rc=$?
  { ! _has_enter && [[ "$(_keys)" != *PASTE* ]] && (( rc != 0 )) && (( ${#ERRS[@]} >= 1 )); } \
    && ok "$label safe_send_keys: no Enter, no paste, refused+logged" || no "$label safe_send_keys keys=$(_keys) rc=$rc errs=${#ERRS[@]}"
  _reset; auto_dismiss_prompts "$pane"
  { ! _has_enter && (( ${#BLOCKS[@]} >= 1 && ${#ERRS[@]} >= 1 )); } \
    && ok "$label auto_dismiss_prompts: no Enter, log_error + BLOCKED sentinel" || no "$label auto_dismiss_prompts keys=$(_keys) blocks=${#BLOCKS[@]} errs=${#ERRS[@]}"
  _reset; wait_for_pane_ready "$pane" 1
  { ! _has_enter && (( ${#ERRS[@]} >= 1 )); } \
    && ok "$label wait_for_pane_ready (shell mode): no Enter, refusal logged" || no "$label wait_for_pane_ready keys=$(_keys) errs=${#ERRS[@]}"
}
# $1=label $2=pane $3=capture : inline (y/n) behaviour kept (Enter), no refusal
_assert_inline() {
  local label="$1" pane="$2"; CAP="$3"
  _reset; safe_send_keys "$pane" "do the thing"
  check "$label safe_send_keys: inline Enter before the paste" "Enter,PASTE" "${(j:,:)${(@)KEYS[1,2]}}"
  _reset; auto_dismiss_prompts "$pane"
  { [[ "$(_keys)" == "Enter" ]] && (( ${#BLOCKS[@]} == 0 )); } && ok "$label auto_dismiss_prompts: inline Enter, no BLOCK" || no "$label auto_dismiss_prompts keys=$(_keys) blocks=${#BLOCKS[@]}"
  _reset; wait_for_pane_ready "$pane" 3
  check "$label wait_for_pane_ready (shell mode): inline Enter (first key)" "Enter" "${KEYS[1]:-}"
}

print "== R3-A: pure function — a picker is detected without label classification or a trailing footer =="
check "codex counterexample (footer then status line)" unknown "$(sel "$CE_FULL")"
check "counterexample without the trailing status line" unknown "$(sel "$CE_NOSTATUS")"
check "counterexample with neither footer nor status (bare unnumbered picker)" unknown "$(sel "$CE_BARE")"
check "counterexample with only a status line after the picker" unknown "$(sel "$CE_STATUS_ONLY")"
check "numbered variant" unknown "$(sel "$CE_NUMBERED")"
check "aligned sibling ABOVE the cursor line" unknown "$(sel "$CE_SIB_ABOVE")"
check "two adjacent cursor-marked unnumbered lines (not column-aligned)" unknown "$(sel "$CE_TWO_CURSORS")"
check "picker inside a box border (│ ... │)" unknown "$(sel "$CE_BOXED")"
check "input box: a lone cursor line is not a picker" none "$(sel "$INPUT_BOX")"
check "input box + blank + indented line: a blank line is no sibling" none "$(sel "$INPUT_BOX_BLANK")"
check "input box + unrelated line + indented line: only DIRECT neighbours count" none "$(sel "$INPUT_BOX_FAR")"
check "no cursor anywhere: plain inline prompt" none "$(sel "Do you want to proceed? (y/n)")"

print "== R3-A: claude pane, non-shell foreground — all three call shapes REFUSE =="
PANE_CMD=claude.exe
_assert_refuse "(codex counterexample)" "%w" "$CE_FULL"
_assert_refuse "(numbered variant)" "%w" "$CE_NUMBERED"
_assert_refuse "(no trailing status line)" "%w" "$CE_NOSTATUS"
_assert_refuse "(bare, no footer/status)" "%w" "$CE_BARE"
_assert_refuse "(two adjacent cursor lines)" "%w" "$CE_TWO_CURSORS"
_assert_refuse "(sibling above)" "%w" "$CE_SIB_ABOVE"

print "== R3-A control: an input box \`❯ hello there\` + inline (y/n) keeps today's inline behaviour =="
PANE_CMD=claude.exe
_assert_inline "(input box)" "%w" "$INPUT_BOX"
_assert_inline "(input box + blank + indented line)" "%w" "$INPUT_BOX_BLANK"

print "== R3-A: a codex bash-trigger pane refuses like any non-shell pane =="
WORKER_ENGINE=codex; PANE_CMD=bash
_assert_refuse "(codex worker, bash fg, counterexample)" "%w" "$CE_FULL"
_assert_refuse "(codex worker, bash fg, bare picker)" "%w" "$CE_BARE"
_assert_inline "(codex worker, bash fg, input box)" "%w" "$INPUT_BOX"
WORKER_ENGINE=claude

print "== R3-A: a shell-foreground claude pane stays skipped (stale scrollback is not a live dialog) =="
PANE_CMD=zsh; CAP="$CE_FULL"
_reset; auto_dismiss_prompts "%w"
{ ! _has_enter && (( ${#BLOCKS[@]} == 0 && ${#ERRS[@]} == 0 )); } && ok "shell fg: auto_dismiss_prompts no Enter, no BLOCK, no refusal" || no "shell fg auto_dismiss keys=$(_keys) blocks=${#BLOCKS[@]} errs=${#ERRS[@]}"
_reset; safe_send_keys "%w" "do the thing"; rc=$?
{ [[ "${KEYS[1]:-}" == PASTE ]] && (( rc == 0 && ${#ERRS[@]} == 0 )); } && ok "shell fg: safe_send_keys not refused, pastes with no Enter before it (restart can paste)" || no "shell fg safe_send_keys keys=$(_keys) rc=$rc errs=${#ERRS[@]}"
_reset; wait_for_pane_ready "%w" 1
{ ! _has_enter && (( ${#ERRS[@]} == 0 )); } && ok "shell fg: wait_for_pane_ready no Enter, no refusal" || no "shell fg wait_for_pane_ready keys=$(_keys) errs=${#ERRS[@]}"
PANE_CMD=claude.exe

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
