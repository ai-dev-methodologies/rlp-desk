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

# ---- D-10: poll dead-pane detection uses the POLLED pane's engine (mixed-engine) ----
grep -q 'check_dead_pane "$poll_cmd" "$_dead_engine"' "$RUN" \
  && ok "D-10: dead-pane check uses role-derived engine (not always WORKER_ENGINE)" || no "D-10: per-pane engine derivation missing"
# behavioral: role → engine (mirror of the derivation)
derive_eng(){ local role="$1" w="$2" v="$3" fv="$4"
  if [[ "$role" == *codex* ]]; then print codex
  elif [[ "$role" == *claude* ]]; then print claude
  elif [[ "$role" == *inal* ]]; then print "$fv"
  elif [[ "$role" == *erifier* ]]; then print "$v"
  else print "$w"; fi; }
[[ "$(derive_eng Verifier claude codex claude)" == codex ]] && ok "D-10: role=Verifier → VERIFIER_ENGINE (codex), not WORKER_ENGINE (claude)" || no "D-10 verifier engine"
[[ "$(derive_eng Verifier-final claude claude codex)" == codex ]] && ok "D-10: role=Verifier-final → FINAL_VERIFIER_ENGINE" || no "D-10 final engine"
[[ "$(derive_eng Verifier-codex claude claude claude)" == codex ]] && ok "D-10: role=Verifier-codex (consensus) → codex" || no "D-10 consensus engine"
[[ "$(derive_eng Worker claude codex codex)" == claude ]] && ok "D-10: role=Worker → WORKER_ENGINE" || no "D-10 worker engine"
# the actual check_dead_pane logic (mirror): a codex pane showing 'bash' is ALIVE
# (codex uses a bash trigger), so judging it with the claude rule false-kills it
cdp(){ local cmd="$1" eng="${2:-claude}"; [[ -z "$cmd" || "$cmd" == zsh ]] && return 0; [[ "$cmd" == bash && "$eng" != codex ]] && return 0; return 1; }
cdp bash codex && no "D-10: codex 'bash' wrongly dead" || ok "D-10: codex verifier showing 'bash' → ALIVE (the false-BLOCK that D-10 fixes)"
cdp bash claude && ok "D-10: claude 'bash' → dead (unchanged)" || no "D-10 claude bash should be dead"
# D-10 codex-fix: single-engine ALL verify polls with role "Verifier-final" so the
# dead-pane derivation matches FINAL_VERIFIER_ENGINE (not VERIFIER_ENGINE)
grep -q '_v_role="Verifier-final"' "$RUN" && grep -q 'poll_for_signal .*"$_v_role"' "$RUN" \
  && ok "D-10 fix: single-engine ALL poll role=Verifier-final → dead-pane uses FINAL_VERIFIER_ENGINE" || no "D-10 fix: _v_role wiring missing"
[[ "$(derive_eng Verifier-final claude claude codex)" == codex ]] && ok "D-10 fix: ALL-verify role resolves FINAL_VERIFIER_ENGINE (codex) when VERIFIER=claude" || no "D-10 fix: final-role engine"

# ---- D-11: CURRENT_US published so lifecycle sentinels emit the real us_id ----
grep -q 'CURRENT_US="$next_us"' "$RUN" && grep -q 'CURRENT_US="$signal_us_id"' "$RUN" \
  && ok "D-11: CURRENT_US set at worker dispatch (next_us) + verify (signal_us_id)" || no "D-11: CURRENT_US assignment missing"

# ---- D-12: pass-path dedup (re-submitted already-verified US not double-credited) ----
grep -q 'verified_us_dedup' "$RUN" \
  && ok "D-12: pass-path dedup guard present (mirrors the fail-path guard)" || no "D-12: pass-path dedup missing"
