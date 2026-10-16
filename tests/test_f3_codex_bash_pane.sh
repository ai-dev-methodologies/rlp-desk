#!/bin/zsh
# ============================================================================
# F3 / F1-RISK — the shell-skip of the prompt handling is ENGINE-AWARE.
#
# F1 follow-up: a pane whose foreground command is a shell (zsh|bash|sh|fish) cannot be showing a
# claude dialog, so stale scrollback there neither gets Enter nor blocks a restart (_pane_fg_is_shell).
# But a codex worker/verifier runs under `bash` (the trigger script / codex launch: check_dead_pane —
# "bash is normal for codex workers, dead for claude"). For such a pane `bash` is NOT "no live dialog":
# the skip emptied auto_dismiss_prompts' capture and turned off the Enter / refusal logic of
# safe_send_keys and wait_for_pane_ready, so a live inline [Y/n] prompt or update dialog of a codex pane
# would never be answered (regression vs the pre-sweep behaviour).
#
# Contract under test:
#   * a pane that may host codex (WORKER_PANE with WORKER_ENGINE=codex; VERIFIER_PANE with
#     VERIFIER_ENGINE or FINAL_VERIFIER_ENGINE = codex, or sequential consensus; CONSENSUS_PANE always)
#     whose foreground is `bash` keeps FULL prompt handling — identical to the same pane with a non-shell
#     foreground, i.e. identical to the behaviour before the shell-skip existed;
#   * claude panes whose claude process is gone (bash/zsh/sh/fish foreground), plain `zsh` in any pane
#     (check_dead_pane: bare zsh is dead for every engine), and panes that are not a campaign pane keep
#     the F1 follow-up skip.
#
# Drives the REAL functions extracted from run_ralph_desk.zsh against a fake tmux.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
zmodload zsh/datetime

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # override only for mutation / baseline checks
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"; }

_extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RUN"; }
TMP_LIB=$(mktemp -t f3-codex-bash.XXXXXX)
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
typeset -ga KEYS ERRS BLOCKS UPD
typeset -g CAP="" PANE_CMD=bash
sleep() { command sleep 0.01; }
log() { :; }
log_debug() { :; }
log_error() { ERRS+=("$*"); }
write_blocked_sentinel() { BLOCKS+=("$*"); }
_dismiss_codex_update_prompt() { UPD+=("$1"); return 1; }
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
_cfg() { WORKER_ENGINE=${1:-claude}; VERIFIER_ENGINE=${2:-claude}; FINAL_VERIFIER_ENGINE=${3:-claude}; CONSENSUS_MODE=${4:-off}; CONSENSUS_PARALLEL=${5:-0}; }
_reset() { KEYS=(); ERRS=(); BLOCKS=(); UPD=(); LAST_AUTO_APPROVE_TS=(); }
_keys() { print -r -- "${(j:,:)KEYS}"; }

# captures a codex pane can legitimately show
INLINE_YN="● codex wants to run a command${NL}Do you want to create notes.txt? [Y/n]"
INLINE_DEFAULT_NO="● codex wants to run a command${NL}Do you want to delete notes.txt? [y/N]"
UPDATE_DLG="  ✨ Update available! 0.150.0 -> 0.151.0${NL}${NL}› 1. Update now${NL}  2. Skip${NL}${NL}  Press enter to continue"
STALE_PICKER="Do you want to create old.txt?${NL}❯ 1. Yes${NL}  2. No${NL}Esc to cancel${NL}kyjin@host rlp-desk % "

