#!/bin/bash
set -uo pipefail

# =============================================================================
# US-001: Debug Log 4-Category Refactoring — Automated Test Suite
# IL-4: >= 3 tests per AC (happy + negative + boundary)
# 10 ACs x 3 tests minimum = 30 tests
# =============================================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$ROOT/src/commands/rlp-desk.md"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
GOV="$ROOT/src/governance.md"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

grep_count() {
  local n
  n=$(grep -c "$1" "$2" 2>/dev/null) || n=0
  echo "$n"
}
grep_exists() { grep -q "$1" "$2" 2>/dev/null && echo 1 || echo 0; }

assert_eq() {
  local val="$1" expected="$2" label="$3"
  if [[ "$val" -eq "$expected" ]]; then pass "$label"; else fail "$label (got $val, expected $expected)"; fi
}

assert_ge() {
  local val="$1" min="$2" label="$3"
  if [[ "$val" -ge "$min" ]]; then pass "$label"; else fail "$label (got $val, expected >=$min)"; fi
}

assert_zero() {
  local val="$1" label="$2"
  assert_eq "$val" 0 "$label"
}

# =============================================================================
# AC1: rlp-desk.md defines exactly 4 categories, 0 legacy tags
# =============================================================================
test_ac1_four_categories_present() {
  local count; count=$(grep -cE '\[(GOV|DECIDE|OPTION|FLOW)\]' "$CMD" || echo 0)
  assert_ge "$count" 10 "AC1-happy: rlp-desk.md has >=10 new-category references"
}

test_ac1_zero_legacy_in_rlp_desk() {
  local legacy; legacy=$(grep_count '\[PLAN\]\|\[VALIDATE\]\|\[EXEC\]' "$CMD")
  assert_zero "$legacy" "AC1-negative: rlp-desk.md has 0 legacy tags"
}

test_ac1_all_four_category_types_present() {
  local gov dec opt flow
  gov=$(grep_count '\[GOV\]' "$CMD")
  dec=$(grep_count '\[DECIDE\]' "$CMD")
  opt=$(grep_count '\[OPTION\]' "$CMD")
  flow=$(grep_count '\[FLOW\]' "$CMD")
  if [[ "$gov" -ge 1 && "$dec" -ge 1 && "$opt" -ge 1 && "$flow" -ge 1 ]]; then
    pass "AC1-boundary: all 4 category types ([GOV],[DECIDE],[OPTION],[FLOW]) present in rlp-desk.md"
  else
    fail "AC1-boundary: missing category type (GOV=$gov DECIDE=$dec OPTION=$opt FLOW=$flow)"
  fi
}

# =============================================================================
# AC2: debug_log call sites <= 14, [GOV] entries include IL/CB/scope
# =============================================================================
test_ac2_debug_log_count_within_limit() {
  local count; count=$(grep_count 'debug_log' "$CMD")
  if [[ "$count" -le 14 ]]; then pass "AC2-happy: debug_log call sites=$count (<=14)"; else fail "AC2-happy: debug_log call sites=$count (expected <=14)"; fi
}

test_ac2_gov_includes_il_cb_scope() {
  local count; count=$(grep -cE '\[GOV\].*(IL|CB|scope.lock|scope lock|circuit.break)' "$CMD" 2>/dev/null || echo 0)
  assert_ge "$count" 1 "AC2-negative: [GOV] entries include IL/CB/scope checks"
}

test_ac2_no_debug_log_without_debug_flag() {
  local gated; gated=$(grep_count 'if.*--debug\|if.*DEBUG\|if (( DEBUG ))' "$RUN")
  assert_ge "$gated" 1 "AC2-boundary: debug_log calls gated behind --debug flag in runner"
}

# =============================================================================
# AC3: 0 [PLAN] tags remain in run_ralph_desk.zsh
# =============================================================================
test_ac3_no_plan_tags_in_runner() {
  local count; count=$(grep_count '\[PLAN\]' "$RUN")
  assert_zero "$count" "AC3-happy: 0 [PLAN] tags in run_ralph_desk.zsh"
}

test_ac3_flow_tags_replaced_plan() {
  local flow; flow=$(grep_count '\[FLOW\]' "$RUN")
  assert_ge "$flow" 10 "AC3-negative: [FLOW] tags present (replaced [PLAN])"
}

