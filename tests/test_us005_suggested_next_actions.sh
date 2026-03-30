#!/usr/bin/env bash
# Test suite: US-005 — Campaign Report "Suggested Next Actions" section
# AC1 (3) + AC2 (3) + AC3 (3) + E2E (3) = 12 total
# RED tests (fail before impl): AC1-*, AC2-*, AC3-negative, AC3-boundary, E2E-*
# Regression tests (pass before and after): AC3-happy

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-005: Suggested Next Actions section ==="
echo "Target: $RUN"
echo ""

# Extract generate_campaign_report function body for analysis
extract_gcr_body() {
  awk '
    /^generate_campaign_report\(\) \{/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$RUN"
}

# Extract lines AFTER "## Suggested Next Actions" header from function body
# Before implementation: returns nothing (header absent) → all greps fail correctly
extract_sna_section() {
  extract_gcr_body | awk '
    /## Suggested Next Actions/ { found=1; next }
    found { print }
  '
}

# ============================================================
# AC1: Suggested Next Actions section exists
# ============================================================
echo "--- AC1: Suggested Next Actions section exists ---"

# AC1-happy: function body contains "## Suggested Next Actions" header
test_ac1_happy() {
  local body
  body=$(extract_gcr_body)
  if echo "$body" | grep -qF '## Suggested Next Actions'; then
    pass "AC1-happy: generate_campaign_report contains '## Suggested Next Actions' header"
  else
    fail "AC1-happy: generate_campaign_report missing '## Suggested Next Actions' header"
  fi
}

# AC1-negative: Suggested Next Actions section must not be empty (>= 1 action item)
test_ac1_negative() {
  local sna
  sna=$(extract_sna_section)
  local action_count
  action_count=$(echo "$sna" | grep -c 'echo "- ')
  if (( action_count >= 1 )); then
    pass "AC1-negative: Suggested Next Actions has action items ($action_count)"
  else
    fail "AC1-negative: Suggested Next Actions section empty or missing action items ($action_count)"
  fi
}

# AC1-boundary: section generated for all 3 statuses via conditional logic on final_status
test_ac1_boundary() {
  local body
  body=$(extract_gcr_body)
  # The Suggested Next Actions section must have conditional branches for each status
  # Check for final_status conditionals referencing all three values near action items
  local has_complete has_blocked has_timeout
  has_complete=$(echo "$body" | grep -c '"COMPLETE"')
  has_blocked=$(echo "$body" | grep -c '"BLOCKED"')
  has_timeout=$(echo "$body" | grep -c '"TIMEOUT"')
  # Before implementation: COMPLETE/BLOCKED/TIMEOUT each appear once (in status determination at top)
  # After implementation: each appears at least twice (status determination + Suggested Next Actions logic)
  if (( has_complete >= 2 && has_blocked >= 2 && has_timeout >= 2 )); then
    pass "AC1-boundary: all 3 statuses have conditional branches (COMPLETE=$has_complete, BLOCKED=$has_blocked, TIMEOUT=$has_timeout)"
  else
    fail "AC1-boundary: not all statuses have extra branches (COMPLETE=$has_complete, BLOCKED=$has_blocked, TIMEOUT=$has_timeout; need >= 2 each)"
  fi
}

# ============================================================
# AC2: Status-differentiated action suggestions
# ============================================================
echo ""
echo "--- AC2: Status-differentiated action suggestions ---"

# AC2-happy: COMPLETE actions include forward-looking language (scoped to SNA section)
test_ac2_happy() {
  local sna
  sna=$(extract_sna_section)
  if echo "$sna" | grep -q 'improve\|next feature\|next cycle\|next campaign'; then
    pass "AC2-happy: COMPLETE path includes forward-looking action language"
  else
    fail "AC2-happy: COMPLETE path missing forward-looking action language (improve/next feature/next cycle/next campaign)"
  fi
}

# AC2-negative: BLOCKED actions include diagnostic language (scoped to SNA section)
test_ac2_negative() {
  local sna
  sna=$(extract_sna_section)
  if echo "$sna" | grep -q 'PRD\|verifier criteria\|circuit breaker'; then
    pass "AC2-negative: BLOCKED path includes diagnostic action language"
  else
    fail "AC2-negative: BLOCKED path missing diagnostic action language (PRD/verifier criteria/circuit breaker)"
  fi
}

# AC2-boundary: TIMEOUT actions include continuation language (scoped to SNA section)
test_ac2_boundary() {
  local sna
  sna=$(extract_sna_section)
  if echo "$sna" | grep -q '\-\-max-iter\|max.iter\|scope'; then
    pass "AC2-boundary: TIMEOUT path includes continuation action language"
  else
    fail "AC2-boundary: TIMEOUT path missing continuation action language (--max-iter/scope)"
  fi
}

# ============================================================
# AC3: Existing 8 sections maintained
# ============================================================
echo ""
echo "--- AC3: Existing 8 sections maintained ---"

# AC3-happy: All 8 existing section headers still present in function body
test_ac3_happy() {
  local body
  body=$(extract_gcr_body)
  local sections=("Objective" "Execution Summary" "US Status" "Verification Results" "Issues Encountered" "Cost & Performance" "SV Summary" "Files Changed")
  local missing=0
  local missing_names=""
  for s in "${sections[@]}"; do
    if ! echo "$body" | grep -qF "## $s"; then
      missing_names="${missing_names} '## $s'"
      missing=1
    fi
  done
  if (( missing == 0 )); then
    pass "AC3-happy: all 8 existing sections present"
  else
    fail "AC3-happy: missing sections:$missing_names"
  fi
}

# AC3-negative: Total "## " section count = 9 (8 existing + Suggested Next Actions)
test_ac3_negative() {
  local body
  body=$(extract_gcr_body)
  local count
  count=$(echo "$body" | grep -c 'echo "## ')
  if (( count == 9 )); then
    pass "AC3-negative: total section count = 9 (8 existing + 1 new)"
  else
    fail "AC3-negative: expected 9 section headers, found $count"
  fi
}

# AC3-boundary: "## Suggested Next Actions" appears after "## Files Changed" in function body
test_ac3_boundary() {
  local body
  body=$(extract_gcr_body)
  local fc_line sna_line
  fc_line=$(echo "$body" | grep -n '## Files Changed' | head -1 | cut -d: -f1)
  sna_line=$(echo "$body" | grep -n '## Suggested Next Actions' | head -1 | cut -d: -f1)
  if [[ -n "$fc_line" && -n "$sna_line" ]] && (( sna_line > fc_line )); then
    pass "AC3-boundary: '## Suggested Next Actions' (L$sna_line) after '## Files Changed' (L$fc_line)"
  else
    fail "AC3-boundary: ordering wrong or missing (Files Changed=${fc_line:-missing}, Suggested Next Actions=${sna_line:-missing})"
  fi
}

# Run static analysis tests
test_ac1_happy
test_ac1_negative
test_ac1_boundary

test_ac2_happy
test_ac2_negative
test_ac2_boundary

test_ac3_happy
test_ac3_negative
test_ac3_boundary

# ============================================================
# E2E: Runtime proof — extract generate_campaign_report and run
# ============================================================
echo ""
echo "--- E2E: Runtime campaign report with Suggested Next Actions ---"

GCR_BODY="$(awk '
  /^generate_campaign_report\(\) \{/ { in_fn=1; depth=0 }
  in_fn {
    line = $0
    for (i=1; i<=length(line); i++) {
      c = substr(line, i, 1)
      if (c == "{") depth++
      else if (c == "}") {
        depth--
        if (depth == 0) { print; in_fn=0; next }
      }
    }
    print
  }
' "$RUN")"

if [[ -z "$GCR_BODY" ]]; then
  fail "E2E-extract: could not extract generate_campaign_report() from $RUN"
  fail "E2E-complete: skipped (extract failed)"
  fail "E2E-blocked: skipped (extract failed)"
  fail "E2E-timeout: skipped (extract failed)"
else

E2E_BASE="$(mktemp -d)"
trap 'rm -rf "$E2E_BASE"' EXIT

# Helper: run generate_campaign_report in isolated env with given status
# $1 = status (COMPLETE, BLOCKED, TIMEOUT)
run_gcr_harness() {
  local status="$1"
  local test_dir="$E2E_BASE/$status"
  local logs_dir="$test_dir/logs"
  local plans_dir="$test_dir/plans"
  mkdir -p "$logs_dir" "$plans_dir"

  # Create mock PRD
  printf '## Objective\nTest objective for E2E\n' > "$plans_dir/prd-test-slug.md"

  # Create mock cost-log
  printf '{"iteration":1,"estimated_tokens":1000,"token_source":"estimated"}\n' > "$logs_dir/cost-log.jsonl"

  # Create sentinel based on status
  case "$status" in
    COMPLETE) touch "$test_dir/complete-sentinel" ;;
    BLOCKED)  touch "$test_dir/blocked-sentinel" ;;
    TIMEOUT)  ;; # no sentinel = TIMEOUT
  esac

  # Write harness script
  cat > "$test_dir/harness.zsh" <<HARNESS_EOF
