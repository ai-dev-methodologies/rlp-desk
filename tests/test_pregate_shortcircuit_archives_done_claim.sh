#!/bin/zsh
# ============================================================================
# F1 (r19-sv-s2-s5 §5): a done-claim rejected by the pre-gate (Layer 1 / 1.5 / 2) is
# archived as iter-NNN-done-claim.json (+ iter-NNN-iter-signal.json) BEFORE the
# short-circuit `continue`. The pre-gate `continue` used to return before
# archive_iter_artifacts, so the bounced claim was overwritten by the next Worker and
# no collector could see the RED/GREEN record of the rejected iteration (governance
# promises per-iteration archiving).
#
# Drives the REAL Layer-2 + "resolve the pre-gate decision" block (extracted from
# run_ralph_desk.zsh) inside a loop with the real archive_iter_artifacts, stubbing only
# the replay result: pre-gate L2 replay mismatch -> redispatch.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
SCRIPT_DIR="${0:A:h}"; ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # override only for mutation checks
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

BLOCK=$(awk '/# --- Layer 2: execution_steps replay/{p=1} /# AC1: capture verifier start timestamp/{p=0} p' "$RUN")
[[ -n "$BLOCK" && "$BLOCK" == *"pregate_fail"* && "$BLOCK" == *continue* ]] || { print -u2 "FAIL: pre-gate block not extracted"; exit 1; }
eval "$(awk '/^archive_iter_artifacts\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$LIB")"
[[ "$(whence -w archive_iter_artifacts)" == *function* ]] || { print -u2 "FAIL: archive_iter_artifacts not extracted"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LOGS_DIR="$T/logs"; mkdir -p "$LOGS_DIR" "$T/memos"
DONE_CLAIM_FILE="$T/memos/s-done-claim.json"; VERDICT_FILE="$T/memos/s-verify-verdict.json"; SIGNAL_FILE="$T/memos/s-iter-signal.json"
CLAIM='{"us_id":"US-001","execution_steps":[{"step":"verify_e2e","ac_id":"AC4","command":"python3 -c ...","exit_code":0}]}'

log(){ :; }; log_debug(){ :; }; log_error(){ :; }; update_status(){ :; }
_lifecycle_mark_unlock(){ :; }
run_pregate_replay(){ PREGATE_REPLAY_RAN=1; PREGATE_REPLAY_FAIL=${STUB_REPLAY_FAIL:-1}; PREGATE_REPLAY_STEP="verify_e2e ac=AC4"; PREGATE_REPLAY_CLAIMED=0; PREGATE_REPLAY_ACTUAL=1; }
_pregate_register_fail_replay(){ PREGATE_FAILURES=1; return ${STUB_REGISTER_RC:-0}; }
PREGATE_FAILURES=0; PREGATE_FAIL_CAP=2; signal_us_id=US-001; _pg_deadline=0; _PREGATE_FAIL_US=""

_drive() {  # $1 = iteration; sets REACHED_VERIFIER=1 only if the loop body falls through the block
  REACHED_VERIFIER=0; _pg_short=0; _pg_force=0
  local ITERATION="$1"
  for _once in 1; do
    eval "$BLOCK"
    REACHED_VERIFIER=1
  done
}

print "== L2 replay mismatch -> redispatch =="
print -r -- "$CLAIM" > "$DONE_CLAIM_FILE"; print -r -- '{"status":"verify","us_id":"US-001"}' > "$SIGNAL_FILE"
# R-C (codex review): leader finalization sets SKIP_NEXT_WORKER, so memo cleanup is bypassed and the
# PREVIOUS verifier's PASS verdict is still in memos/ when the pre-gate rejects the new claim.
print -r -- '{"verdict":"pass","us_id":"US-000-stale"}' > "$VERDICT_FILE"
STUB_REPLAY_FAIL=1 STUB_REGISTER_RC=0 _drive 1
(( REACHED_VERIFIER == 0 )) && ok "short-circuit still skips the verifier (decision unchanged)" || no "pre-gate decision changed: verifier reached"
[[ -f "$LOGS_DIR/iter-001-done-claim.json" ]] && [[ "$(cat "$LOGS_DIR/iter-001-done-claim.json")" == "$CLAIM" ]] \
  && ok "iter-001-done-claim.json archived with the ORIGINAL content" || no "rejected done-claim NOT archived (iter-001-done-claim.json missing/changed)"
[[ -f "$LOGS_DIR/iter-001-iter-signal.json" ]] && ok "iter-001-iter-signal.json archived too" || no "iter-signal not archived"
[[ ! -e "$LOGS_DIR/iter-001-verify-verdict.json" ]] && ok "stale pass verdict in memos is NOT archived under the rejected iteration (no verifier ran)" || no "stale pass verdict archived as iter-001-verify-verdict.json for a pre-gate bounce"

# the next Worker overwrites the memo; the archive must keep the first claim
print -r -- '{"us_id":"US-001","execution_steps":[],"note":"second worker"}' > "$DONE_CLAIM_FILE"
[[ "$(cat "$LOGS_DIR/iter-001-done-claim.json")" == "$CLAIM" ]] && ok "archive survives the next Worker overwriting the memo" || no "archive was clobbered"

print "== no pre-gate failure -> verifier round proceeds, nothing archived by the block =="
rm -f "$LOGS_DIR"/iter-*(N); print -r -- "$CLAIM" > "$DONE_CLAIM_FILE"
STUB_REPLAY_FAIL=0 _drive 2
(( REACHED_VERIFIER == 1 )) && ok "pre-gate pass falls through to the verifier (unchanged)" || no "pass path changed"
[[ ! -e "$LOGS_DIR/iter-002-done-claim.json" ]] && ok "pass path leaves archiving to the normal step-7d site (no double archive)" || no "pass path archived early"

print ""; print "pregate_shortcircuit_archives_done_claim: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
