# ============================================================================
# SELF-VERIFICATION HARNESS BODY — codex+tmux execution path
# Appended to a main()-stripped copy of run_ralph_desk.zsh and run at toplevel
# so every function under test is the REAL function in its REAL load context.
# ============================================================================
SV_PASS=0; SV_FAIL=0
svok(){ SV_PASS=$((SV_PASS+1)); print -P "  %F{green}PASS%f $1"; }
svno(){ SV_FAIL=$((SV_FAIL+1)); print -P "  %F{red}FAIL%f $1"; }
sect(){ print -P "%F{cyan}── $1%f"; }

# ---------------------------------------------------------------------------
sect "S1  _auto_detect_engine — model:level engine routing"
WORKER_MODEL="opus:high"; WORKER_ENGINE="claude"; WORKER_EFFORT=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
[[ "$WORKER_ENGINE" == claude && "$WORKER_MODEL" == opus && "$WORKER_EFFORT" == high ]] \
  && svok "S1.1 opus:high → claude/opus/high" || svno "S1.1 engine=$WORKER_ENGINE model=$WORKER_MODEL effort=$WORKER_EFFORT"

WORKER_MODEL="gpt-5.5:high"; WORKER_ENGINE="claude"; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
[[ "$WORKER_ENGINE" == codex && "$WORKER_CODEX_MODEL" == gpt-5.5 && "$WORKER_CODEX_REASONING" == high ]] \
  && svok "S1.2 gpt-5.5:high → codex/gpt-5.5/high" || svno "S1.2 engine=$WORKER_ENGINE cm=$WORKER_CODEX_MODEL cr=$WORKER_CODEX_REASONING"

WORKER_MODEL="spark:medium"; WORKER_ENGINE="claude"; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
[[ "$WORKER_ENGINE" == codex && "$WORKER_CODEX_MODEL" == gpt-5.3-codex-spark && "$WORKER_CODEX_REASONING" == medium ]] \
  && svok "S1.3 spark:medium → codex/gpt-5.3-codex-spark/medium" || svno "S1.3 cm=$WORKER_CODEX_MODEL cr=$WORKER_CODEX_REASONING"

WORKER_MODEL="sonnet"; WORKER_ENGINE="claude"
_auto_detect_engine WORKER_MODEL WORKER_ENGINE "" "" WORKER_EFFORT
[[ "$WORKER_ENGINE" == claude && "$WORKER_MODEL" == sonnet ]] \
  && svok "S1.4 sonnet (no colon) → claude unchanged" || svno "S1.4 engine=$WORKER_ENGINE model=$WORKER_MODEL"

# mixed: worker codex + verifier claude routing independence
VERIFIER_MODEL="opus:max"; VERIFIER_ENGINE="claude"; VERIFIER_EFFORT=""
_auto_detect_engine VERIFIER_MODEL VERIFIER_ENGINE VERIFIER_CODEX_MODEL VERIFIER_CODEX_REASONING VERIFIER_EFFORT
[[ "$VERIFIER_ENGINE" == claude && "$VERIFIER_EFFORT" == max ]] \
  && svok "S1.5 verifier opus:max → claude/max (mixed-engine independence)" || svno "S1.5 engine=$VERIFIER_ENGINE effort=$VERIFIER_EFFORT"

# full versioned claude ids WITH effort → claude engine (not codex)
WORKER_MODEL="claude-opus-4-8:high"; WORKER_ENGINE="claude"; WORKER_EFFORT=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
[[ "$WORKER_ENGINE" == claude && "$WORKER_MODEL" == claude-opus-4-8 && "$WORKER_EFFORT" == high ]] \
  && svok "S1.6 claude-opus-4-8:high → claude/claude-opus-4-8/high" || svno "S1.6 engine=$WORKER_ENGINE model=$WORKER_MODEL effort=$WORKER_EFFORT"

VERIFIER_MODEL="claude-fable-5:max"; VERIFIER_ENGINE="claude"; VERIFIER_EFFORT=""; VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""
_auto_detect_engine VERIFIER_MODEL VERIFIER_ENGINE VERIFIER_CODEX_MODEL VERIFIER_CODEX_REASONING VERIFIER_EFFORT
[[ "$VERIFIER_ENGINE" == claude && "$VERIFIER_MODEL" == claude-fable-5 && "$VERIFIER_EFFORT" == max ]] \
  && svok "S1.7 claude-fable-5:max → claude/claude-fable-5/max" || svno "S1.7 engine=$VERIFIER_ENGINE model=$VERIFIER_MODEL effort=$VERIFIER_EFFORT"

# bracket+colon combo: 1M suffix survives alongside effort, still claude engine
WORKER_MODEL="claude-opus-4-8[1m]:high"; WORKER_ENGINE="claude"; WORKER_EFFORT=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
[[ "$WORKER_ENGINE" == claude && "$WORKER_MODEL" == "claude-opus-4-8[1m]" && "$WORKER_EFFORT" == high ]] \
  && svok "S1.8 claude-opus-4-8[1m]:high → claude/claude-opus-4-8[1m]/high" || svno "S1.8 engine=$WORKER_ENGINE model=$WORKER_MODEL effort=$WORKER_EFFORT"