#!/usr/bin/env zsh -f
CAMPAIGN_REPORT_GENERATED=0
COMPLETE_SENTINEL="$test_dir/complete-sentinel"
BLOCKED_SENTINEL="$test_dir/blocked-sentinel"
LOGS_DIR="$logs_dir"
SLUG="test-slug"
START_TIME=\$(( \$(date +%s) - 120 ))
DESK="$test_dir"
COST_LOG="$logs_dir/cost-log.jsonl"
ITERATION=5
MAX_ITER=10
VERIFIED_US="US-001 US-002"
CONSECUTIVE_FAILURES=2
WORKER_MODEL="sonnet"
WORKER_ENGINE="claude"
VERIFIER_MODEL="sonnet"
VERIFIER_ENGINE="claude"
WITH_SELF_VERIFICATION=0
ROOT="$test_dir"
BASELINE_COMMIT="none"
DEBUG=0

log() { : ; }
atomic_write() { local target="\$1"; cat > "\$target"; }

HARNESS_EOF

  printf '%s\n' "$GCR_BODY" >> "$test_dir/harness.zsh"
  printf '\ngenerate_campaign_report\n' >> "$test_dir/harness.zsh"

  # Initialize git repo (for git diff commands in the function)
  (cd "$test_dir" && git init -q && git add -A && git commit -q -m "init" 2>/dev/null) >/dev/null 2>&1

  zsh -f "$test_dir/harness.zsh" >/dev/null 2>&1
  echo "$logs_dir/campaign-report.md"
}

