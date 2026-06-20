#!/bin/zsh
# ============================================================================
# F-1 regression: codex's "✨ Update available!" launch menu must be detected and
# classified as DISMISS (select "2. Skip") BEFORE the '›' ready check — because
# the update menu ALSO renders '›' (on "› 1. Update now"), so a naive ready check
# would treat the update prompt as "codex ready", send the task, and the Enter
# would confirm the default "Update now" → hijack.
#
# This deterministically verifies the detection predicate + ordering used in
# launch_worker_codex / launch_verifier_codex. NOTE: true end-to-end verification
# (actually sending Down+Enter to a live prompt and confirming codex proceeds)
# still awaits the next codex release — codex auto-updated 0.140→0.141, so no
# update prompt currently appears. Detection/ordering logic is verified here.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

# mirror of the runner predicates (update check MUST precede ready check)
is_update_prompt(){ print -r -- "$1" | grep -qiE 'Update available|1\. Update now'; }
is_ready(){ print -r -- "$1" | grep -q '›'; }
classify(){
  if is_update_prompt "$1"; then print dismiss
  elif is_ready "$1"; then print ready
  else print wait; fi
}

# the REAL captured update prompt (from the methodology workflow C1 smoke)
UPDATE_PANE='  ✨ Update available! 0.140.0 -> 0.141.0
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

print -P "%F{cyan}F-1 codex update-prompt dismiss/ordering regression%f"

[[ "$(classify "$UPDATE_PANE")" == dismiss ]] \
  && ok "real update prompt → DISMISS (not mistaken for ready despite the '›' on '1. Update now')" \
  || no "update prompt misclassified: $(classify "$UPDATE_PANE")"

[[ "$(classify "$READY_PANE")" == ready ]] \
  && ok "genuine codex ready prompt ('›' input, no update banner) → READY" \
  || no "ready prompt misclassified: $(classify "$READY_PANE")"

[[ "$(classify "$WORKING_PANE")" == wait ]] \
  && ok "working/thinking pane → WAIT (neither update nor ready)" \
  || no "working pane misclassified: $(classify "$WORKING_PANE")"

# precedence: a pane with BOTH the update banner AND '›' must be DISMISS, never READY
[[ "$(classify "$UPDATE_PANE")" != ready ]] \
  && ok "ordering: update banner + '›' is never classified READY (the hijack guard)" \
  || no "ordering broken — update prompt would be treated as ready → hijack"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-1 update dismiss: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-1 update dismiss: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
