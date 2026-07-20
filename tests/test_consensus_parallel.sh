#!/usr/bin/env zsh
# Feature 2: parallel consensus verification — behavioral tests.
#
# Exercises the REAL functions with fixtures/mocks:
#   - _evidence_lock (LIB): mkdir-atomic mutex — second acquire waits/timeouts
#     while the first holds it, then succeeds after release (AC-C3 interference).
#   - _emit_evidence_lock_contract (LIB): single-source lock contract text (AC-C3).
#   - _consensus_finalize (RUN, shared): NO ENGINE PRIORITY merge — both pass →
#     pass; any fail → fail verdict + fix contract (AC-C2 merge semantics).
#   - run_consensus_verification_parallel (RUN): both dispatched before polling
#     (AC-C2), one-verdict-missing → infrastructure failure (AC-C4).
# Structural asserts confirm the flag gate + that the evidence lock is injected
# into BOTH parallel prompts and only in parallel (AC-C1/AC-C3).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
print -r -- "-- _evidence_lock: mkdir-atomic mutex, waits then acquires after release (AC-C3)"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  LOCK="'"$TMP"'/ev.lock"
  _evidence_lock acquire "$LOCK" 5; print "first=$?"
  # second acquire while held, wait 2s → must time out (blocked)
  _evidence_lock acquire "$LOCK" 2; print "held=$?"
  _evidence_lock release "$LOCK"; print "released=$?"
  _evidence_lock acquire "$LOCK" 2; print "after=$?"
')
[[ "$out" == *"first=0"* ]] && ok "first acquire succeeds" || no "first acquire failed ($out)"
[[ "$out" == *"held=1"* ]]  && ok "second acquire blocks/times out while held" || no "held should be 1 ($out)"
[[ "$out" == *"after=0"* ]] && ok "acquire succeeds after release" || no "post-release acquire failed ($out)"

# ---------------------------------------------------------------------------
print -r -- "-- _emit_evidence_lock_contract: single-source contract text (AC-C3)"
out=$(zsh --no-rcs -c 'source "'"$LIB"'" 2>/dev/null; _emit_evidence_lock_contract "/x/evidence.lock"')
[[ "$out" == *"EVIDENCE ISOLATION"* ]] && ok "contract has EVIDENCE ISOLATION header" || no "header missing"
[[ "$out" == *"/x/evidence.lock"* ]] && ok "contract embeds the lock path" || no "lock path missing"
[[ "$out" == *"mkdir"* && "$out" == *"rmdir"* ]] && ok "contract gives mkdir/rmdir acquire+release" || no "lock ops missing"

# ---------------------------------------------------------------------------
print -r -- "-- _consensus_finalize: NO ENGINE PRIORITY merge (AC-C2)"
# Extract shared merge helper from RUN, source it with atomic_write from LIB.
finalize_body=$(sed -n '/^_consensus_finalize() {$/,/^}$/p' "$RUN")
[[ -n "$finalize_body" ]] && ok "_consensus_finalize extractable" || no "could not extract _consensus_finalize"

cf() { # $1=claude_verdict $2=codex_verdict  → prints "RC=<rc> V=<merged verdict>"
  local cv="$1" xv="$2"
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    '"$finalize_body"'
    LOGS_DIR="'"$TMP"'/cf"; mkdir -p "$LOGS_DIR"
    VERDICT_FILE="$LOGS_DIR/verdict.json"
    CONSENSUS_ROUND=1; CLAUDE_VERDICT="'"$cv"'"; CODEX_VERDICT="'"$xv"'"
    cf="$LOGS_DIR/iter-005.verify-verdict-claude.json"
    xf="$LOGS_DIR/iter-005.verify-verdict-codex.json"
    print -r -- "{\"verdict\":\"'"$cv"'\",\"issues\":[{\"severity\":\"high\",\"criterion\":\"AC1\",\"description\":\"c\"}]}" > "$cf"
    print -r -- "{\"verdict\":\"'"$xv"'\",\"issues\":[{\"severity\":\"high\",\"criterion\":\"AC1\",\"description\":\"x\"}]}" > "$xf"
    _consensus_finalize 5 US-001 "$cf" "$xf"; rc=$?
    print "RC=$rc V=$(jq -r .verdict "$VERDICT_FILE")"
  '
}
[[ "$(cf pass pass)" == *"RC=0 V=pass"* ]] && ok "both pass → verdict pass, return 0" || no "both-pass wrong ($(cf pass pass))"
[[ "$(cf pass fail)" == *"RC=2 V=fail"* ]] && ok "claude pass + codex fail → fail, return 2 (NO PRIORITY)" || no "pass+fail wrong ($(cf pass fail))"
[[ "$(cf fail pass)" == *"RC=2 V=fail"* ]] && ok "claude fail + codex pass → fail, return 2 (symmetry)" || no "fail+pass wrong ($(cf fail pass))"

