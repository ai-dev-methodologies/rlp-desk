#!/usr/bin/env bash
# Test Suite: v0.5.2 improvements
# Item 1: US_FAIL_HISTORY dual counter (D1-D7)
# Item 2: Task size principle in docs (T1-T2)
# Item 3: Spec quality warning, mid-CB warning, failure_category (I1-I4)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
GOV="$ROOT_DIR/src/governance.md"
CMD="$ROOT_DIR/src/commands/rlp-desk.md"

PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Helper: extract function body from lib or run
extract_fn() {
  local fn_name="$1"
  local body
  body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$LIB" 2>/dev/null)
  if [[ -z "$body" ]]; then
    body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$RUN" 2>/dev/null)
  fi
  echo "$body"
}

# Helper: run a zsh harness script
run_harness() {
  local script="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "$script" > "$tmpdir/harness.zsh"
  zsh -f "$tmpdir/harness.zsh" 2>&1
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# ============================================================
# Item 1: US_FAIL_HISTORY dual counter
# ============================================================
echo "=== Item 1: US_FAIL_HISTORY dual counter ==="
echo ""

# D1: US_FAIL_HISTORY associative array declared in run_ralph_desk.zsh
echo "--- D1: Declaration ---"
test_d1_us_fail_history_declared() {
  if grep -q 'typeset -A US_FAIL_HISTORY' "$RUN"; then
    pass "D1: US_FAIL_HISTORY associative array declared"
  else
    fail "D1: typeset -A US_FAIL_HISTORY missing from run_ralph_desk.zsh"
  fi
}

# D2: record_us_failure() function exists in lib
echo "--- D2: record_us_failure function ---"
test_d2_record_function_exists() {
  if grep -qF 'record_us_failure()' "$LIB"; then
    pass "D2: record_us_failure() exists in lib"
  else
    fail "D2: record_us_failure() missing from lib_ralph_desk.zsh"
  fi
}

# D3: record_us_failure increments US_FAIL_HISTORY[us_id]
test_d3_record_increments() {
  local fn_body
  fn_body=$(extract_fn "record_us_failure")
  if [[ -z "$fn_body" ]]; then
    fail "D3: record_us_failure() not found"
    return
  fi
  if echo "$fn_body" | grep -q 'US_FAIL_HISTORY'; then
    pass "D3: record_us_failure uses US_FAIL_HISTORY"
  else
    fail "D3: record_us_failure does not reference US_FAIL_HISTORY"
  fi
}

# D4: Runtime — record_us_failure tracks failures per US
echo "--- D4: Runtime tracking ---"
test_d4_runtime_tracking() {
  local fn_body
  fn_body=$(extract_fn "record_us_failure")
  if [[ -z "$fn_body" ]]; then
    fail "D4: record_us_failure() not found"
    return
  fi
  result=$(run_harness "#!/usr/bin/env zsh -f
typeset -A US_FAIL_HISTORY
log_debug() { : ; }
${fn_body}
record_us_failure 'US-001'
record_us_failure 'US-001'
record_us_failure 'US-003'
if (( US_FAIL_HISTORY[US-001] == 2 && US_FAIL_HISTORY[US-003] == 1 )); then
  exit 0
else
  echo \"US-001=\${US_FAIL_HISTORY[US-001]} US-003=\${US_FAIL_HISTORY[US-003]}\" >&2
  exit 1
fi" 2>&1)
  if (( $? == 0 )); then
    pass "D4: record_us_failure tracks per-US counts correctly"
  else
    fail "D4: tracking incorrect: $result"
  fi
}

# D5: pass verdict does NOT reset US_FAIL_HISTORY
echo "--- D5: Pass does not reset history ---"
test_d5_pass_no_reset() {
  # Check that the pass verdict path does NOT contain US_FAIL_HISTORY reset
  local pass_block
  # Extract the pass) case block from run_ralph_desk.zsh
  pass_block=$(awk '/case "\$verdict" in/,/esac/' "$RUN" | awk '/pass\)/,/;;/' | head -30)
  if echo "$pass_block" | grep -q 'US_FAIL_HISTORY='; then
    fail "D5: pass verdict resets US_FAIL_HISTORY (should not)"
  else
    pass "D5: pass verdict does not reset US_FAIL_HISTORY"
  fi
}

# D6: fail verdict calls record_us_failure
echo "--- D6: Fail calls record ---"
test_d6_fail_calls_record() {
  local fail_block
  fail_block=$(awk '/case "\$verdict" in/,/esac/' "$RUN" | awk '/fail\)/,/;;/')
  if echo "$fail_block" | grep -q 'record_us_failure'; then
    pass "D6: fail verdict calls record_us_failure"
  else
    fail "D6: fail verdict does not call record_us_failure"
  fi
}

# D7: Prior-failure warning logged when US with history fails again
echo "--- D7: Prior-failure warning ---"
test_d7_prior_failure_warning() {
  local fn_body
  fn_body=$(extract_fn "record_us_failure")
  if [[ -z "$fn_body" ]]; then
    fail "D7: record_us_failure() not found"
    return
  fi
  if echo "$fn_body" | grep -q 'prior failure history\|prior_failures\|WARN.*US.*fail.*history'; then
    pass "D7: Prior-failure warning present in record_us_failure"
  else
    fail "D7: No prior-failure warning in record_us_failure"
  fi
}

# D8: campaign.jsonl includes us_fail_history
echo "--- D8: campaign.jsonl includes history ---"
test_d8_campaign_jsonl_history() {
  local fn_body
  fn_body=$(extract_fn "write_campaign_jsonl")
  if [[ -z "$fn_body" ]]; then
    fail "D8: write_campaign_jsonl() not found"
    return
  fi
  if echo "$fn_body" | grep -q 'us_fail_history'; then
    pass "D8: campaign.jsonl includes us_fail_history"
  else
    fail "D8: campaign.jsonl missing us_fail_history field"
  fi
}

# ============================================================
# Item 2: Task size principle
# ============================================================
echo ""
echo "=== Item 2: Task size principle ==="
echo ""

# T1: governance.md mentions comfortable zone / worker capability sizing
echo "--- T1: Governance doc ---"
test_t1_governance_task_size() {
  if grep -qi 'comfortable zone\|smaller than.*worker.*capabilit\|below.*worker.*ceiling\|within comfortable' "$GOV"; then
    pass "T1: governance.md mentions task-size-below-worker-capability principle"
  else
    fail "T1: governance.md missing task size principle"
  fi
}

# T2: rlp-desk.md brainstorm section mentions the principle
echo "--- T2: rlp-desk.md ---"
test_t2_cmd_brainstorm_task_size() {
  if grep -qi 'comfortable zone\|smaller than.*worker.*capabilit\|below.*worker.*ceiling\|within comfortable' "$CMD"; then
    pass "T2: rlp-desk.md mentions task-size-below-worker-capability principle"
  else
    fail "T2: rlp-desk.md missing task size principle in brainstorm section"
  fi
}

# ============================================================
# Item 3: Improvement points
# ============================================================
echo ""
echo "=== Item 3: Improvement points ==="
echo ""

# I1: Spec quality warning — same AC 2x fail suggests IL-2 re-assessment
echo "--- I1: Spec quality warning ---"
test_i1_spec_quality_warning() {
  # check_model_upgrade or nearby code should suggest IL-2 re-assessment
  if grep -q 'IL-2.*re-assess\|spec.*quality.*warn\|AC.*quality.*check\|ambiguity.*re-check' "$LIB"; then
    pass "I1: Spec quality warning present (IL-2 re-assessment suggestion)"
  else
    fail "I1: No spec quality warning when same AC fails repeatedly"
  fi
}

# I2: Mid-CB warning at CB_THRESHOLD / 2
echo "--- I2: Mid-CB warning ---"
test_i2_mid_cb_warning() {
  if grep -q 'mid.*CB\|CB_THRESHOLD.*2\|halfway.*circuit\|EFFECTIVE_CB_THRESHOLD / 2\|EFFECTIVE_CB_THRESHOLD /2' "$RUN"; then
    pass "I2: Mid-CB warning logic present"
  else
    fail "I2: Mid-CB warning at threshold/2 not found"
  fi
}

# I3: Verifier verdict supports failure_category field (documented)
echo "--- I3: failure_category ---"
test_i3_failure_category() {
  if grep -q 'failure_category' "$GOV"; then
    pass "I3: failure_category field documented in governance"
  else
    fail "I3: failure_category field not documented in governance.md"
  fi
}

# I4: Self-verification feedback loop documented
echo "--- I4: SV feedback loop ---"
test_i4_sv_feedback_loop() {
  if grep -qi 'self-verification.*brainstorm\|SV.*report.*brainstorm\|feedback.*loop.*brainstorm\|next.*brainstorm.*report' "$CMD" || \
     grep -qi 'self-verification.*brainstorm\|SV.*report.*brainstorm\|feedback.*loop.*brainstorm\|next.*brainstorm.*report' "$GOV"; then
    pass "I4: SV report → next brainstorm feedback loop documented"
  else
    fail "I4: SV → brainstorm feedback loop not documented"
  fi
}

# ============================================================
# Syntax check
# ============================================================
echo ""
echo "--- Syntax ---"
test_syntax_run() {
  if zsh -n "$RUN" 2>/dev/null; then
    pass "SYN1: run_ralph_desk.zsh syntax OK"
  else
    fail "SYN1: run_ralph_desk.zsh syntax error"
  fi
}

test_syntax_lib() {
  if zsh -n "$LIB" 2>/dev/null; then
    pass "SYN2: lib_ralph_desk.zsh syntax OK"
  else
    fail "SYN2: lib_ralph_desk.zsh syntax error"
  fi
}

# ============================================================
# Run all tests
# ============================================================
test_d1_us_fail_history_declared
test_d2_record_function_exists
test_d3_record_increments
test_d4_runtime_tracking
test_d5_pass_no_reset
test_d6_fail_calls_record
test_d7_prior_failure_warning
test_d8_campaign_jsonl_history
test_t1_governance_task_size
test_t2_cmd_brainstorm_task_size
test_i1_spec_quality_warning
test_i2_mid_cb_warning
test_i3_failure_category
test_i4_sv_feedback_loop
test_syntax_run
test_syntax_lib

echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
