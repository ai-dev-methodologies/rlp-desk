#!/usr/bin/env bash
# Test Suite: CB threshold + analytics always-on + SV report path fix
# T1-T2 (CB), T3-T9 (analytics), T10 (SV path) = 10 total

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
LIB="${LIB:-src/scripts/lib_ralph_desk.zsh}"
GOV="${GOV:-src/governance.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== CB threshold + analytics always-on ==="
echo "Target: $RUN, $LIB, $GOV"
echo ""

# ============================================================
# T1: CB_THRESHOLD default is 6
# ============================================================
echo "--- Change 1: CB_THRESHOLD ---"

test_t1_cb_default_6() {
  if grep -q 'CB_THRESHOLD="${CB_THRESHOLD:-6}"' "$RUN"; then
    pass "T1: CB_THRESHOLD default is 6"
  else
    fail "T1: CB_THRESHOLD default should be 6 (found: $(grep 'CB_THRESHOLD="${CB_THRESHOLD:-' "$RUN"))"
  fi
}

# T2: consensus mode doubles CB to 12
test_t2_cb_consensus_doubles() {
  # The doubling logic: EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD * 2 ))
  # With default 6, effective should be 12 when consensus=1
  # We verify the multiplication formula exists and CB default is 6
  local has_double
  has_double=$(grep -c 'EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD \* 2 ))' "$RUN")
  local has_default_6
  has_default_6=$(grep -c 'CB_THRESHOLD="${CB_THRESHOLD:-6}"' "$RUN")
  if (( has_double >= 1 && has_default_6 >= 1 )); then
    pass "T2: consensus mode doubles CB (6*2=12)"
  else
    fail "T2: consensus doubling formula or CB default 6 missing (double=$has_double, default6=$has_default_6)"
  fi
}

# ============================================================
# T3-T9: campaign.jsonl + metadata.json always-on
# ============================================================
echo ""
echo "--- Change 2: analytics always-on ---"

# T3: analytics directory created without debug gating
test_t3_analytics_dir_always() {
  # The mkdir -p "$ANALYTICS_DIR" must NOT be inside a DEBUG/WITH_SELF_VERIFICATION conditional
  # Check: the line "mkdir -p \"$ANALYTICS_DIR\"" should exist WITHOUT being preceded by "if (( DEBUG ))"
  # Strategy: extract the 3 lines around mkdir ANALYTICS_DIR and check no DEBUG conditional
  local context
  context=$(grep -B2 'mkdir -p "\$ANALYTICS_DIR"' "$RUN" 2>/dev/null)
  if echo "$context" | grep -q 'DEBUG\|WITH_SELF_VERIFICATION'; then
    fail "T3: analytics dir creation is still gated by DEBUG/WITH_SELF_VERIFICATION"
  elif echo "$context" | grep -q 'mkdir -p "\$ANALYTICS_DIR"'; then
    pass "T3: analytics dir created without debug gating"
  else
    fail "T3: mkdir ANALYTICS_DIR not found"
  fi
}

# T4: metadata.json written without debug gating
test_t4_metadata_always() {
  # The "metadata.json: write at campaign start" comment and its jq block must NOT be inside DEBUG gating
  # Strategy: find the comment line, check the line AFTER it for if-gating
  local meta_comment_line
  meta_comment_line=$(grep -n 'metadata.json.*write at campaign start' "$RUN" | head -1 | cut -d: -f1)
  if [[ -z "$meta_comment_line" ]]; then
    fail "T4: metadata.json write section comment not found"
    return
  fi
  # Check the line after the comment for DEBUG/WITH_SELF_VERIFICATION gating
  local after
  after=$(sed -n "$((meta_comment_line + 1))p" "$RUN")
  if echo "$after" | grep -q 'DEBUG\|WITH_SELF_VERIFICATION'; then
    fail "T4: metadata.json write is still gated by DEBUG/WITH_SELF_VERIFICATION"
  else
    pass "T4: metadata.json written without debug gating"
  fi
}

# T5: metadata.json includes project_name field
test_t5_metadata_project_name() {
  if grep -q 'project_name' "$RUN"; then
    pass "T5: metadata.json includes project_name field"
  else
    fail "T5: metadata.json missing project_name field"
  fi
}

# T6: write_campaign_jsonl() has no debug gating
test_t6_campaign_jsonl_no_gating() {
  # The function should NOT have the early return guard
  local func_body
  func_body=$(awk '/^write_campaign_jsonl\(\)/{found=1} found{print; if(/^\}/) exit}' "$LIB")
  if echo "$func_body" | grep -q 'DEBUG.*WITH_SELF_VERIFICATION.*return'; then
    fail "T6: write_campaign_jsonl() still has DEBUG gating"
  elif [[ -n "$func_body" ]]; then
    pass "T6: write_campaign_jsonl() has no debug gating"
  else
    fail "T6: write_campaign_jsonl() function not found"
  fi
}

# T7: campaign.jsonl record includes consecutive_failures field
test_t7_campaign_consecutive_failures() {
  local func_body
  func_body=$(awk '/^write_campaign_jsonl\(\)/{found=1} found{print; if(/^\}/) exit}' "$LIB")
  if echo "$func_body" | grep -q 'consecutive_failures'; then
    pass "T7: campaign.jsonl includes consecutive_failures field"
  else
    fail "T7: campaign.jsonl missing consecutive_failures field"
  fi
}

# T8: campaign.jsonl record includes model_upgraded field
test_t8_campaign_model_upgraded() {
  local func_body
  func_body=$(awk '/^write_campaign_jsonl\(\)/{found=1} found{print; if(/^\}/) exit}' "$LIB")
  if echo "$func_body" | grep -q 'model_upgraded'; then
    pass "T8: campaign.jsonl includes model_upgraded field"
  else
    fail "T8: campaign.jsonl missing model_upgraded field"
  fi
}

# T9: campaign.jsonl versioning not gated by DEBUG
test_t9_campaign_versioning_always() {
  # The campaign.jsonl versioning comment should NOT be followed by DEBUG/WITH_SELF gating
  local comment_line
  comment_line=$(grep -n 'campaign.jsonl versioning' "$RUN" | head -1 | cut -d: -f1)
  if [[ -z "$comment_line" ]]; then
    fail "T9: campaign.jsonl versioning comment not found"
    return
  fi
  # Check the line after the comment for DEBUG gating
  local after
  after=$(sed -n "$((comment_line + 1))p" "$RUN")
  if echo "$after" | grep -q 'DEBUG\|WITH_SELF_VERIFICATION'; then
    fail "T9: campaign.jsonl versioning still gated by DEBUG"
  else
    pass "T9: campaign.jsonl versioning not gated by DEBUG"
  fi
}

# ============================================================
# T10: SV report path fix
# ============================================================
echo ""
echo "--- Change 3: SV report path ---"

test_t10_sv_report_reads_logs_dir() {
  # generate_campaign_report should read SV report from $LOGS_DIR, not $ANALYTICS_DIR
  local func_body
  func_body=$(awk '/^generate_campaign_report\(\)/{found=1} found{print; if(/^\}/ && found>1) exit; found++}' "$LIB")
  if echo "$func_body" | grep -q 'ANALYTICS_DIR.*self-verification-report'; then
    fail "T10: SV report read from ANALYTICS_DIR (should be LOGS_DIR)"
  elif echo "$func_body" | grep -q 'LOGS_DIR.*self-verification-report'; then
    pass "T10: SV report read from LOGS_DIR"
  else
    fail "T10: SV report reference not found in generate_campaign_report"
  fi
}

# ============================================================
# Governance doc check
# ============================================================
echo ""
echo "--- Governance doc ---"

test_t11_governance_cb_default() {
  if grep -q 'cb_threshold.*6\|default.*6\|default: 6' "$GOV"; then
    pass "T11: governance §8 mentions CB default 6"
  else
    fail "T11: governance §8 should mention CB default 6"
  fi
}

# ============================================================
# Run all tests
# ============================================================
test_t1_cb_default_6
test_t2_cb_consensus_doubles
test_t3_analytics_dir_always
test_t4_metadata_always
test_t5_metadata_project_name
test_t6_campaign_jsonl_no_gating
test_t7_campaign_consecutive_failures
test_t8_campaign_model_upgraded
test_t9_campaign_versioning_always
test_t10_sv_report_reads_logs_dir
test_t11_governance_cb_default

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $(( FAIL > 0 ? 1 : 0 ))
