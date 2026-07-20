#!/bin/zsh
# request-b ③/④ — prompt submission guarantee + submit-anchored timeout,
# plus incidental #2 (BLOCKED exit-code consistency).
#
# Unit-tests the new helpers against mocked pane snapshots and the anchor math,
# then structurally asserts the codex + parallel-consensus pollers use the anchor
# and re-dispatch (rather than a bare task-timeout BLOCK), and that every BLOCKED
# termination stays non-zero while COMPLETE is 0.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" && -f "$LIB" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

# lib helpers are safe to source (lib never runs main).
log(){ :; }; log_error(){ :; }; log_debug(){ :; }
source "$LIB"

# --- _pane_shows_progress: multi-signal predicate, banner/echo tolerant ---
_pane_shows_progress "esc to interrupt"            && ok "progress: 'esc to interrupt' → running" || no "esc to interrupt not detected"
_pane_shows_progress "✻ Crunching (12s)"           && ok "progress: spinner verb → running" || no "spinner not detected"
_pane_shows_progress "1234 in · 20 out"            && ok "progress: nonzero token counter → running" || no "nonzero token counter not detected"
! _pane_shows_progress "0 in · 0 out"              && ok "idle: '0 in · 0 out' → NOT running" || no "'0 in' falsely counted as progress"
! _pane_shows_progress "› Read and execute the instructions in /tmp/p.md" \
  && ok "echoed prompt (contains 'execute'/'in') → NOT running (anchor not polluted)" \
  || no "echoed prompt falsely counted as progress"
! _pane_shows_progress "less than 25% of your weekly limit"  && ok "weekly-limit warning banner → NOT running" || no "warning banner falsely counted"
! _pane_shows_progress "3 usage limit resets available"      && ok "resets-available warning banner → NOT running" || no "resets banner falsely counted"
! _pane_shows_progress ""                          && ok "empty snapshot → NOT running" || no "empty falsely counted"

# --- _submission_deadline_state: anchor math + classification ---
[[ "$(_submission_deadline_state 0 100 150 600 90)" == "pending" ]]            && ok "state: no progress, within submit window → pending" || no "pending wrong"
[[ "$(_submission_deadline_state 0 100 191 600 90)" == "submission_failure" ]] && ok "state: no progress, submit window exceeded → submission_failure" || no "submission_failure wrong"
[[ "$(_submission_deadline_state 100 0 150 600 90)" == "running" ]]            && ok "state: progress seen, within task budget → running" || no "running wrong"
[[ "$(_submission_deadline_state 100 0 701 600 90)" == "task_timeout" ]]       && ok "state: progress seen, task budget exceeded → task_timeout" || no "task_timeout wrong"
# ★ the re-basing proof: dispatch@0, banner delays first progress to @100,
# task budget 60s. At now=140 (40s after progress) it is STILL running — a
# dispatch-anchored clock (140 >= 60) would have falsely timed out here.
[[ "$(_submission_deadline_state 100 0 140 60 90)" == "running" ]] \
  && ok "★ re-based: 140s post-dispatch but 40s post-progress → running (no false timeout)" \
  || no "re-basing failed: banner-delayed submission still times out"
[[ "$(_submission_deadline_state 100 0 161 60 90)" == "task_timeout" ]] \
  && ok "★ re-based: 61s after first progress → task_timeout (budget honored from progress)" \
  || no "task budget not enforced from first progress"

# --- detect_quota_exhausted: strict, tolerant of non-exhaustion warnings (③.3) ---
detect_quota_exhausted "You've hit your usage limit. Try again at 3:00pm." \
  && ok "quota: true exhaustion (hit your usage limit + reset hint) → detected" || no "true exhaustion not detected"
! detect_quota_exhausted "3 usage limit resets available" \
  && ok "quota: 'resets available' warning → NOT exhaustion (resubmission allowed)" || no "warning banner tripped quota abort"
! detect_quota_exhausted "less than 25% of your weekly limit" \
  && ok "quota: weekly-limit warning → NOT exhaustion (resubmission allowed)" || no "weekly warning tripped quota abort"

# --- structural: config + pollers use the anchor + re-dispatch, not bare BLOCK ---
grep -q 'SUBMISSION_TIMEOUT=' "$RUN"        && ok "config: SUBMISSION_TIMEOUT present" || no "SUBMISSION_TIMEOUT missing"
grep -q 'SUBMISSION_MAX_REDISPATCH=' "$RUN" && ok "config: SUBMISSION_MAX_REDISPATCH present" || no "SUBMISSION_MAX_REDISPATCH missing"

# codex verifier poll uses the anchor + classifier
cx=$(awk '/Polling for verify-verdict.json \(\$suffix, codex TUI\)/,/^  else$/' "$RUN")
print -r -- "$cx" | grep -q '_first_progress_ts' \
  && ok "codex poll: records first_progress_ts anchor" || no "codex poll missing first_progress_ts"
print -r -- "$cx" | grep -q '_submission_deadline_state' \
  && ok "codex poll: drives the deadline via _submission_deadline_state" || no "codex poll not anchored"
print -r -- "$cx" | grep -q 'submission_failure)' \
  && print -r -- "$cx" | grep -q 'launch_verifier_codex "\$VERIFIER_PANE"' \
  && ok "codex poll: submission_failure re-dispatches (not a bare BLOCK)" || no "codex poll missing re-dispatch"

# parallel consensus poll (the field-BLOCK site) uses per-side start + re-dispatch
pp=$(awk '/Poll BOTH verdict files until both present/,/Reap both panes/' "$RUN")
print -r -- "$pp" | grep -q '_both_started_ts' \
  && ok "parallel poll: task deadline anchored at _both_started_ts" || no "parallel poll not anchored"