# $1=label $2=pane $3=expected: full|skip   (CAP / PANE_CMD / engines are set by the caller)
_shapes() {
  local label="$1" pane="$2" want="$3" rc
  _reset; safe_send_keys "$pane" "do the thing"; rc=$?
  local sk_keys="${(j:,:)${(@)KEYS[1,2]}}" sk_rc=$rc sk_errs=${#ERRS[@]}
  _reset; auto_dismiss_prompts "$pane"
  local ad_keys="$(_keys)" ad_blocks=${#BLOCKS[@]} ad_errs=${#ERRS[@]}
  _reset; wait_for_pane_ready "$pane" 1; rc=$?
  local wp_keys="${KEYS[1]:-}" wp_rc=$rc wp_errs=${#ERRS[@]}   # first key only: the number of Enters in a 1s wait is timing-dependent
  print -r -- "$sk_keys|$sk_rc|$sk_errs|$ad_keys|$ad_blocks|$ad_errs|$wp_keys|$wp_rc|$wp_errs"
}

print "== a codex pane (WORKER_ENGINE=codex) with a bash foreground keeps FULL prompt handling =="
_cfg codex claude claude
CAP="$INLINE_YN"; PANE_CMD=bash
_reset; auto_dismiss_prompts %w
check "codex worker, bash fg, inline [Y/n]: auto_dismiss_prompts presses Enter" "Enter" "$(_keys)"
(( ${#BLOCKS[@]} == 0 )) && ok "codex worker, bash fg, inline [Y/n]: no BLOCKED sentinel" || no "unexpected BLOCKED: ${(j:|:)BLOCKS}"
_reset; safe_send_keys %w "do the thing"
check "codex worker, bash fg, inline [Y/n]: safe_send_keys answers (Enter) before the paste" "Enter,PASTE" "${(j:,:)${(@)KEYS[1,2]}}"
_reset; wait_for_pane_ready %w 3
check "codex worker, bash fg, inline [Y/n]: wait_for_pane_ready (shell mode) approves it (first key)" "Enter" "${KEYS[1]:-}"

CAP="$INLINE_DEFAULT_NO"; PANE_CMD=bash
_reset; auto_dismiss_prompts %w
{ [[ -z "$(_keys)" ]] && (( ${#BLOCKS[@]} == 1 )); } && ok "codex worker, bash fg, inline [y/N] (default No): BLOCKED, no Enter" || no "default-No: keys=$(_keys) blocks=${#BLOCKS[@]}"

CAP="$UPDATE_DLG"; PANE_CMD=bash
_reset; auto_dismiss_prompts %w
{ [[ -z "$(_keys)" ]] && (( ${#BLOCKS[@]} == 0 )); } && ok "codex worker, bash fg, update dialog: auto_dismiss_prompts sends no blind Enter (the update dismisser owns it)" || no "update dialog: keys=$(_keys) blocks=${#BLOCKS[@]}"
_reset; safe_send_keys %w "do the thing"; rc=$?
{ (( rc != 0 )) && [[ "$(_keys)" != *PASTE* ]]; } && ok "codex worker, bash fg, update dialog (confirm footer at the bottom): safe_send_keys refuses, nothing is pasted into it" || no "update dialog safe_send_keys rc=$rc keys=$(_keys)"
_reset; wait_for_pane_ready %w 1
(( ${#UPD[@]} >= 1 )) && ok "codex worker, bash fg, update dialog: wait_for_pane_ready consults the codex update dismisser" || no "update dismisser never consulted"

print "== every codex-capable pane: bash foreground == non-shell foreground (full handling) =="
_equiv() { # $1=label $2=pane $3=capture
  local a b
  CAP="$3"; PANE_CMD=bash;  a=$(_shapes "$1" "$2" full)
  CAP="$3"; PANE_CMD=codex; b=$(_shapes "$1" "$2" full)
  [[ "$a" == "$b" ]] && ok "$1: bash fg handled exactly like a live codex foreground ($a)" || no "$1: bash fg '$a' != codex fg '$b'"
}
for CAPN in INLINE_YN INLINE_DEFAULT_NO UPDATE_DLG STALE_PICKER; do
  _cfg codex claude claude;               _equiv "worker pane, WORKER_ENGINE=codex, $CAPN" %w "${(P)CAPN}"
  _cfg claude codex claude;               _equiv "verifier pane, VERIFIER_ENGINE=codex, $CAPN" %v "${(P)CAPN}"
  _cfg claude claude codex;               _equiv "verifier pane, FINAL_VERIFIER_ENGINE=codex, $CAPN" %v "${(P)CAPN}"
  _cfg claude claude claude all 0;        _equiv "verifier pane, sequential consensus (codex verifies on it), $CAPN" %v "${(P)CAPN}"
  CONSENSUS_PANE="%c"; _cfg claude claude claude all 1; _equiv "consensus pane (codex cross-verifier), $CAPN" %c "${(P)CAPN}"; CONSENSUS_PANE=""
done

print "== the F1 follow-up skip still applies where the pane cannot be a codex pane =="
_skip_case() { # $1=label $2=pane $3=fg ; capture = a stale picker above a shell prompt
  CAP="$STALE_PICKER"; PANE_CMD="$3"
  _reset; auto_dismiss_prompts "$2"
  { [[ -z "$(_keys)" ]] && (( ${#BLOCKS[@]} == 0 && ${#ERRS[@]} == 0 )); } && ok "$1: auto_dismiss_prompts skips (no Enter, no BLOCK, no refusal)" || no "$1: auto_dismiss keys=$(_keys) blocks=${#BLOCKS[@]} errs=${#ERRS[@]}"
  _reset; safe_send_keys "$2" "do the thing"; rc=$?
  { (( rc == 0 )) && [[ "${KEYS[1]:-}" == PASTE ]] && (( ${#ERRS[@]} == 0 )); } && ok "$1: safe_send_keys pastes at once (no Enter before it, no refusal)" || no "$1: safe_send_keys rc=$rc keys=$(_keys) errs=${#ERRS[@]}"
  _reset; wait_for_pane_ready "$2" 3; rc=$?
  { (( rc == 0 )) && [[ -z "$(_keys)" ]] && (( ${#ERRS[@]} == 0 )); } && ok "$1: wait_for_pane_ready ready at once, no Enter, no refusal" || no "$1: wait rc=$rc keys=$(_keys) errs=${#ERRS[@]}"
}
_cfg claude claude claude
for FG in bash zsh sh fish; do
  _skip_case "claude worker pane, claude gone, fg=$FG" %w $FG
  _skip_case "claude verifier pane, claude gone, fg=$FG" %v $FG
done
_cfg codex codex codex all 0
_skip_case "codex worker pane with a bare zsh (check_dead_pane: bare zsh is dead for codex too)" %w zsh
_skip_case "codex verifier pane with a bare zsh" %v zsh
_cfg codex codex codex
_skip_case "a pane that is not a campaign pane (leader / user pane), fg=bash" %x bash
_cfg claude codex claude
_skip_case "mixed engines: the CLAUDE worker pane, fg=bash" %w bash
_cfg codex claude claude all 1
_skip_case "mixed engines: the CLAUDE verifier pane (parallel consensus keeps claude there), fg=bash" %v bash

print "== mixed engines: only the codex pane keeps handling =="
_cfg claude codex claude
CAP="$INLINE_YN"; PANE_CMD=bash
_reset; auto_dismiss_prompts %v
check "verifier pane (codex), bash fg, inline [Y/n]: Enter" "Enter" "$(_keys)"
_reset; auto_dismiss_prompts %w
check "worker pane (claude), bash fg, the same capture: skipped" "" "$(_keys)"

print ""
print "f3_codex_bash_pane: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