# behavioral mirror of the dedup credit
credit(){ local cur="$1" us="$2"; if echo ",$cur," | grep -q ",$us,"; then print "$cur"; else [[ -n "$cur" ]] && print "$cur,$us" || print "$us"; fi; }
[[ "$(credit 'US-001,US-002' 'US-002')" == 'US-001,US-002' ]] && ok "D-12: re-submitted US-002 → not appended (no US-001,US-002,US-002)" || no "D-12 dedup failed"
[[ "$(credit 'US-001' 'US-002')" == 'US-001,US-002' ]] && ok "D-12: new US-002 → appended" || no "D-12 new-append failed"

# ---- D-5b: model-upgrade state restored on relaunch (restore-priority, gated) ----
grep -q 'restored_model_upgrade=true' "$RUN" && grep -q '_status_mu" == "1"' "$RUN" \
  && ok "D-5b: relaunch restores upgraded model, GATED on model_upgraded==1 (fresh campaign keeps CLI model)" || no "D-5b: model-upgrade restore missing/ungated"
# behavioral: gate logic
mu_restore(){ local mu="$1"; [[ "$mu" == "1" ]] && print RESTORE || print KEEP_CLI; }
[[ "$(mu_restore 1)" == RESTORE ]] && ok "D-5b: model_upgraded=1 → restore upgraded model" || no "D-5b restore gate"
[[ "$(mu_restore 0)" == KEEP_CLI ]] && ok "D-5b: model_upgraded=0 (never upgraded) → keep CLI/env model" || no "D-5b keep gate"

# ---- D-13: per-leader paste buffer (no cross-leader ABA on a global buffer) ----
grep -q 'rlp-paste-$$-' "$RUN" && grep -vq 'load-buffer -b rlp-paste ' <(grep 'load-buffer' "$RUN") 2>/dev/null \
  && ok "D-13: paste buffer is per-leader+pane (rlp-paste-\$\$-…), not a server-global name" || no "D-13: per-leader paste buffer missing"

# ---- D-14: consensus codex null-verdict retry (symmetry with claude) ----
grep -q 'consensus_codex_retry' "$RUN" \
  && ok "D-14: consensus codex null-verdict retry present (symmetry with claude)" || no "D-14: codex null-retry missing"

# ---- D-15: consensus merged verdict carries us_id (D-3 cross-check applies) ----
grep -q 'cons_us_id="${2:-' "$RUN" && grep -q '"us_id": "'\''"$cons_us_id"'\''",' "$RUN" \
  && ok "D-15: consensus merged verdict includes us_id (passed from caller)" || no "D-15: consensus us_id missing"
# D-15 codex-fix: us_id sanitized to JSON-safe (ALL|US-NNN) before echo-interpolation
grep -q 'cons_us_id" == (ALL|US-<->)' "$RUN" \
  && ok "D-15 fix: us_id sanitized to ALL|US-NNN (JSON-safe; no quote/backslash injection)" || no "D-15 fix: us_id sanitize missing"
sane(){ local u="$1"; [[ "$u" == (ALL|US-<->) ]] && print "$u" || print ALL; }
[[ "$(sane 'US-007')" == US-007 && "$(sane 'ALL')" == ALL && "$(sane 'x"]}evil')" == ALL ]] && ok "D-15 fix: US-007/ALL pass through; malformed → ALL" || no "D-15 sanitize logic"
# D-13 codex-fix: redundant explicit delete-buffer removed (paste -d already deletes)
grep -q 'tmux delete-buffer -b "$_buf"' "$RUN" && no "D-13 fix: redundant delete-buffer still present" \
  || ok "D-13 fix: redundant hot-path delete-buffer removed (paste -d handles it)"

# ---- D-1c: documented consensus cross-verifier model knobs are WIRED (were dead) ----
# run_single_verifier codex branch honors the passed-in model arg ("model:reasoning")
# instead of always using the global VERIFIER_CODEX_*.
grep -qF '_cx_model="$VERIFIER_CODEX_MODEL" _cx_reason="$VERIFIER_CODEX_REASONING"' "$RUN" \
  && grep -qF 'local _m="${model%%:*}" _r="${model##*:}"' "$RUN" \
  && grep -qF '_cx_model="$_m"; _cx_reason="$_r"' "$RUN" \
  && ok "D-1c: codex verifier parses model:reasoning arg (falls back to globals)" || no "D-1c: codex model-arg parse missing"
