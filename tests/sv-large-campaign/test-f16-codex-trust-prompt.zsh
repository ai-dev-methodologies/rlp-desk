#!/bin/zsh
# ============================================================================
# F-16 regression: codex 0.141 shows a "Do you trust the contents of this
# directory? 1. Yes, continue / 2. No, quit" prompt at startup. The leader's
# ready-detection must classify it as ACCEPT-TRUST (send Enter = default
# "1. Yes, continue") and NEVER as the ready input box — even though the menu
# renders '›'. Otherwise the worker instruction lands in the menu, can select
# "No, quit", and codex exits → "worker not active" BLOCK.
#
# Mirrors the detection predicates + ordering in launch_worker_codex /
# launch_verifier_codex. (End-to-end behavior — codex then runs the task — was
# validated live; this locks the classification/ordering.)
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

is_update(){ print -r -- "$1" | grep -qiE 'Update available|1\. Update now'; }
is_trust(){  print -r -- "$1" | grep -qiE 'Do you trust|1\. Yes, continue'; }
is_ready(){  print -r -- "$1" | grep -q '›'; }
# runner ordering: update→skip, THEN trust→accept, THEN '›'→ready
classify(){
  if is_update "$1"; then print skip-update
  elif is_trust "$1"; then print accept-trust
  elif is_ready "$1"; then print ready
  else print wait; fi
}

TRUST_PANE='  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection. Trusting the directory allows project-local config, hooks, and exec policies to load.
› 1. Yes, continue
  2. No, quit
  Press enter to continue'

READY_PANE='› Explain this codebase
  gpt-5.5 medium · master · Context 90% left · 69.3K in · 321 out · 5h 100% left'

UPDATE_PANE='✨ Update available! 0.141.0 -> 0.142.0
› 1. Update now
  2. Skip'

WORKING_PANE='• Working (14s · esc to interrupt)
  Added DONE.txt (+1 -0)'

print -P "%F{cyan}F-16 codex directory-trust prompt classification%f"

[[ "$(classify "$TRUST_PANE")" == accept-trust ]] \
  && ok "trust prompt → ACCEPT-TRUST (never mis-read as ready despite the '›' on '1. Yes, continue')" \
  || no "trust misclassified: $(classify "$TRUST_PANE")"

[[ "$(classify "$READY_PANE")" == ready ]] \
  && ok "real input box (status bar, no menu) → READY" \
  || no "ready misclassified: $(classify "$READY_PANE")"

[[ "$(classify "$UPDATE_PANE")" == skip-update ]] \
  && ok "update prompt → SKIP-UPDATE (F-1, still ahead of trust)" \
  || no "update misclassified: $(classify "$UPDATE_PANE")"

[[ "$(classify "$WORKING_PANE")" == wait ]] \
  && ok "working pane → WAIT" || no "working misclassified: $(classify "$WORKING_PANE")"

# the hijack/quit guard: a trust prompt is NEVER classified ready
[[ "$(classify "$TRUST_PANE")" != ready ]] \
  && ok "ordering guard: trust menu + '›' is never READY (prevents the 'No, quit' exit)" \
  || no "ordering broken — instruction would hit the trust menu"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-16 trust prompt: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-16 trust prompt: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
