#!/bin/zsh
# ============================================================================
# F-22/F-23/F-25 regression — leader no-longer-dies-on-a-single-slip class.
#   F-22: _check_consecutive_blocks was DEAD CODE (never called) → a single
#         transient worker/verifier "blocked" terminated the campaign, and
#         request_info / unknown verdict|status spun silently to MAX_ITER.
#         Now: blocks get grace (_block_with_grace); soft-fails bump the CB.
#   F-23: recommended/us_id phrasing variants ("completed","done","all") no
#         longer strand a complete campaign at MAX_ITER.
#   F-25: run_single_verifier captures poll rc directly (rc==2 branch live).
# Logic cases mirror the helpers; structural cases assert the REAL wiring.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }
print -P "%F{cyan}F-22/F-23/F-25 block-grace + CB + normalization%f"

# ---- faithful mirror of the leader helpers ----
EFFECTIVE_CB_THRESHOLD=6
BLOCK_CB_THRESHOLD=3
CONSECUTIVE_FAILURES=0
CONSECUTIVE_BLOCKS=0
LAST_BLOCK_REASON=""
_canonical_block_reason(){ print -r -- "$1"; }   # identity is enough for the test
_check_consecutive_blocks(){
  local reason="$1" category="${2:-metric_failure}" iter="${3:-0}"
  if [[ "$category" == "infra_failure" ]] || (( iter <= 1 )); then
    LAST_BLOCK_REASON=""; CONSECUTIVE_BLOCKS=0; return 0
  fi
  local canonical; canonical=$(_canonical_block_reason "$reason")
  if [[ "$canonical" == "$LAST_BLOCK_REASON" && -n "$canonical" ]]; then
    CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
  else
    CONSECUTIVE_BLOCKS=1; LAST_BLOCK_REASON="$canonical"
  fi
  (( CONSECUTIVE_BLOCKS >= BLOCK_CB_THRESHOLD )) && return 1
  return 0
}
_bump_consecutive_failure(){
  (( CONSECUTIVE_FAILURES++ ))
  (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )) && return 0
  return 1
}
_block_with_grace(){
  local reason="$1" category="${2:-metric_failure}"
  _check_consecutive_blocks "$reason" "$category" "${ITERATION:-0}" || return 0
  [[ "$category" == "infra_failure" ]] && return 0
  _bump_consecutive_failure && return 0
  return 1
}

# ---- behavioral cases ----
ITERATION=3

# 1. _bump: under threshold returns 1 (continue), trips to 0 at threshold
CONSECUTIVE_FAILURES=0
_bump_consecutive_failure; r1=$?
[[ $r1 -eq 1 && $CONSECUTIVE_FAILURES -eq 1 ]] && ok "bump 1/6 → continue (rc=1)" || no "bump first (rc=$r1 cf=$CONSECUTIVE_FAILURES)"
CONSECUTIVE_FAILURES=5
_bump_consecutive_failure; r2=$?
[[ $r2 -eq 0 && $CONSECUTIVE_FAILURES -eq 6 ]] && ok "bump 6/6 → CB trips (rc=0)" || no "bump trip (rc=$r2 cf=$CONSECUTIVE_FAILURES)"

# 2. infra_failure block → immediate terminal
CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_block_with_grace "api dead" "infra_failure"; r=$?
[[ $r -eq 0 ]] && ok "infra block → terminal (no grace)" || no "infra block (rc=$r)"

# 3. recoverable first block → absorbed (soft-fail, continue)
CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_block_with_grace "metric: AC2 unclear" "metric_failure"; r=$?
[[ $r -eq 1 && $CONSECUTIVE_FAILURES -eq 1 ]] && ok "first recoverable block → absorbed (rc=1)" || no "first block absorb (rc=$r cf=$CONSECUTIVE_FAILURES)"