# consensus selects per-US vs final model pairs (claude=VERIFIER/FINAL_VERIFIER, codex=CONSENSUS/FINAL_CONSENSUS)
grep -qF '_cons_claude_model="$FINAL_VERIFIER_MODEL"; _cons_codex_model="$FINAL_CONSENSUS_MODEL"' "$RUN" \
  && grep -qF '_cons_claude_model="$VERIFIER_MODEL"; _cons_codex_model="$CONSENSUS_MODEL"' "$RUN" \
  && ok "D-1c: consensus picks final pair for ALL, lighter pair per-US" || no "D-1c: consensus model-pair selection missing"
# the consensus run_single_verifier calls use the selected models, not the raw globals
grep -qF 'run_single_verifier "$iter" "claude" "$_cons_claude_model"' "$RUN" \
  && grep -qF 'run_single_verifier "$iter" "codex" "$_cons_codex_model"' "$RUN" \
  && ok "D-1c: consensus dispatch threads the selected per-US/final models" || no "D-1c: consensus dispatch not wired to selected models"
# logic mirror: model:reasoning split for the documented defaults
cxsplit(){ local m="$1" mo re; if [[ "$m" == *:* ]]; then mo="${m%%:*}"; re="${m##*:}"; else mo="$m"; re="GLOBAL"; fi; print "$mo|$re"; }
[[ "$(cxsplit 'gpt-5.5:medium')" == 'gpt-5.5|medium' && "$(cxsplit 'gpt-5.5:high')" == 'gpt-5.5|high' && "$(cxsplit 'gpt-5.5')" == 'gpt-5.5|GLOBAL' ]] \
  && ok "D-1c: model:reasoning split (gpt-5.5:medium→medium, gpt-5.5:high→high, bare→global)" || no "D-1c: split logic"
# D-1c codex MEDIUM: final consensus claude effort = FINAL_VERIFIER_EFFORT (not VERIFIER_EFFORT).
# Single-dash ${6-...} preserves an explicitly-passed empty effort (re-review LOW).
grep -qF 'local effort="${6-$VERIFIER_EFFORT}"' "$RUN" && grep -qF 'build_claude_cmd tui "$model" "" "" "$effort"' "$RUN" \
  && grep -qF '_cons_claude_effort="$FINAL_VERIFIER_EFFORT"' "$RUN" \
  && grep -qF 'run_single_verifier "$iter" "claude" "$_cons_claude_model" "-claude" "$claude_verdict_file" "$_cons_claude_effort"' "$RUN" \
  && ok "D-1c fix(MED): final consensus claude effort threaded (FINAL_VERIFIER_EFFORT for ALL, empty preserved via \${6-})" || no "D-1c fix(MED): claude effort not threaded"
# \${6-} vs \${6:-} — explicitly-passed empty must NOT collapse to the default
six(){ local e="${1-DEFAULT}"; print "$e"; }   # mirror of ${6-...} for the passed arg
[[ "$(six '')" == '' && "$(six)" == DEFAULT && "$(six medium)" == medium ]] \
  && ok "D-1c fix(MED): \${6-} preserves explicit empty (unset→default, ''→'', val→val)" || no "D-1c fix(MED): \${6-} semantics"
# D-1c codex LOW: malformed model:reasoning rejected → fall back to globals (xhigh is VALID — re-review LOW)
grep -qF '"$model" != *:*:*' "$RUN" && grep -qF '"$_r" == (minimal|low|medium|high|xhigh)' "$RUN" \
  && ok "D-1c fix(LOW): malformed model:reasoning validated (>1 colon / bad reasoning → fallback; xhigh allowed)" || no "D-1c fix(LOW): malformed-spec validation missing"