test_ac3_no_plan_in_rlp_desk_either() {
  local count; count=$(grep_count '\[PLAN\]' "$CMD")
  assert_zero "$count" "AC3-boundary: 0 [PLAN] tags in rlp-desk.md either"
}

# =============================================================================
# AC4: 0 [VALIDATE] tags remain in run_ralph_desk.zsh
# =============================================================================
test_ac4_no_validate_tags_in_runner() {
  local count; count=$(grep_count '\[VALIDATE\]' "$RUN")
  assert_zero "$count" "AC4-happy: 0 [VALIDATE] tags in run_ralph_desk.zsh"
}

test_ac4_no_validate_in_any_source_file() {
  local c1 c2 c3 total
  c1=$(grep_count '\[VALIDATE\]' "$CMD"); c2=$(grep_count '\[VALIDATE\]' "$GOV"); c3=$(grep_count '\[VALIDATE\]' "$INIT")
  total=$(( c1 + c2 + c3 ))
  assert_zero "$total" "AC4-negative: 0 [VALIDATE] tags across all other source files"
}

test_ac4_flow_is_replacement_category() {
  local flow; flow=$(grep_count '\[FLOW\]' "$RUN")
  assert_ge "$flow" 10 "AC4-boundary: [FLOW] count=$flow validates [VALIDATE] replacement"
}

# =============================================================================
# AC5: 0 [EXEC] tags remain in run_ralph_desk.zsh
# =============================================================================
test_ac5_no_exec_tags_in_runner() {
  local count; count=$(grep_count '\[EXEC\]' "$RUN")
  assert_zero "$count" "AC5-happy: 0 [EXEC] tags in run_ralph_desk.zsh"
}

test_ac5_gov_and_decide_replaced_exec() {
  local gov; gov=$(grep_count '\[GOV\]' "$RUN")
  local dec; dec=$(grep_count '\[DECIDE\]' "$RUN")
  assert_ge "$gov" 3 "AC5-negative: [GOV] tags (replaced CB/governance [EXEC])"
  assert_ge "$dec" 1 "AC5-negative: [DECIDE] tag (replaced fix_loop [EXEC])"
}

test_ac5_no_exec_in_rlp_desk() {
  local count; count=$(grep_count '\[EXEC\]' "$CMD")
  assert_zero "$count" "AC5-boundary: 0 [EXEC] tags in rlp-desk.md"
}

# =============================================================================
# AC6: >= 3 [OPTION] entries with concrete examples
# =============================================================================
test_ac6_option_count_rlp_desk() {
  local count; count=$(grep_count '\[OPTION\]' "$CMD")
  assert_ge "$count" 3 "AC6-happy: rlp-desk.md has >=$count [OPTION] entries"
}

test_ac6_option_count_runner() {
  local count; count=$(grep_count '\[OPTION\]' "$RUN")
  assert_ge "$count" 3 "AC6-negative: run_ralph_desk.zsh has >=$count [OPTION] entries"
}

test_ac6_concrete_examples_present() {
  local cb; cb=$(grep_exists 'cb_threshold\|CB_THRESHOLD' "$CMD")
  local vm; vm=$(grep_exists 'verify_mode\|VERIFY_MODE' "$CMD")
  local eng; eng=$(grep_exists 'engine.*model\|WORKER_ENGINE\|worker_engine' "$CMD")
  if [[ "$cb" -eq 1 && "$vm" -eq 1 && "$eng" -eq 1 ]]; then
    pass "AC6-boundary: concrete [OPTION] examples (cb_threshold, verify_mode, engine) all present"
  else
    fail "AC6-boundary: missing concrete example (cb=$cb vm=$vm eng=$eng)"
  fi
}

# =============================================================================
# AC7: debug.log versioned to debug-v{N}.log on re-execution
# =============================================================================
test_ac7_versioning_documented_in_rlp_desk() {
  local found; found=$(grep_exists 'debug-v' "$CMD")
  assert_ge "$found" 1 "AC7-happy: debug.log versioning documented in rlp-desk.md"
}

test_ac7_versioning_implemented_in_runner() {
  local found; found=$(grep_count 'dbg_n\|mv.*DEBUG_LOG' "$RUN")
  assert_ge "$found" 1 "AC7-negative: versioning code implemented in run_ralph_desk.zsh"
}

test_ac7_version_counter_increments() {
  local found; found=$(grep_count 'dbg_n' "$RUN")
  assert_ge "$found" 1 "AC7-boundary: version counter (dbg_n) present for N-increment logic"
}