print -r -- "$pp" | grep -q '_pane_shows_progress' \
  && ok "parallel poll: per-side progress detection" || no "parallel poll missing progress detection"
print -r -- "$pp" | grep -qE 'never started .*submission failure' \
  && ok "parallel poll: exhausted re-dispatch → submission failure (bounded)" || no "parallel poll missing bounded re-dispatch"
# The old dispatch-anchored 'infrastructure failure within ITER_TIMEOUT' BLOCK is gone.
! print -r -- "$pp" | grep -q 'did not return a verdict within ${ITER_TIMEOUT}s (claude=' \
  && ok "parallel poll: dispatch-anchored timeout BLOCK removed" || no "old dispatch-anchored BLOCK still present"

# --- incidental #2: BLOCKED exit codes non-zero, COMPLETE zero (BEHAVIORAL) ---
# Execute the REAL terminal-exit block (awk-extracted from run_ralph_desk.zsh at
# test time, so drift fails the test) inside a scratch zsh with a stubbed main
# and controlled sentinel files, asserting the actual process exit codes.
_exit_tail=$(awk '/^main "\$@"/,0' "$RUN")
_run_terminal_exit() {  # $1=main rc  $2=touch complete?  $3=touch blocked?
  local tmp; tmp=$(mktemp -d)
  local rc
  zsh -c "
    COMPLETE_SENTINEL='$tmp/complete'; BLOCKED_SENTINEL='$tmp/blocked'
    [[ '$2' == 1 ]] && touch \"\$COMPLETE_SENTINEL\"
    [[ '$3' == 1 ]] && touch \"\$BLOCKED_SENTINEL\"
    main() { return $1 }
    $_exit_tail
  " >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  return $rc
}
_run_terminal_exit 0 1 0; [[ $? -eq 0 ]] \
  && ok "exit-code behavioral: COMPLETE sentinel → exit 0" || no "COMPLETE did not exit 0"
_run_terminal_exit 0 0 1; [[ $? -ne 0 ]] \
  && ok "exit-code behavioral: BLOCKED sentinel + main rc 0 → non-zero (race pinned)" || no "BLOCKED with rc 0 exited 0"
_run_terminal_exit 1 0 1; [[ $? -eq 1 ]] \
  && ok "exit-code behavioral: BLOCKED sentinel + main rc 1 → 1 preserved" || no "BLOCKED rc not preserved"
_run_terminal_exit 3 0 0; [[ $? -eq 3 ]] \
  && ok "exit-code behavioral: no sentinel → main rc passthrough" || no "rc passthrough broken"
# verify_partial_malformed CB: assert on the CODE (return 1 directly inside the
# CB branch after the blocked-status update), not on a comment string.
_cb_block=$(awk '/verify_partial_malformed repeated/,/^          fi$/' "$RUN")
print -r -- "$_cb_block" | grep -q 'return 1' \
  && ok "exit-code: verify_partial_malformed CB branch returns 1 directly (code assert)" \
  || no "verify_partial_malformed CB branch lacks direct return 1"

# --- seal #4/#7: poll_for_signal is submit-anchored (single source for worker,
# sequential claude verifier, final verifier) ---
_pfs=$(awk '/^poll_for_signal\(\)/,/^}/' "$RUN")
print -r -- "$_pfs" | grep -q '_pfs_first_progress_ts' \
  && ok "poll_for_signal: first-progress anchor present" || no "poll_for_signal missing anchor"
print -r -- "$_pfs" | grep -q '_pane_shows_progress' \
  && ok "poll_for_signal: uses the multi-signal progress predicate" || no "poll_for_signal missing progress predicate"
print -r -- "$_pfs" | grep -q 'SUBMISSION_MAX_REDISPATCH' \
  && ok "poll_for_signal: bounded submission recovery wired" || no "poll_for_signal missing bounded recovery"
! print -r -- "$_pfs" | grep -q 'if (( elapsed >= ITER_TIMEOUT )); then' \
  && ok "poll_for_signal: dispatch-anchored ITER_TIMEOUT check removed" || no "old dispatch-anchored check still present"
# Knob safety (seal #6): garbage env values must fall back to defaults, not
# explode under set -u (BEHAVIORAL — spawn the real config lines via a scratch
# zsh that sources _validate_int_knob and the knob block).
_knob_rc=$(zsh -c "
  set -u
  $(awk '/^_validate_int_knob\(\)/,/^}/' "$RUN")
  log_error(){ :; }
  SUBMISSION_TIMEOUT='bogus'; SUBMISSION_MAX_REDISPATCH='12x'
  SUBMISSION_TIMEOUT=\"\${SUBMISSION_TIMEOUT:-90}\"; SUBMISSION_MAX_REDISPATCH=\"\${SUBMISSION_MAX_REDISPATCH:-2}\"
  _validate_int_knob SUBMISSION_TIMEOUT 90 1
  _validate_int_knob SUBMISSION_MAX_REDISPATCH 2 0
  print \"\$SUBMISSION_TIMEOUT/\$SUBMISSION_MAX_REDISPATCH\"
  (( SUBMISSION_TIMEOUT + SUBMISSION_MAX_REDISPATCH >= 0 )) || exit 9
" 2>/dev/null)
[[ "$_knob_rc" == "90/2" ]] \
  && ok "knobs behavioral: bogus SUBMISSION_* env → validated back to defaults, arithmetic safe" \
  || no "knob validation failed (got '$_knob_rc')"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