# ---------------------------------------------------------------------------
sect "S2  parse_model_flag — CLI --worker-model/--verifier-model parsing"
[[ "$(parse_model_flag opus:high worker)" == "claude opus high" ]] && svok "S2.1 opus:high → 'claude opus high'" || svno "S2.1 got '$(parse_model_flag opus:high worker)'"
[[ "$(parse_model_flag gpt-5.5:high worker)" == "codex gpt-5.5 high" ]] && svok "S2.2 gpt-5.5:high → 'codex gpt-5.5 high'" || svno "S2.2 got '$(parse_model_flag gpt-5.5:high worker)'"
[[ "$(parse_model_flag spark:low verifier)" == "codex gpt-5.3-codex-spark low" ]] && svok "S2.3 spark:low → 'codex gpt-5.3-codex-spark low'" || svno "S2.3 got '$(parse_model_flag spark:low verifier)'"
[[ "$(parse_model_flag sonnet worker)" == "claude sonnet" ]] && svok "S2.4 sonnet → 'claude sonnet'" || svno "S2.4 got '$(parse_model_flag sonnet worker)'"
parse_model_flag "a:b:c" worker >/dev/null 2>&1; [[ $? -ne 0 ]] && svok "S2.5 'a:b:c' rejected (2 colons)" || svno "S2.5 invalid not rejected"
[[ "$(parse_model_flag claude-opus-4-8:high verifier)" == "claude claude-opus-4-8 high" ]] && svok "S2.6 claude-opus-4-8:high → 'claude claude-opus-4-8 high'" || svno "S2.6 got '$(parse_model_flag claude-opus-4-8:high verifier)'"
[[ "$(parse_model_flag claude-fable-5:max final-verifier)" == "claude claude-fable-5 max" ]] && svok "S2.7 claude-fable-5:max → 'claude claude-fable-5 max'" || svno "S2.7 got '$(parse_model_flag claude-fable-5:max final-verifier)'"
[[ "$(parse_model_flag 'claude-opus-4-8[1m]:high' worker)" == "claude claude-opus-4-8[1m] high" ]] && svok "S2.8 claude-opus-4-8[1m]:high → 'claude claude-opus-4-8[1m] high'" || svno "S2.8 got '$(parse_model_flag 'claude-opus-4-8[1m]:high' worker)'"

# ---------------------------------------------------------------------------
sect "S3  check_dead_pane — engine-aware liveness (codex bash=alive, claude bash=dead)"
if check_dead_pane "bash" "codex" "worker"; then svno "S3.1 codex+bash flagged dead"; else svok "S3.1 codex+bash → ALIVE"; fi
if check_dead_pane "bash" "claude" "worker"; then svok "S3.2 claude+bash → DEAD"; else svno "S3.2 claude+bash not dead"; fi
if check_dead_pane "zsh" "codex" "worker"; then svok "S3.3 bare zsh → DEAD"; else svno "S3.3 zsh not dead"; fi
if check_dead_pane "" "codex" "worker"; then svok "S3.4 empty cmd → DEAD"; else svno "S3.4 empty not dead"; fi
if check_dead_pane "node" "claude" "worker"; then svno "S3.5 node flagged dead"; else svok "S3.5 node+claude → ALIVE"; fi
if check_dead_pane "codex" "codex" "worker"; then svno "S3.6 codex proc flagged dead"; else svok "S3.6 codex proc → ALIVE"; fi

# ---------------------------------------------------------------------------
sect "S4  check_dependencies — engine matrix (positive + codex-missing negative)"
# positive: codex-only campaign w/ everything installed
( WORKER_ENGINE=codex; VERIFIER_ENGINE=codex; CONSENSUS_MODE=off; check_dependencies >/dev/null 2>&1 ) \
  && svok "S4.1 codex+codex deps OK (all installed)" || svno "S4.1 codex+codex deps failed unexpectedly"
# positive: mixed worker=claude verifier=codex
( WORKER_ENGINE=claude; VERIFIER_ENGINE=codex; CONSENSUS_MODE=off; check_dependencies >/dev/null 2>&1 ) \
  && svok "S4.2 claude+codex (mixed) deps OK" || svno "S4.2 mixed deps failed"
# negative: codex engine but codex hidden from PATH → must fail (exit 1)
( WORKER_ENGINE=codex; VERIFIER_ENGINE=claude; CONSENSUS_MODE=off; PATH="$SV_FAKEPATH"; check_dependencies >/dev/null 2>&1 ) \
  && svno "S4.3 codex-missing NOT detected (should fail)" || svok "S4.3 codex engine + codex absent → fails (exit 1)"