# =============================================================================
# AC8: baseline.log documented as deleted on re-execution
# =============================================================================
test_ac8_baseline_lifecycle_documented() {
  local found; found=$(grep_exists 'baseline.log' "$CMD")
  assert_ge "$found" 1 "AC8-happy: baseline.log lifecycle section exists in rlp-desk.md"
}

test_ac8_deleted_keyword_present() {
  local found; found=$(grep_exists 'baseline.*deleted\|deleted.*baseline' "$CMD")
  assert_ge "$found" 1 "AC8-negative: 'deleted' keyword associated with baseline.log"
}

test_ac8_baseline_not_versioned() {
  local found; found=$(grep_count 'baseline.*v[0-9]' "$CMD")
  assert_zero "$found" "AC8-boundary: baseline.log NOT versioned (only deleted, not renamed)"
}

# =============================================================================
# AC9: 0 legacy tags across ALL 4 source files
# =============================================================================
test_ac9_zero_legacy_all_files() {
  local count; count=$(grep -rn '\[PLAN\]\|\[VALIDATE\]\|\[EXEC\]' "$CMD" "$GOV" "$RUN" "$INIT" 2>/dev/null | wc -l | tr -d ' ')
  assert_zero "$count" "AC9-happy: 0 legacy tags across all 4 source files"
}

test_ac9_governance_clean() {
  local count; count=$(grep_count '\[PLAN\]\|\[VALIDATE\]\|\[EXEC\]' "$GOV")
  assert_zero "$count" "AC9-negative: 0 legacy tags in governance.md"
}

test_ac9_init_clean() {
  local count; count=$(grep_count '\[PLAN\]\|\[VALIDATE\]\|\[EXEC\]' "$INIT")
  assert_zero "$count" "AC9-boundary: 0 legacy tags in init_ralph_desk.zsh"
}

# =============================================================================
# AC10: running without --debug must NOT create debug.log
# =============================================================================
test_ac10_debug_log_gated() {
  local found; found=$(grep_exists 'If.*--debug\|if.*DEBUG\|If \`--debug\`' "$CMD")
  assert_ge "$found" 1 "AC10-happy: debug.log creation documented as gated by --debug"
}

test_ac10_no_unconditional_debug_write() {
  # log_debug must only write inside the if (( DEBUG )) guard
  local ungated; ungated=$(grep_count '^echo.*DEBUG_LOG\|^echo.*debug\.log' "$RUN")
  assert_zero "$ungated" "AC10-negative: no unconditional writes to debug.log"
}

test_ac10_debug_guard_in_log_debug_function() {
  local found; found=$(grep_exists 'if (( DEBUG ))' "$RUN")
  assert_ge "$found" 1 "AC10-boundary: log_debug function has if (( DEBUG )) guard"
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== US-001 Debug Log 4-Category Refactoring — Test Suite ==="
echo ""

for fn in \
  test_ac1_four_categories_present \
  test_ac1_zero_legacy_in_rlp_desk \
  test_ac1_all_four_category_types_present \
  test_ac2_debug_log_count_within_limit \
  test_ac2_gov_includes_il_cb_scope \
  test_ac2_no_debug_log_without_debug_flag \
  test_ac3_no_plan_tags_in_runner \
  test_ac3_flow_tags_replaced_plan \
  test_ac3_no_plan_in_rlp_desk_either \
  test_ac4_no_validate_tags_in_runner \
  test_ac4_no_validate_in_any_source_file \
  test_ac4_flow_is_replacement_category \
  test_ac5_no_exec_tags_in_runner \
  test_ac5_gov_and_decide_replaced_exec \
  test_ac5_no_exec_in_rlp_desk \
  test_ac6_option_count_rlp_desk \
  test_ac6_option_count_runner \
  test_ac6_concrete_examples_present \
  test_ac7_versioning_documented_in_rlp_desk \
  test_ac7_versioning_implemented_in_runner \
  test_ac7_version_counter_increments \
  test_ac8_baseline_lifecycle_documented \
  test_ac8_deleted_keyword_present \
  test_ac8_baseline_not_versioned \
  test_ac9_zero_legacy_all_files \
  test_ac9_governance_clean \
  test_ac9_init_clean \
  test_ac10_debug_log_gated \
  test_ac10_no_unconditional_debug_write \
  test_ac10_debug_guard_in_log_debug_function; do
  $fn
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then exit 1; else exit 0; fi