# ---------------------------------------------------------------------------
print -r -- "-- run_consensus_verification_parallel: dispatch order + one-missing infra fail (AC-C2/AC-C4)"
par_body=$(sed -n '/^run_consensus_verification_parallel() {$/,/^}$/p' "$RUN")
[[ -n "$par_body" ]] && ok "run_consensus_verification_parallel extractable" || no "could not extract parallel fn"

# Common mock preamble: stub every external the parallel fn touches. The launch
# mocks write the per-engine verdict files (simulating the verifiers) — the real
# fn rm -f's stale verdicts before dispatch, so the verdicts MUST be produced by
# the (mock) launch, not pre-seeded. VERDICT_TAG controls what each writes; an
# empty tag means "produce no verdict" (used for the one-missing AC-C4 case).
mocks='
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  DISPATCH="'"$TMP"'/dispatch.log"; : > "$DISPATCH"
  _ensure_consensus_pane(){ CONSENSUS_PANE="%99"; return 0; }
  build_claude_cmd(){ print "claude-cmd"; }
  wait_for_pane_ready(){ return 0; }
  write_verifier_trigger(){ :; }
  detect_quota_exhausted(){ return 1; }
  _kill_pane_process(){ :; }
  tmux(){ return 0; }
  _verify_pane_alive(){ return 0; }   # IMP-02 C0: real helper reads tmux(){return 0} stdout="" → would look DEAD; stub alive so existing cases keep passing

  launch_verifier_claude(){ print "claude" >> "$DISPATCH"; [[ -n "$CLAUDE_TAG" ]] && print -r -- "{\"verdict\":\"$CLAUDE_TAG\"}" > "$claude_verdict_file"; return 0; }
  launch_verifier_codex(){ print "codex" >> "$DISPATCH"; [[ -n "$CODEX_TAG" ]] && print -r -- "{\"verdict\":\"$CODEX_TAG\"}" > "$codex_verdict_file"; return 0; }
  VERIFIER_PANE="%1"; CONSENSUS_PANE=""
  VERIFIER_MODEL=sonnet; FINAL_VERIFIER_MODEL=opus; VERIFIER_EFFORT=""; FINAL_VERIFIER_EFFORT=""
  CONSENSUS_MODEL="gpt:medium"; FINAL_CONSENSUS_MODEL="gpt:high"
  VERIFIER_CODEX_MODEL=gpt; VERIFIER_CODEX_REASONING=medium; CODEX_BIN=echo
  VERIFIER_HEARTBEAT="'"$TMP"'/vhb"; CONSENSUS_HEARTBEAT="'"$TMP"'/chb"
  CONSENSUS_EVIDENCE_LOCK="'"$TMP"'/ev2.lock"; POLL_INTERVAL=1
'

# AC-C2: both verifiers produce verdicts → both engines dispatched, claude before
# codex, both dispatched before polling resolves, return 0 (consensus pass).
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  ITER_TIMEOUT=10; CLAUDE_TAG=pass; CODEX_TAG=pass
  LOGS_DIR="'"$TMP"'/p2"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 7 US-001; rc=$?
  print "RC=$rc"
  print "DISPATCH=$(tr "\n" "," < "$DISPATCH")"
')
[[ "$out" == *"RC=0"* ]] && ok "both verdicts present → return 0 (consensus pass)" || no "parallel both-pass wrong ($out)"
[[ "$out" == *"DISPATCH=claude,codex,"* ]] && ok "both engines dispatched (claude then codex) BEFORE polling" || no "dispatch order/both wrong ($out)"