# logic mirror: validation accept/reject table (xhigh is a real upgrade-table ceiling level)
cxvalid(){ local m="$1" mo re; if [[ "$m" == *:* ]]; then mo="${m%%:*}" re="${m##*:}"; if [[ -n "$mo" && "$m" != *:*:* && "$re" == (minimal|low|medium|high|xhigh) ]]; then print "OK:$mo:$re"; else print FALLBACK; fi; else print "BARE:$m"; fi; }
[[ "$(cxvalid 'gpt-5.5:medium')" == 'OK:gpt-5.5:medium' && "$(cxvalid 'gpt-5.5:xhigh')" == 'OK:gpt-5.5:xhigh' && "$(cxvalid 'gpt-5.5:')" == FALLBACK && "$(cxvalid ':medium')" == FALLBACK && "$(cxvalid 'foo:bar:baz')" == FALLBACK && "$(cxvalid 'gpt-5.5:turbo')" == FALLBACK && "$(cxvalid 'gpt-5.5')" == 'BARE:gpt-5.5' ]] \
  && ok "D-1c fix(LOW): valid(incl xhigh)→split, empty/multi-colon/unknown→fallback, bare→global" || no "D-1c fix(LOW): validation logic"

# ---- D-16: last-US pass finalizes directly (leader-synthesized ALL signal, no worker round-trip) ----
# Was: after the last per-US pass, the leader dispatched a worker round-trip whose only job
# was to emit an ALL signal — a fragile extra LLM iteration (observed hanging on an API
# rate-limit in SV CRITICAL, blocking a campaign whose work was already done).
grep -qF '_FINALIZE_PENDING=0      # D-16' "$RUN" \
  && ok "D-16: _FINALIZE_PENDING global declared (survives the loop-local SKIP_NEXT_WORKER)" || no "D-16: finalize flag missing"
grep -qF '_all_us_verified()' "$RUN" \
  && ok "D-16: _all_us_verified coverage helper present" || no "D-16: coverage helper missing"
# arm: the per-US pass branch sets _FINALIZE_PENDING when coverage completes
grep -qF '_all_us_verified; then' "$RUN" && grep -qF '_FINALIZE_PENDING=1' "$RUN" \
  && ok "D-16: pass-branch arms finalize on coverage-complete" || no "D-16: arm missing"
# consume: the loop top synthesizes an ALL verify signal + reuses SKIP_NEXT_WORKER (proven recovery path)
grep -qF 'if (( _FINALIZE_PENDING )) && [[ "$SKIP_NEXT_WORKER" -eq 0 ]]; then' "$RUN" \
  && grep -qF '"status": "verify", "us_id": "ALL"' "$RUN" \
  && grep -qF 'SKIP_NEXT_WORKER=1' "$RUN" \
  && ok "D-16: loop-top synthesizes ALL verify signal + skips worker (reuses SKIP_NEXT_WORKER)" || no "D-16: finalize-synth missing"
# operator-recovery precedence + the existing worker-ALL-signal final-verify trigger still intact
grep -qF 'signal_us_id" == "ALL" && "$VERIFY_MODE" == "per-us" && -n "$US_LIST"' "$RUN" \
  && ok "D-16: downstream final-verify trigger (signal_us_id=ALL) unchanged — D-16 only changes HOW we reach it" || no "D-16: final-verify trigger drifted"
# logic mirror: coverage check (all US present → arm; any missing → don't)
allverif(){ local list="$1" verified="$2" us; for us in $(echo "$list" | tr ',' ' '); do echo ",$verified," | grep -q ",$us," || { print NO; return; }; done; print YES; }
[[ "$(allverif 'US-001' 'US-001')" == YES && "$(allverif 'US-001,US-002' 'US-001')" == NO && "$(allverif 'US-001,US-002' 'US-001,US-002')" == YES && "$(allverif '' 'US-001')" == YES ]] \
  && ok "D-16: coverage logic (full→arm, partial→wait); note empty US_LIST guarded separately in helper" || no "D-16: coverage logic"