# E2E-complete: COMPLETE status report has forward-looking actions
report_file=$(run_gcr_harness "COMPLETE")
if [[ -f "$report_file" ]] && grep -qF '## Suggested Next Actions' "$report_file"; then
  if grep -q 'improve\|next feature\|next cycle\|next campaign' "$report_file"; then
    pass "E2E-complete: COMPLETE report has Suggested Next Actions with forward-looking actions"
  else
    fail "E2E-complete: Suggested Next Actions present but lacks COMPLETE-specific actions"
  fi
else
  fail "E2E-complete: campaign-report.md missing or lacks '## Suggested Next Actions' (file exists: $(test -f "$report_file" && echo yes || echo no))"
fi

# E2E-blocked: BLOCKED status report has diagnostic actions
report_file=$(run_gcr_harness "BLOCKED")
if [[ -f "$report_file" ]] && grep -qF '## Suggested Next Actions' "$report_file"; then
  if grep -q 'PRD\|verifier criteria\|circuit breaker' "$report_file"; then
    pass "E2E-blocked: BLOCKED report has Suggested Next Actions with diagnostic actions"
  else
    fail "E2E-blocked: Suggested Next Actions present but lacks BLOCKED-specific actions"
  fi
else
  fail "E2E-blocked: campaign-report.md missing or lacks '## Suggested Next Actions' (file exists: $(test -f "$report_file" && echo yes || echo no))"
fi

# E2E-timeout: TIMEOUT status report has continuation actions
report_file=$(run_gcr_harness "TIMEOUT")
if [[ -f "$report_file" ]] && grep -qF '## Suggested Next Actions' "$report_file"; then
  if grep -q '\-\-max-iter\|max.iter\|scope' "$report_file"; then
    pass "E2E-timeout: TIMEOUT report has Suggested Next Actions with continuation actions"
  else
    fail "E2E-timeout: Suggested Next Actions present but lacks TIMEOUT-specific actions"
  fi
else
  fail "E2E-timeout: campaign-report.md missing or lacks '## Suggested Next Actions' (file exists: $(test -f "$report_file" && echo yes || echo no))"
fi

fi  # end if GCR_BODY not empty

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