# negative: consensus on but codex hidden → must fail
( WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; CONSENSUS_MODE=final-only; PATH="$SV_FAKEPATH"; check_dependencies >/dev/null 2>&1 ) \
  && svno "S4.4 consensus codex-missing NOT detected" || svok "S4.4 consensus + codex absent → fails"

# ---------------------------------------------------------------------------
sect "S5  codex verdict legacy-path fallback (_migrate_legacy_verdict)"
mkdir -p "$(dirname "$LEGACY_VERDICT_FILE")" "$(dirname "$VERDICT_FILE")" 2>/dev/null
print '{"status":"pass","summary":"ok"}' > "$LEGACY_VERDICT_FILE"
rm -f "$VERDICT_FILE"
if _migrate_legacy_verdict && [[ -f "$VERDICT_FILE" && ! -f "$LEGACY_VERDICT_FILE" ]]; then
  svok "S5.1 valid legacy verdict migrated → canonical, legacy removed"
else
  svno "S5.1 migration failed (canon=$([[ -f $VERDICT_FILE ]] && echo y || echo n) legacy=$([[ -f $LEGACY_VERDICT_FILE ]] && echo y || echo n))"
fi
print 'not valid json' > "$LEGACY_VERDICT_FILE"; rm -f "$VERDICT_FILE"
if _migrate_legacy_verdict; then svno "S5.2 invalid legacy json migrated (should refuse)"; else svok "S5.2 invalid legacy json refused"; fi
rm -f "$LEGACY_VERDICT_FILE" "$VERDICT_FILE"

# ---------------------------------------------------------------------------
sect "S6  tmux session lifecycle — create_session / pane-alive / kill-detect"
mkdir -p "$MEMOS_DIR" "$LOGS_DIR" "$RUNTIME_DIR" 2>/dev/null
create_session >/dev/null 2>&1
if [[ -n "$LEADER_PANE" && -n "$WORKER_PANE" && -n "$VERIFIER_PANE" ]]; then
  svok "S6.1 create_session → leader=$LEADER_PANE worker=$WORKER_PANE verifier=$VERIFIER_PANE"
else
  svno "S6.1 panes not all created (L=$LEADER_PANE W=$WORKER_PANE V=$VERIFIER_PANE)"
fi
_verify_session_alive "$SESSION_NAME" && svok "S6.2 session '$SESSION_NAME' alive" || svno "S6.2 session not alive"
_verify_pane_alive "$WORKER_PANE" && svok "S6.3 worker pane alive after create" || svno "S6.3 worker pane not alive"
_verify_pane_alive "$VERIFIER_PANE" && svok "S6.4 verifier pane alive after create" || svno "S6.4 verifier pane not alive"
# distinct pane ids
[[ "$WORKER_PANE" != "$VERIFIER_PANE" && "$WORKER_PANE" != "$LEADER_PANE" ]] && svok "S6.5 pane ids distinct" || svno "S6.5 pane id collision"

# ---------------------------------------------------------------------------
sect "S7  R12 lifecycle monitor — dead pane → infra_failure BLOCKED + exit 1"
tmux kill-pane -t "$VERIFIER_PANE" 2>/dev/null
sleep 0.6
if _verify_pane_alive "$VERIFIER_PANE"; then svno "S7.1 killed pane still reported alive"; else svok "S7.1 killed verifier pane → dead detected"; fi
rm -f "$BLOCKED_SENTINEL"
( _r12_check_lifecycle "sv-s7" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && svok "S7.2 _r12_check_lifecycle exits 1 on dead pane" || svno "S7.2 r12 rc=$rc (expected 1)"
if [[ -f "$BLOCKED_SENTINEL" ]] && grep -qi "infra_failure\|dead" "$BLOCKED_SENTINEL" 2>/dev/null; then
  svok "S7.3 BLOCKED sentinel written w/ infra_failure category"
else
  svno "S7.3 BLOCKED sentinel missing/incorrect"
fi

# ---------------------------------------------------------------------------
sect "S8  check_existing_sessions — duplicate-session guard"
# create a second decoy session matching the slug pattern, then verify the guard trips
DECOY="rlp-desk-${SLUG}-decoy$$"
tmux new-session -d -s "$DECOY" 2>/dev/null
( check_existing_sessions ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && svok "S8.1 existing-session guard trips (exit≠0) when decoy present" || svno "S8.1 guard did not trip (rc=$rc)"
tmux kill-session -t "$DECOY" 2>/dev/null

# ---------------------------------------------------------------------------
print ""
print -P "%F{magenta}─────────────────────────────────────────────%f"
if (( SV_FAIL == 0 )); then
  print -P "%F{green}▶ codex+tmux SELF-VERIFY: $SV_PASS/$((SV_PASS+SV_FAIL)) PASS%f"
else
  print -P "%F{red}▶ codex+tmux SELF-VERIFY: $SV_PASS pass, $SV_FAIL FAIL%f"
fi
exit $(( SV_FAIL > 0 ? 1 : 0 ))