# ---- D-18: final verify is flake-resilient — a per-US-passed US's FAIL verdict must reproduce ----
# Was: run_sequential_final_verify failed a US on the FIRST fail verdict. A codex
# final-verifier false-fail (non-determinism) on already-correct, per-US-passed work
# then entered the fix loop the worker couldn't satisfy → stale-context BLOCK of a
# complete campaign (observed in the D-16 3-US dogfood, pytest 36/36).
grep -qF 'FINAL_VERIFY_MAX_ATTEMPTS="${FINAL_VERIFY_MAX_ATTEMPTS:-3}"' "$RUN" \
  && ok "D-18: FINAL_VERIFY_MAX_ATTEMPTS knob declared (default 3, env-overridable)" || no "D-18: knob missing"
# dispatch/poll/verdict extracted into a re-runnable helper
grep -qF '_final_verify_one_us()' "$RUN" && grep -qF '_final_verify_one_us "$us" "$iter"' "$RUN" \
  && ok "D-18: per-US dispatch extracted to _final_verify_one_us (re-runnable)" || no "D-18: helper missing"
# already-per-US-passed US gets max attempts; others get 1; reverify only on fail verdict (rc!=2)
grep -qF 'if echo ",$VERIFIED_US," | grep -q ",$us,"; then _fv_max=$FINAL_VERIFY_MAX_ATTEMPTS; fi' "$RUN" \
  && grep -qF '(( _fv_rc == 2 ))' "$RUN" && grep -qF '(( _fv_rc == 0 )) && break' "$RUN" \
  && ok "D-18: per-US-passed→max attempts, infra(rc2)→no retry, pass(rc0)→break" || no "D-18: reverify gating missing"
# helper must NOT set FAILED_US (caller owns it) and returns 0/1/2
grep -qF '[[ "$verdict" == "pass" ]] && return 0' "$RUN" \
  && ok "D-18: helper returns verdict rc (0 pass / 1 fail / 2 infra), caller owns FAILED_US" || no "D-18: helper return contract"
# logic mirror: attempt budget + first-pass-wins
fvmax(){ local us="$1" verified="$2" max="$3"; echo ",$verified," | grep -q ",$us," && print "$max" || print 1; }
[[ "$(fvmax US-001 'US-001,US-002' 3)" == 3 && "$(fvmax US-009 'US-001,US-002' 3)" == 1 ]] \
  && ok "D-18: budget — per-US-passed US=max(3), never-passed US=1 (genuine regression fails fast)" || no "D-18: budget logic"
# first-pass-wins + reproduce-to-fail (simulate verdict sequences)
fvres(){ local max="$1"; shift; local a=0 v; for v in "$@"; do (( a++ )); [[ "$v" == pass ]] && { print "PASS@$a"; return; }; (( a >= max )) && { print "FAIL@$a"; return; }; done; print "FAIL@$a"; }
[[ "$(fvres 3 fail pass)" == 'PASS@2' && "$(fvres 3 fail fail fail)" == 'FAIL@3' && "$(fvres 1 fail)" == 'FAIL@1' && "$(fvres 3 pass)" == 'PASS@1' ]] \
  && ok "D-18: flake(fail→pass)=PASS@2, real regression(fail×3)=FAIL@3, no-tolerance(max1,fail)=FAIL@1, clean=PASS@1" || no "D-18: reverify outcome logic"
