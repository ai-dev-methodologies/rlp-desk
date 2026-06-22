#!/bin/zsh
# ============================================================================
# D-backlog regression (exhaustive-audit follow-ups).
#   D-3: leader cross-checks the verdict's own us_id vs the scoped US; a verifier
#        that grades a DIFFERENT US does NOT get the scoped US credited.
#   D-5: consecutive-blocks state (+ model-upgrade state) is persisted in
#        status.json and restored on relaunch, so the now-live block CB (F-22)
#        survives a crash-loop (same durability class as F-13).
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }
ROOT="${0:A:h:h:h}"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"
print -P "%F{cyan}D-3 / D-5 backlog regression%f"

# ---- D-5: update_status persists + status round-trips (incl. special chars) ----
D=$(mktemp -d)
zsh -c '
source '"$LIB"' 2>/dev/null
SLUG=t; ITERATION=3; MAX_ITER=10; WORKER_MODEL=sonnet; VERIFIER_MODEL=sonnet
WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; WORKER_CODEX_MODEL=; WORKER_CODEX_REASONING=
VERIFIER_CODEX_MODEL=; VERIFIER_CODEX_REASONING=; VERIFY_MODE=per-us; CONSENSUS_MODE=off
CONSECUTIVE_FAILURES=1; CONSECUTIVE_BLOCKS=2; LAST_BLOCK_REASON="cross-US: needs US-003 \"output\""
_MODEL_UPGRADED=1; _SAME_US_FAIL_COUNT=2; _ORIGINAL_WORKER_MODEL=haiku; VERIFIED_US="US-001"
STATUS_FILE="'"$D"'/status.json"; BASELINE_COMMIT=none
update_status idle test 2>/dev/null
'
if jq -e '.consecutive_blocks==2 and .model_upgraded==1 and (.last_block_reason|test("cross-US"))' "$D/status.json" >/dev/null 2>&1; then
  ok "D-5: update_status persists consecutive_blocks/model_upgraded/last_block_reason (special chars JSON-safe)"
else
  no "D-5: status.json missing/invalid D-5 fields"; jq -c '{consecutive_blocks,model_upgraded,last_block_reason}' "$D/status.json" 2>&1 | head
fi
rm -rf "$D"

# D-5 structural: the restore block reads consecutive_blocks back
grep -q 'restored_consecutive_blocks_from_status' "$RUN" \
  && ok "D-5: relaunch restore reads consecutive_blocks back (F-22 block CB survives relaunch)" \
  || no "D-5: consecutive_blocks restore missing from relaunch block"

# ---- D-3: verdict us_id cross-check (structural + decision mirror) ----
grep -q '_verdict_us_id' "$RUN" && grep -q 'verdict_us_id_mismatch' "$RUN" \
  && ok "D-3: pass branch cross-checks verdict.us_id vs scoped signal_us_id" \
  || no "D-3: verdict us_id cross-check missing"

# decision mirror: present-mismatch → don't credit; absent or match → credit
decide(){ # args: verdict_us_id signal_us_id  → echo CREDIT|SKIP
  local v="${1:u}" s="$2"
  if [[ -n "$v" && "$v" != "$s" ]]; then print SKIP; else print CREDIT; fi
}
[[ "$(decide 'US-007' 'US-001')" == SKIP   ]] && ok "D-3: graded US-007 while scoped US-001 → SKIP credit" || no "D-3 mismatch not skipped"
[[ "$(decide ''        'US-001')" == CREDIT ]] && ok "D-3: absent verdict us_id → trust scope → CREDIT" || no "D-3 absent should credit"
[[ "$(decide 'us-001'  'US-001')" == CREDIT ]] && ok "D-3: case-normalized match (us-001==US-001) → CREDIT" || no "D-3 case match should credit"
# D-3 codex-fix: the pass-entry CB reset is undone on mismatch so it accumulates
grep -q '_cf_before_pass=$CONSECUTIVE_FAILURES' "$RUN" && grep -q 'CONSECUTIVE_FAILURES=$_cf_before_pass' "$RUN" \
  && ok "D-3 fix: mismatch restores pre-pass CB so consecutive mismatches accumulate (not reset to 0)" \
  || no "D-3 fix: _cf_before_pass snapshot/restore missing"
# D-5 codex-fix: restore is atomic (both count AND reason required)
grep -q '"$_status_cb" -gt 0 && -n "$_status_lbr"' "$RUN" \
  && ok "D-5 fix: block-state restore is atomic (count AND reason, or neither)" \
  || no "D-5 fix: atomic restore guard missing"

# ---- D-4: sequential final verify distinguishes rc==2 (terminal) vs rc==1 (retry) ----
grep -q 'Verifier hard-fail (rc=2' "$RUN" && grep -q 'replacing pane + retrying once (D-4)' "$RUN" \
  && ok "D-4: sequential final verify retries rc==1 (replace+re-dispatch) and is terminal on rc==2" \
  || no "D-4: sequential final-verify retry/terminal split missing"

# ---- D-2: A4 done-claim freshness (mtime-based; stale prior-run claim rejected) ----
grep -q 'block_stale_done_claim' "$RUN" && grep -q '_dc_mt < _wp_mt' "$RUN" \
  && ok "D-2: A4 synth gate rejects a done-claim older than this iteration's worker-prompt" \
  || no "D-2: stale done-claim freshness gate missing"