# IMP-01: verdict-phrasing variants at the parallel read sites (2-3) — a verifier
# emitting "PASS" / "Pass " (trailing space) must NOT diverge from lowercase
# "pass". _normalize_verdict wraps the reads; both engines resolve to pass →
# merged VERDICT_FILE verdict == pass, RC=0.
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  ITER_TIMEOUT=10; CLAUDE_TAG=PASS; CODEX_TAG="Pass "
  LOGS_DIR="'"$TMP"'/p2b"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 7 US-001; rc=$?
  print "RC=$rc V=$(jq -r .verdict "$VERDICT_FILE" 2>/dev/null)"
')
[[ "$out" == *"RC=0 V=pass"* ]] && ok "phrasing variants (PASS / 'Pass ') → merged verdict pass, RC=0 (IMP-01)" || no "IMP-01 parallel variant wrong ($out)"

# AC-C4: only claude verdict arrives → return 1 (caller maps to infra_failure
# BLOCKED). request-b ④ split this into two classifications by the submit anchor:
#   (a) codex STARTED (showed progress) but produced no verdict → task timeout
#       measured from _both_started_ts (not dispatch).
#   (b) codex NEVER started (no progress signal) → submission failure after the
#       bounded re-dispatches.
# Both return 1; the abort reason differs. The config vars live in run_ralph_desk
# (not the sourced slice) so the mock sets them explicitly.

# (a) started-but-silent → timeout. Force progress true so both sides are
# "started"; codex never writes a verdict → deadline (from first progress) fires.
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  _pane_shows_progress(){ return 0; }   # both panes look "running"
  ITER_TIMEOUT=2; SUBMISSION_TIMEOUT=60; SUBMISSION_MAX_REDISPATCH=2
  CLAUDE_TAG=pass; CODEX_TAG=
  LOGS_DIR="'"$TMP"'/p4a"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 8 US-001; rc=$?
  print "RC=$rc REASON=$VERIFIER_ABORT_REASON"
')
[[ "$out" == *"RC=1"* ]] && ok "started-but-silent codex → return 1 (caller → infra_failure)" || no "started-silent rc wrong ($out)"
[[ "$out" == *"after both started"* ]] && ok "abort reason: task timeout anchored at both-started (AC-C4a)" || no "timeout reason missing ($out)"

# (b) never-started → submission failure (bounded re-dispatch). No progress ever.
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  _pane_shows_progress(){ return 1; }   # neither pane ever "starts"
  ITER_TIMEOUT=60; SUBMISSION_TIMEOUT=1; SUBMISSION_MAX_REDISPATCH=1
  CLAUDE_TAG=pass; CODEX_TAG=
  LOGS_DIR="'"$TMP"'/p4b"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 8 US-001; rc=$?
  print "RC=$rc REASON=$VERIFIER_ABORT_REASON"
')
[[ "$out" == *"RC=1"* ]] && ok "never-started codex → return 1 (caller → infra_failure)" || no "never-started rc wrong ($out)"
[[ "$out" == *"submission failure"* ]] && ok "abort reason: bounded re-dispatch → submission failure (AC-C4b)" || no "submission-failure reason missing ($out)"

# ---------------------------------------------------------------------------
# IMP-02: scoped mid-round pane liveness. A pane that dies while its verdict is
# unresolved is classified as a pane-death infra_failure within ~2 poll ticks —
# NOT after the submit-anchored task budget / re-dispatch windows with a
# misattributed reason. %99 = mocked consensus pane, %1 = mocked verifier pane.
print -r -- "-- IMP-02 C1: mid-round consensus (codex) pane death → fast, correctly-attributed abort"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  _pane_shows_progress(){ return 0; }               # both sides "started"
  _verify_pane_alive(){ [[ "$1" == "%99" ]] && return 1; return 0; }  # consensus pane dead
  ITER_TIMEOUT=60; SUBMISSION_TIMEOUT=60; SUBMISSION_MAX_REDISPATCH=2
  CLAUDE_TAG=pass; CODEX_TAG=                        # codex never writes a verdict
  LOGS_DIR="'"$TMP"'/p_c1"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 9 US-001; rc=$?
  print "RC=$rc REASON=$VERIFIER_ABORT_REASON"