# D-18 codex HIGH: knob validated — non-integer / out-of-range must NOT mis-evaluate (silent false-fail)
grep -qF 'if ! [[ "$FINAL_VERIFY_MAX_ATTEMPTS" == <-> ]] || (( FINAL_VERIFY_MAX_ATTEMPTS < 1 || FINAL_VERIFY_MAX_ATTEMPTS > 10 )); then' "$RUN" \
  && ok "D-18 fix(HIGH): FINAL_VERIFY_MAX_ATTEMPTS validated (integer 1..10, glob-checked before arithmetic)" || no "D-18 fix(HIGH): knob validation missing"
# logic mirror: validation table (glob-first so arithmetic never runs on non-integer)
fvval(){ local v="$1"; if ! [[ "$v" == <-> ]] || (( v < 1 || v > 10 )); then print 3; else print "$v"; fi; }
[[ "$(fvval 3)" == 3 && "$(fvval 1)" == 1 && "$(fvval 10)" == 10 && "$(fvval abc)" == 3 && "$(fvval 0)" == 3 && "$(fvval 99)" == 3 && "$(fvval '')" == 3 ]] \
  && ok "D-18 fix(HIGH): valid 1..10 pass through; abc/0/99/'' → default 3 (no arith on non-int)" || no "D-18 fix(HIGH): validation logic"

# ---- D-17a: claude rate-limit banner routes to bounded API backoff (was → 600s frozen BLOCK) ----
# The claude TUI "API Error: ... temporarily limiting requests ... · Rate limited" banner
# previously did not match the API-error patterns → fell through to the frozen-pane 600s
# BLOCK with a misleading "deadlock" reason (observed: CRITICAL att.1 + D-16 dogfood att.1).
# codex MEDIUM fix: single banner-specific pattern (API Error + the distinctive
# multi-word phrase on one line), NOT loose standalone patterns.
grep -qF "grep -qiE 'api error.*temporarily limiting requests'" "$RUN" \
  && ok "D-17a: banner pattern requires 'API Error' + 'temporarily limiting requests' together" || no "D-17a: banner pattern missing"
grep -qF "grep -qiE '(^|[^[:digit:]])429([^[:digit:]]|\$)'" "$RUN" \
  && ok "D-17a: HTTP 429 added (mirrors 500/529)" || no "D-17a: 429 missing"
# loose patterns must be GONE (codex MEDIUM: false-positive on legit rate-limit discussion)
grep -qF "grep -qiE 'api error.*rate.?limit'" "$RUN" && no "D-17a fix: loose 'api error.*rate.?limit' still present (false-positive risk)" \
  || ok "D-17a fix(MED): loose patterns removed (no standalone 'temporarily limiting requests' / 'api error.*rate.?limit')"
# logic mirror: match the real banner + 429; do NOT match legit discussion/feature/quote
rlmatch(){ echo "$1" | grep -qiE 'api error.*temporarily limiting requests' || echo "$1" | grep -qiE '(^|[^[:digit:]])429([^[:digit:]]|$)'; }
rlmatch '⏺ API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited' && b1=Y || b1=N
rlmatch '⏺ API Error: 429 Too Many Requests' && b2=Y || b2=N
rlmatch 'def rate_limit(n): # implement a rate limiter' && f1=Y || f1=N
rlmatch '# handle the API error: back off when rate limited (see docs)' && f2=Y || f2=N
rlmatch 'the server is temporarily limiting requests in my new throttle module' && f3=Y || f3=N
[[ "$b1" == Y && "$b2" == Y && "$f1" == N && "$f2" == N && "$f3" == N ]] \
  && ok "D-17a fix(MED): banner+429 match; feature/discussion/quote (incl. 'API error: back off when rate limited', bare 'temporarily limiting requests') do NOT false-trigger" || no "D-17a match/false-positive (b1=$b1 b2=$b2 f1=$f1 f2=$f2 f3=$f3)"

print ""
if (( FAIL == 0 )); then print -P "%F{green}D-backlog: $PASS/$((PASS+FAIL)) PASS%f"; else print -P "%F{red}D-backlog: $PASS pass, $FAIL FAIL%f"; fi
exit $(( FAIL > 0 ))