# behavioral mirror of the mtime decision
stale_decide(){ local dc=$1 wp=$2; (( dc > 0 && wp > 0 && dc < wp )) && print STALE || print FRESH; }
[[ "$(stale_decide 100 200)" == STALE ]] && ok "D-2: claim mtime(100) < worker-prompt(200) → STALE (reject)" || no "D-2 stale not caught"
[[ "$(stale_decide 300 200)" == FRESH ]] && ok "D-2: claim mtime(300) > worker-prompt(200) → FRESH (synthesize)" || no "D-2 fresh wrongly rejected"
[[ "$(stale_decide 200 200)" == FRESH ]] && ok "D-2: equal mtime → FRESH (1s granularity safe, not stale)" || no "D-2 equal wrongly rejected"
[[ "$(stale_decide 0 200)"   == FRESH ]] && ok "D-2: missing stat (0) → FRESH (no false-reject when mtime unavailable)" || no "D-2 zero-mtime false-reject"

# ---- D-8: cleanup re-entrancy guard (idempotent under EXIT+INT/TERM double-fire) ----
grep -q 'CLEANUP_DONE' "$RUN" \
  && ok "D-8: cleanup has a re-entrancy guard (CLEANUP_DONE)" || no "D-8: cleanup re-entrancy guard missing"
# behavioral mirror: a guarded body runs at most once
CLEANUP_DONE=0; _ran=0
_guarded(){ (( ${CLEANUP_DONE:-0} )) && return 0; CLEANUP_DONE=1; _ran=$((_ran+1)); }
_guarded; _guarded; _guarded
[[ $_ran -eq 1 ]] && ok "D-8: guarded cleanup body runs exactly once across 3 invocations" || no "D-8: guard ran body $_ran times"

# ---- D-1: FINAL_VERIFIER_* is WIRED into the final-verify dispatch (was dead) ----
grep -q 'FINAL_VERIFIER_CODEX_MODEL FINAL_VERIFIER_CODEX_REASONING FINAL_VERIFIER_EFFORT' "$RUN" \
  && ok "D-1: FINAL_VERIFIER codex sub-vars are auto-detected (parsing fixed)" || no "D-1: FINAL_VERIFIER auto-detect not fixed"
grep -q 'FINAL_VERIFIER_ENGINE" = "codex"' "$RUN" && grep -q 'build_claude_cmd tui "\$FINAL_VERIFIER_MODEL"' "$RUN" \
  && ok "D-1: sequential final verify dispatches FINAL_VERIFIER_* (stronger final model)" || no "D-1: sequential final not wired to FINAL_VERIFIER_*"
grep -q 'signal_us_id" == "ALL" \]\]; then' "$RUN" && grep -q '_v_eng="\$FINAL_VERIFIER_ENGINE"' "$RUN" \
  && ok "D-1: single-engine ALL verify uses FINAL_VERIFIER_*; per-US aliases VERIFIER_* (no hot-path change)" || no "D-1: single-engine ALL not wired"

# ---- D-9: runner-lock delegated to acquire_slug_lock (atomic pid-IS-the-lock) ----
# The dir-based mkdir+pid-file design had a fundamental acquire/pid-write gap a
# recovery mutex couldn't close (codex D-9 R2); now it reuses the F-20-proven
# acquire_slug_lock (whose own race-safety is covered by test_zsh4_lock 9/9).
grep -q 'acquire_slug_lock "$RUNNER_LOCKFILE_PATH"' "$RUN" \
  && ok "D-9: runner-lock delegates to acquire_slug_lock (no acquire/pid-write gap)" || no "D-9: acquire_slug_lock delegation missing"
grep -q '_rl_mutex' "$RUN" && no "D-9: the insufficient inline recovery-mutex is still present (should be removed)" \
  || ok "D-9: insufficient inline recovery-mutex removed (replaced by delegation)"
grep -q '"${RUNNER_LOCKFILE_PATH}.meta"' "$RUN" && grep -q '"${RUNNER_LOCKFILE_PATH}.recovery.d"' "$RUN" \
  && ok "D-9: cleanup removes lockfile + .meta sidecar + .recovery.d (pid-match ownership)" || no "D-9: cleanup not updated for delegation"
# real end-to-end: acquire_slug_lock on a runner-lock-style file is exclusive
D9=$(mktemp -d); RLF="$D9/runner.lock"
( source "$LIB" 2>/dev/null; acquire_slug_lock "$RLF" ) ; r1=$?
sleep 30 & HOLD=$!; echo "$HOLD" > "$RLF"   # simulate a live holder
( source "$LIB" 2>/dev/null; acquire_slug_lock "$RLF" ) ; r2=$?
[[ $r1 -eq 0 && $r2 -eq 1 ]] && ok "D-9: acquire_slug_lock on the runner file — fresh acquires (0), live holder → busy (1)" || no "D-9 delegation exclusivity (r1=$r1 r2=$r2)"
kill "$HOLD" 2>/dev/null; rm -rf "$D9"

print ""
if (( FAIL == 0 )); then print -P "%F{green}D-backlog: $PASS/$((PASS+FAIL)) PASS%f"; else print -P "%F{red}D-backlog: $PASS pass, $FAIL FAIL%f"; fi
exit $(( FAIL > 0 ))