# 4. same reason repeated to BLOCK_CB_THRESHOLD → terminal
CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_block_with_grace "same wall" "metric_failure"   # blocks=1 absorb
_block_with_grace "same wall" "metric_failure"   # blocks=2 absorb
_block_with_grace "same wall" "metric_failure"; r=$?   # blocks=3 → terminal
[[ $r -eq 0 ]] && ok "same reason ×$BLOCK_CB_THRESHOLD → terminal (consecutive-blocks CB now LIVE)" || no "repeat-block terminal (rc=$r blocks=$CONSECUTIVE_BLOCKS)"

# 5. recoverable but CONSECUTIVE_FAILURES already at ceiling → terminal via CB
CONSECUTIVE_FAILURES=5; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_block_with_grace "varied reason A" "metric_failure"; r=$?
[[ $r -eq 0 ]] && ok "recoverable block at CB ceiling → terminal" || no "CB-ceiling block (rc=$r cf=$CONSECUTIVE_FAILURES)"

# 5b. F-22b: a block, then PROGRESS (reset), then the SAME reason must NOT count
# as consecutive — i.e. progress clears CONSECUTIVE_BLOCKS/LAST_BLOCK_REASON.
CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_block_with_grace "wallA" "metric_failure"   # blocks=1 absorb
# simulate a pass/progress reset (mirrors the pass + partial-progress branches)
CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""; CONSECUTIVE_FAILURES=0
_block_with_grace "wallA" "metric_failure"; r=$?   # same reason but AFTER progress → blocks=1 again, absorb
[[ $r -eq 1 && $CONSECUTIVE_BLOCKS -eq 1 ]] && ok "F-22b: progress resets block streak (same reason post-progress → absorbed, blocks=1)" || no "F-22b reset (rc=$r blocks=$CONSECUTIVE_BLOCKS)"
# structural: the pass + partial-progress branches reset CONSECUTIVE_BLOCKS
prog_resets=$(grep -cE 'CONSECUTIVE_BLOCKS=0' "${0:A:h:h:h}/src/scripts/run_ralph_desk.zsh")
[[ "$prog_resets" -ge 2 ]] && ok "F-22b: CONSECUTIVE_BLOCKS reset wired into pass+progress ($prog_resets sites)" || no "F-22b reset sites=$prog_resets (want >=2)"

# ---- structural wiring on the REAL source ----
RUN="${0:A:h:h:h}/src/scripts/run_ralph_desk.zsh"
ccb_calls=$(grep -cE '_check_consecutive_blocks "' "$RUN")
[[ "$ccb_calls" -ge 1 ]] && ok "_check_consecutive_blocks is CALLED (was dead code) — $ccb_calls site(s)" || no "_check_consecutive_blocks still dead (0 calls)"
bwg_calls=$(grep -cE 'if _block_with_grace ' "$RUN")
[[ "$bwg_calls" -ge 2 ]] && ok "_block_with_grace wired into both block paths ($bwg_calls)" || no "_block_with_grace call sites = $bwg_calls (want >=2)"
bump_calls=$(grep -cE 'if _bump_consecutive_failure' "$RUN")
[[ "$bump_calls" -ge 3 ]] && ok "_bump_consecutive_failure wired into request_info+unknown paths ($bump_calls)" || no "_bump call sites = $bump_calls (want >=3)"
grep -qE 'recommended" == \(complete\|completed\|done\)' "$RUN" \
  && ok "F-23: recommended accepts complete|completed|done" || no "F-23 recommended normalization missing"
grep -qE 'signal_us_id="\$\{signal_us_id:u\}"' "$RUN" \
  && ok "F-23: signal_us_id uppercased (all→ALL)" || no "F-23 signal_us_id normalization missing"
# F-25: the buggy `if ! poll…; then local rc=$?` is gone from run_single_verifier
grep -qE 'poll_for_signal .*Verifier\$suffix"$' "$RUN" \
  && ok "F-25: run_single_verifier captures poll rc directly (no if-! wrapper)" || no "F-25 direct rc capture missing"

print ""
if (( FAIL == 0 )); then print -P "%F{green}F-22/F-23/F-25: $PASS/$((PASS+FAIL)) PASS%f"; else print -P "%F{red}F-22/F-23/F-25: $PASS pass, $FAIL FAIL%f"; fi
exit $(( FAIL > 0 ))
