#!/usr/bin/env bash
# Test Suite: US-002 — Consensus Mode Stability
# IL-4 compliant: 3 tests per AC (happy + negative + boundary)
# 8 ACs x 3 = 24 tests total

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local result="$2"
  local expected="$3"
  if [[ "$result" = "$expected" ]]; then
    echo "PASS: $name"
    (( PASS++ ))
  else
    echo "FAIL: $name  (expected='$expected' got='$result')"
    (( FAIL++ ))
  fi
}

# count_grep PATTERN FILE — returns integer count, 0 on no match or missing file
# When FILE is RUN, also searches LIB (lib_ralph_desk.zsh) and sums counts
count_grep() {
  local pattern="$1" file="$2"
  local result
  result=$(grep -c "$pattern" "$file" 2>/dev/null) || result=0
  if [[ "$file" == "$RUN" ]]; then
    local lib_result
    lib_result=$(grep -c "$pattern" "$LIB" 2>/dev/null) || lib_result=0
    result=$(( result + lib_result ))
  fi
  echo "$result"
}

# pipe_count CMD... — runs pipeline, returns wc -l count (safe with pipefail)
pipe_count() {
  "$@" 2>/dev/null | wc -l | tr -d ' '
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="$REPO_ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$REPO_ROOT/src/scripts/lib_ralph_desk.zsh"
CMD="$REPO_ROOT/src/commands/rlp-desk.md"
GOV="$REPO_ROOT/src/governance.md"

echo "=== US-002: Consensus Mode Stability ==="
echo ""

# =============================================================================
# AC1: --cb-threshold option (default 3, help text, tmux env vars)
# =============================================================================

# AC1-happy: --cb-threshold appears in rlp-desk.md options list and help text (>= 3)
count=$(count_grep 'cb-threshold' "$CMD")
run_test "AC1-happy: --cb-threshold in rlp-desk.md >= 3 occurrences" "$(( count >= 3 ))" "1"

# AC1-negative: cb-threshold default is documented as 3
count=$(grep 'cb-threshold' "$CMD" 2>/dev/null | grep -c '3\|default') || count=0
run_test "AC1-negative: cb-threshold default=3 documented in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC1-boundary: CB_THRESHOLD env var defined in run_ralph_desk.zsh (>= 4)
count=$(count_grep 'CB_THRESHOLD' "$RUN")
run_test "AC1-boundary: CB_THRESHOLD in run_ralph_desk.zsh >= 4 occurrences" "$(( count >= 4 ))" "1"

# =============================================================================
# AC2: Consensus auto-double (EFFECTIVE_CB_THRESHOLD = CB_THRESHOLD * 2)
# =============================================================================

# AC2-happy: CB_THRESHOLD * 2 logic present in run_ralph_desk.zsh
count=$(count_grep 'CB_THRESHOLD \* 2\|CB_THRESHOLD\*2' "$RUN")
run_test "AC2-happy: CB_THRESHOLD * 2 auto-double logic in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC2-negative: EFFECTIVE_CB_THRESHOLD NOT referenced inside check_stale_context
_csc_body=$(grep -A 25 '^check_stale_context()' "$RUN" 2>/dev/null)
if [[ -z "$_csc_body" ]]; then _csc_body=$(grep -A 25 '^check_stale_context()' "$LIB" 2>/dev/null); fi
count=$(echo "$_csc_body" | grep -c 'EFFECTIVE_CB_THRESHOLD') || count=0
run_test "AC2-negative: check_stale_context does NOT use EFFECTIVE_CB_THRESHOLD" "$(( count == 0 ))" "1"

# AC2-boundary: EFFECTIVE_CB_THRESHOLD appears >= 3 times in run_ralph_desk.zsh
count=$(count_grep 'EFFECTIVE_CB_THRESHOLD' "$RUN")
run_test "AC2-boundary: EFFECTIVE_CB_THRESHOLD count >= 3 in run_ralph_desk.zsh" "$(( count >= 3 ))" "1"

# =============================================================================
# AC3: --iter-timeout option (default 600, tmux-mode only, Agent non-enforcement)
# =============================================================================

# AC3-happy: --iter-timeout appears >= 3 times in rlp-desk.md
count=$(count_grep 'iter-timeout' "$CMD")
run_test "AC3-happy: --iter-timeout in rlp-desk.md >= 3 occurrences" "$(( count >= 3 ))" "1"

# AC3-negative: Agent mode non-enforcement explicitly documented for iter-timeout
count=$(grep -i 'iter.timeout' "$CMD" 2>/dev/null | grep -ic 'agent.*not\|not.*enfor\|non-enfor\|agent.*no.*timeout') || count=0
run_test "AC3-negative: iter-timeout Agent non-enforcement documented in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC3-boundary: ITER_TIMEOUT default remains 600 in run_ralph_desk.zsh
count=$(count_grep 'ITER_TIMEOUT.*:-600' "$RUN")
run_test "AC3-boundary: ITER_TIMEOUT default is still 600 in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# =============================================================================
# AC4: Consensus round cap 3->6 across all 3 files
# =============================================================================

# AC4-happy: CONSENSUS_ROUND compared against 6 in run_ralph_desk.zsh (>= 2 spots)
count=$(count_grep 'CONSENSUS_ROUND < 6\|CONSENSUS_ROUND >= 6' "$RUN")
run_test "AC4-happy: CONSENSUS_ROUND compared against 6 in run_ralph_desk.zsh" "$(( count >= 2 ))" "1"

# AC4-negative: zero CONSENSUS_ROUND-vs-3 comparisons remain in run_ralph_desk.zsh
count=$(count_grep 'CONSENSUS_ROUND < 3\|CONSENSUS_ROUND >= 3' "$RUN")
run_test "AC4-negative: zero CONSENSUS_ROUND-vs-3 comparisons in run_ralph_desk.zsh" "$(( count == 0 ))" "1"

# AC4-negative-strings: zero hardcoded '3' in consensus failure messages/JSON output
count=$(count_grep 'after 3 round\|"round": 3' "$RUN")
run_test "AC4-negative-strings: zero hardcoded '3' in consensus failure messages" "$(( count == 0 ))" "1"

# AC4-boundary: "Max 6 consensus rounds" in both rlp-desk.md and governance.md
count_cmd=$(count_grep 'Max 6 consensus rounds' "$CMD")
count_gov=$(count_grep 'Max 6 consensus rounds' "$GOV")
run_test "AC4-boundary: 'Max 6 consensus rounds' in rlp-desk.md + governance.md (>= 2 total)" "$(( count_cmd + count_gov >= 2 ))" "1"

# =============================================================================
# AC5: Architecture Escalation uses cb_threshold; Path A Agent-mode-only
# =============================================================================

# AC5-happy: cb_threshold referenced in §7¾ section of governance.md
sec=$(sed -n '/7¾\. Architecture/,/^## 8\./p' "$GOV" 2>/dev/null)
count=$(echo "$sec" | grep -c 'cb_threshold\|CB_THRESHOLD\|consecutive.*threshold') || count=0
run_test "AC5-happy: cb_threshold referenced in §7¾ Architecture Escalation" "$(( count >= 1 ))" "1"

# AC5-negative: §7¾ no longer has hardcoded "3+ consecutive fix" phrasing
count=$(echo "$sec" | grep -c 'If 3+ consecutive fix\|3+ consecutive fix') || count=0
run_test "AC5-negative: §7¾ has no hardcoded '3+ consecutive fix' text" "$(( count == 0 ))" "1"

# AC5-boundary: CB Path A documented as Agent-mode only in governance.md
count=$(count_grep '[Aa]gent.mode only\|[Pp]ath [Aa].*[Aa]gent\|consecutive.*[Aa]gent.mode only' "$GOV")
run_test "AC5-boundary: CB Path A Agent-mode-only documented in governance.md" "$(( count >= 1 ))" "1"

# =============================================================================
# AC6: Stale-context breaker independence (stays at hardcoded 3, no EFFECTIVE_CB_THRESHOLD)
# =============================================================================

# AC6-happy: STALE_CONTEXT_COUNT >= 3 still present (unchanged)
count=$(count_grep 'STALE_CONTEXT_COUNT >= 3' "$RUN")
run_test "AC6-happy: STALE_CONTEXT_COUNT >= 3 unchanged in run_ralph_desk.zsh" "$(( count == 1 ))" "1"

# AC6-negative: check_stale_context function has zero EFFECTIVE_CB_THRESHOLD refs
_csc_body2=$(grep -A 25 '^check_stale_context()' "$RUN" 2>/dev/null)
if [[ -z "$_csc_body2" ]]; then _csc_body2=$(grep -A 25 '^check_stale_context()' "$LIB" 2>/dev/null); fi
count=$(echo "$_csc_body2" | grep -c 'EFFECTIVE_CB_THRESHOLD') || count=0
run_test "AC6-negative: check_stale_context has zero EFFECTIVE_CB_THRESHOLD references" "$(( count == 0 ))" "1"

# AC6-boundary: STALE_CONTEXT_COUNT appears >= 3 times total (init + compare + reset + log)
count=$(count_grep 'STALE_CONTEXT_COUNT' "$RUN")
run_test "AC6-boundary: STALE_CONTEXT_COUNT appears >= 3 times in run_ralph_desk.zsh" "$(( count >= 3 ))" "1"

# =============================================================================
# AC7: CB parameterized via EFFECTIVE_CB_THRESHOLD; session-config includes both vars
# =============================================================================

# AC7-happy: CONSECUTIVE_FAILURES compared to EFFECTIVE_CB_THRESHOLD (not hardcoded)
count=$(count_grep 'CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD' "$RUN")
run_test "AC7-happy: CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC7-negative: no hardcoded CONSECUTIVE_FAILURES >= 3 remains
count=$(count_grep 'CONSECUTIVE_FAILURES >= 3' "$RUN")
run_test "AC7-negative: zero hardcoded CONSECUTIVE_FAILURES >= 3 in run_ralph_desk.zsh" "$(( count == 0 ))" "1"

# AC7-boundary: session-config.json write includes both cb_threshold and effective_cb_threshold
count=$(count_grep '"cb_threshold"\|"effective_cb_threshold"' "$RUN")
run_test "AC7-boundary: session-config.json write has cb_threshold + effective_cb_threshold (>= 2)" "$(( count >= 2 ))" "1"

# =============================================================================
# AC8: ITER_TIMEOUT default 600 preserved (no backward-incompatible change)
# =============================================================================

# AC8-happy: ITER_TIMEOUT default is still 600
count=$(count_grep 'ITER_TIMEOUT.*:-600' "$RUN")
run_test "AC8-happy: ITER_TIMEOUT default 600 preserved in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC8-negative: no ITER_TIMEOUT default other than 600
count=$(( $(grep 'ITER_TIMEOUT:-' "$RUN" 2>/dev/null | grep -v 'ITER_TIMEOUT:-600' | wc -l | tr -d ' ') + $(grep 'ITER_TIMEOUT:-' "$LIB" 2>/dev/null | grep -v 'ITER_TIMEOUT:-600' | wc -l | tr -d ' ') ))
run_test "AC8-negative: no non-600 ITER_TIMEOUT default in run_ralph_desk.zsh" "$(( count == 0 ))" "1"

# AC8-boundary: iter_timeout key still present in session-config.json write block
count=$(count_grep '"iter_timeout"' "$RUN")
run_test "AC8-boundary: iter_timeout key in session-config.json write block" "$(( count >= 1 ))" "1"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed out of $(( PASS + FAIL )) total"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
