#!/bin/zsh
# ============================================================================
# F-1 regression: codex's "✨ Update available!" launch menu must be detected and
# classified as DISMISS BEFORE the '›' ready check — because the update menu ALSO
# renders '›' (on "› 1. Update now"), so a naive ready check would treat the update
# prompt as "codex ready", send the task, and the Enter would confirm the default
# "Update now" → hijack.
#
# v0.22.21 (incident 2026-07-22): codex 0.145.0 shipped a TWO-option dialog
# ("1. Update now / 2. Skip") whose changed key handling defeated the old Skip
# handler → masqueraded as a verifier submission failure. The durable fix injects
# `-c check_for_update_on_startup=false` at launch (removes the surface), and the
# inline handlers were consolidated into ONE shared dismisser
# (_dismiss_codex_update_prompt) with a single canonical regex (_RLP_CODEX_UPDATE_RE).
#
# This test pins BOTH: (1) classification/ordering against the REAL 0.145.0
# TWO-option banner AND the legacy 0.140 THREE-option banner, using the canonical
# regex extracted from source; (2) the shared dismisser's key strategy against a
# recording tmux stub — attempts 1-2 send Down+Enter (works for 2- and 3-option
# menus), attempt 3+ sends the literal "2" hotkey + Enter.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

# Pin the REAL canonical detector + dismisser from source (no hand-mirrored copy).
eval "$(grep '^_RLP_CODEX_UPDATE_RE=' "$RUN")"
[[ -n "${_RLP_CODEX_UPDATE_RE:-}" ]] || { print -u2 "FAIL: _RLP_CODEX_UPDATE_RE not extracted"; exit 1; }
_dismiss_src=$(awk '/^_dismiss_codex_update_prompt\(\)/,/^\}/' "$RUN")
[[ -n "$_dismiss_src" ]] && print -r -- "$_dismiss_src" | grep -q 'return 0' \
  || { print -u2 "FAIL: _dismiss_codex_update_prompt not extracted (drift?)"; exit 1; }
sleep(){ : ; }   # no-op so the dismisser's inter-key sleeps don't slow the suite
log(){ :; }; log_debug(){ :; }
eval "$_dismiss_src"

# classify mirror using the REAL regex (update check MUST precede the ready check)
is_update_prompt(){ print -r -- "$1" | grep -qiE "$_RLP_CODEX_UPDATE_RE"; }
is_ready(){ print -r -- "$1" | grep -q '›'; }
classify(){
  if is_update_prompt "$1"; then print dismiss
  elif is_ready "$1"; then print ready
  else print wait; fi
}

# REAL 0.145.0 TWO-option update dialog (from the incident: 0.144.6 -> 0.145.0)
UPDATE_PANE_2OPT='  ✨ Update available! 0.144.6 -> 0.145.0
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  Press enter to continue'

# Legacy 0.140 THREE-option dialog (kept as a regression — both must DISMISS)
UPDATE_PANE_3OPT='  ✨ Update available! 0.140.0 -> 0.141.0
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version
  Press enter to continue'

READY_PANE=' /tmp/x  master
❯ codex -m gpt-5.5 ...
╭─── codex ──────────╮
› '

WORKING_PANE='• Working… (12s · ↓ 2.5k tokens)
  reading files'

print -P "%F{cyan}F-1 codex update-prompt dismiss/ordering + key-injection regression%f"

# --- classification / ordering (both banners) ---------------------------------
[[ "$(classify "$UPDATE_PANE_2OPT")" == dismiss ]] \
  && ok "0.145.0 TWO-option update dialog → DISMISS (not mistaken for ready despite '›')" \
  || no "0.145 update prompt misclassified: $(classify "$UPDATE_PANE_2OPT")"

[[ "$(classify "$UPDATE_PANE_3OPT")" == dismiss ]] \
  && ok "0.140 THREE-option update dialog → DISMISS (legacy regression retained)" \
  || no "0.140 update prompt misclassified: $(classify "$UPDATE_PANE_3OPT")"

[[ "$(classify "$READY_PANE")" == ready ]] \
  && ok "genuine codex ready prompt ('›' input, no update banner) → READY" \
  || no "ready prompt misclassified: $(classify "$READY_PANE")"

[[ "$(classify "$WORKING_PANE")" == wait ]] \
  && ok "working/thinking pane → WAIT (neither update nor ready)" \
  || no "working pane misclassified: $(classify "$WORKING_PANE")"

[[ "$(classify "$UPDATE_PANE_2OPT")" != ready ]] \
  && ok "ordering: update banner + '›' is never classified READY (the hijack guard)" \
  || no "ordering broken — update prompt would be treated as ready → hijack"

# --- behavioral: shared dismisser key strategy vs a recording tmux -------------
# drive <fixture> <attempt> → prints "rc=<rc> keys=[<recorded send-keys args>]"
_drive_dismiss() {
  local FIX="$1" ATT="$2" REC=""
  tmux() {
    case "$1" in
      capture-pane) print -r -- "$FIX" ;;
      send-keys) shift; REC+="$* | " ;;
    esac
    return 0
  }
  _dismiss_codex_update_prompt "%1" "$ATT"; local rc=$?
  unfunction tmux
  print -r -- "rc=$rc keys=[$REC]"
}

# attempt 1 on the real 2-option dialog → Down + Enter (no literal "2")
out=$(_drive_dismiss "$UPDATE_PANE_2OPT" 1)
{ [[ "$out" == "rc=0 "* ]] && [[ "$out" == *"Down"* ]] && [[ "$out" == *"C-m"* ]] && [[ "$out" != *" 2 |"* ]] } \
  && ok "attempt 1 (2-option) → Down + Enter, no literal '2' ($out)" \
  || no "attempt 1 key strategy wrong ($out)"

# attempt 2 → still Down + Enter
out=$(_drive_dismiss "$UPDATE_PANE_2OPT" 2)
{ [[ "$out" == "rc=0 "* ]] && [[ "$out" == *"Down"* ]] && [[ "$out" != *" 2 |"* ]] } \
  && ok "attempt 2 → Down + Enter (menu-agnostic) ($out)" \
  || no "attempt 2 key strategy wrong ($out)"

# attempt 3 → literal "2" hotkey + Enter fallback (no Down)
out=$(_drive_dismiss "$UPDATE_PANE_2OPT" 3)
{ [[ "$out" == "rc=0 "* ]] && [[ "$out" == *" 2 |"* ]] && [[ "$out" == *"C-m"* ]] && [[ "$out" != *"Down"* ]] } \
  && ok "attempt 3 → literal '2' hotkey + Enter fallback, no Down ($out)" \
  || no "attempt 3 fallback key strategy wrong ($out)"

# attempt 3 also works on the 3-option dialog
out=$(_drive_dismiss "$UPDATE_PANE_3OPT" 3)
{ [[ "$out" == "rc=0 "* ]] && [[ "$out" == *" 2 |"* ]] } \
  && ok "attempt 3 (3-option) → literal '2' hotkey fallback ($out)" \
  || no "attempt 3 (3-option) wrong ($out)"

# no dialog present → rc=1, NO keys sent (caller proceeds to its own checks)
out=$(_drive_dismiss "$READY_PANE" 1)
{ [[ "$out" == "rc=1 keys=[]" ]] } \
  && ok "no dialog present → rc=1, zero keystrokes (caller proceeds)" \
  || no "false-positive dismissal on a ready pane ($out)"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-1 update dismiss: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-1 update dismiss: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