')
[[ "$out" == *"RC=1"* ]] && ok "consensus pane death → return 1 (caller → infra_failure)" || no "C1 rc wrong ($out)"
[[ "$out" == *"consensus pane died mid-round"* ]] && ok "abort reason names the consensus pane death" || no "C1 reason wrong ($out)"
[[ "$out" != *"after both started"* ]] && ok "beat the ITER_TIMEOUT budget (not a misattributed timeout)" || no "C1 misattributed as timeout ($out)"

print -r -- "-- IMP-02 C2: mid-round claude verifier pane death (symmetry)"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  _pane_shows_progress(){ return 0; }
  _verify_pane_alive(){ [[ "$1" == "%1" ]] && return 1; return 0; }  # verifier pane dead
  ITER_TIMEOUT=60; SUBMISSION_TIMEOUT=60; SUBMISSION_MAX_REDISPATCH=2
  CLAUDE_TAG=; CODEX_TAG=pass                        # claude never writes a verdict
  LOGS_DIR="'"$TMP"'/p_c2"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 10 US-001; rc=$?
  print "RC=$rc REASON=$VERIFIER_ABORT_REASON"
')
[[ "$out" == *"RC=1"* ]] && ok "claude verifier pane death → return 1" || no "C2 rc wrong ($out)"
[[ "$out" == *"claude verifier pane died"* ]] && ok "abort reason names the claude verifier pane death" || no "C2 reason wrong ($out)"

print -r -- "-- IMP-02 C3: resolved-side immunity — a pane that dies AFTER its verdict landed never aborts"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$finalize_body"'
  '"$par_body"'
  '"$mocks"'
  _pane_shows_progress(){ return 0; }
  _verify_pane_alive(){ return 1; }                 # EVERYTHING looks dead
  ITER_TIMEOUT=60; SUBMISSION_TIMEOUT=60; SUBMISSION_MAX_REDISPATCH=2
  CLAUDE_TAG=pass; CODEX_TAG=pass                    # both verdicts land on tick 1
  LOGS_DIR="'"$TMP"'/p_c3"; mkdir -p "$LOGS_DIR"
  VERDICT_FILE="$LOGS_DIR/verdict.json"
  run_consensus_verification_parallel 11 US-001; rc=$?
  print "RC=$rc REASON=$VERIFIER_ABORT_REASON"
')
[[ "$out" == *"RC=0"* ]] && ok "both verdicts present → return 0 despite dead-looking panes (liveness scoped to unresolved side)" || no "C3 rc wrong ($out)"

# IMP-02 cleanup() teardown of the 4th pane. Extract the real cleanup() body, run
# it with a RECORDING tmux mock, and assert the consensus pane is reaped.
print -r -- "-- IMP-02 C4: cleanup() reaps the 4th (consensus) pane"
cleanup_body=$(sed -n '/^cleanup() {$/,/^}$/p' "$RUN")
[[ -n "$cleanup_body" ]] && ok "cleanup() extractable" || no "could not extract cleanup()"
C4LOG="$TMP/c4-tmux.log"; : > "$C4LOG"
zsh --no-rcs -c '
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  generate_campaign_report(){ :; }; generate_sv_report(){ :; }; sleep(){ :; }
  tmux(){ print -r -- "$*" >> "'"$C4LOG"'"; }
  '"$cleanup_body"'
  CLEANUP_DONE=0; LOCKFILE_ACQUIRED=0
  LOCKFILE_PATH="'"$TMP"'/nolock1"; RUNNER_LOCKFILE_PATH="'"$TMP"'/nolock2"
  WORKER_PANE=%1; VERIFIER_PANE=%2; CONSENSUS_PANE=%99
  LOGS_DIR="'"$TMP"'/c4"; MEMOS_DIR="'"$TMP"'/c4"; mkdir -p "$LOGS_DIR"
  START_TIME=$(date +%s)
  COMPLETE_SENTINEL="'"$TMP"'/ne-c"; BLOCKED_SENTINEL="'"$TMP"'/ne-b"; METADATA_FILE="'"$TMP"'/ne-m"
  DEBUG=0; VERIFY_MODE=all; CONSENSUS_MODE=off; ITERATION=1
  SESSION_NAME=t; SLUG=s; MAX_ITER=1
  cleanup
' >/dev/null 2>&1
c4=$(cat "$C4LOG")
[[ "$c4" == *"send-keys -t %99 C-c"* ]] && ok "cleanup C-c's the consensus pane %99" || no "C4 consensus C-c missing ($c4)"
[[ "$c4" == *"kill-pane -t %99"* ]] && ok "cleanup kill-pane's the consensus pane %99" || no "C4 consensus kill-pane missing ($c4)"

print -r -- "-- IMP-02 C5: cleanup() off-path — no consensus pane → byte-identical non-consensus teardown"
C5LOG="$TMP/c5-tmux.log"; : > "$C5LOG"
zsh --no-rcs -c '
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  generate_campaign_report(){ :; }; generate_sv_report(){ :; }; sleep(){ :; }
  tmux(){ print -r -- "$*" >> "'"$C5LOG"'"; }
  '"$cleanup_body"'
  CLEANUP_DONE=0; LOCKFILE_ACQUIRED=0
  LOCKFILE_PATH="'"$TMP"'/nolock1"; RUNNER_LOCKFILE_PATH="'"$TMP"'/nolock2"
  WORKER_PANE=%1; VERIFIER_PANE=%2; CONSENSUS_PANE=""
  LOGS_DIR="'"$TMP"'/c5"; MEMOS_DIR="'"$TMP"'/c5"; mkdir -p "$LOGS_DIR"
  START_TIME=$(date +%s)
  COMPLETE_SENTINEL="'"$TMP"'/ne-c"; BLOCKED_SENTINEL="'"$TMP"'/ne-b"; METADATA_FILE="'"$TMP"'/ne-m"
  DEBUG=0; VERIFY_MODE=all; CONSENSUS_MODE=off; ITERATION=1
  SESSION_NAME=t; SLUG=s; MAX_ITER=1
  cleanup
' >/dev/null 2>&1
c5=$(cat "$C5LOG")
[[ "$c5" != *"%99"* ]] && ok "no consensus pane → no %99 teardown line" || no "C5 unexpected %99 line ($c5)"
[[ "$c5" == *"kill-pane -t %2"* ]] && ok "verifier pane still reaped (kill-pane -t %2) — non-consensus path unchanged" || no "C5 verifier kill-pane missing ($c5)"

# ---------------------------------------------------------------------------
print -r -- "-- structural: flag gate + evidence-lock injected in BOTH parallel prompts, parallel-only"
grep -q 'if (( CONSENSUS_PARALLEL )); then' "$RUN" \
  && grep -A2 'if (( CONSENSUS_PARALLEL )); then' "$RUN" | grep -q "run_consensus_verification_parallel" \
  && ok "run_consensus_verification gates to parallel path when flag on" || no "parallel gate missing"
# Both write_verifier_trigger calls in the parallel fn pass the evidence lock (7th arg).
[[ "$(print -r -- "$par_body" | grep -c 'CONSENSUS_EVIDENCE_LOCK')" -ge 2 ]] \
  && ok "evidence lock passed to BOTH parallel verifier triggers" || no "evidence lock not in both triggers"
# Sequential single-verifier path must NOT inject the evidence lock (parallel-only).
sv_body=$(sed -n '/^run_single_verifier() {$/,/^}$/p' "$RUN")
print -r -- "$sv_body" | grep -q 'CONSENSUS_EVIDENCE_LOCK' \
  && no "sequential run_single_verifier should NOT reference the evidence lock" \
  || ok "sequential path has no evidence-lock injection (parallel-only)"
grep -q 'RLP_CONSENSUS_PARALLEL' "$REPO/src/node/run.mjs" \
  && ok "run.mjs forwards RLP_CONSENSUS_PARALLEL env" || no "run.mjs env forward missing"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
