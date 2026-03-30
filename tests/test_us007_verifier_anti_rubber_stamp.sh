#!/usr/bin/env bash
# Test suite: US-007 — Claude verifier anti-rubber-stamp guidance
# AC1 (3) + AC2 (3) + AC3 (3) + E2E (3) = 12 total
# RED tests (fail before impl): AC1-happy, AC1-boundary, AC2-happy, AC2-negative, AC2-boundary, E2E-init, E2E-existing
# Regression tests (pass before and after): AC1-negative, AC3-happy, AC3-negative, AC3-boundary, E2E-categories

INIT="${INIT:-src/scripts/init_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-007: Claude verifier anti-rubber-stamp guidance ==="
echo "Target: $INIT"
echo ""

# Extract verifier prompt template section (between # --- Verifier Prompt --- and next # ---)
extract_verifier_prompt() {
  awk '
    /^# --- Verifier Prompt ---/ { in_section=1; next }
    /^# ---/ && in_section { exit }
    in_section { print }
  ' "$INIT"
}

# ============================================================
# AC1: Anti-rubber-stamp guidance in verifier prompt
# ============================================================
echo "--- AC1: Anti-rubber-stamp guidance ---"

# AC1-happy: verifier prompt template contains "100% pass rate" red flag text
# RED before impl: text does not exist yet
test_ac1_happy() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qF '100% pass rate'; then
    pass "AC1-happy: verifier prompt contains '100% pass rate' red flag text"
  else
    fail "AC1-happy: verifier prompt missing '100% pass rate' red flag text"
  fi
}

# AC1-negative: anti-rubber-stamp does NOT contain "always FAIL" directive
# Regression: current template has no "always fail" — must remain true
test_ac1_negative() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qi 'always fail'; then
    fail "AC1-negative: anti-rubber-stamp must NOT direct verifier to always FAIL"
  else
    pass "AC1-negative: no 'always FAIL' directive found (correct)"
  fi
}

# AC1-boundary: exact key phrase "re-examine your last verdict with increased scrutiny"
# RED before impl: phrase does not exist yet
test_ac1_boundary() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qF 're-examine your last verdict with increased scrutiny'; then
    pass "AC1-boundary: exact scrutiny phrase present"
  else
    fail "AC1-boundary: missing 're-examine your last verdict with increased scrutiny'"
  fi
}

# ============================================================
# AC2: Conditional pass (WARN) guidance
# ============================================================
echo ""
echo "--- AC2: Conditional pass (WARN) guidance ---"

# AC2-happy: verifier prompt template contains "PASS with explicit warning"
# RED before impl: text does not exist yet
test_ac2_happy() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qF 'PASS with explicit warning'; then
    pass "AC2-happy: verifier prompt contains 'PASS with explicit warning' guidance"
  else
    fail "AC2-happy: verifier prompt missing 'PASS with explicit warning' guidance"
  fi
}

# AC2-negative: WARN guidance references "concerning patterns" with examples
# RED before impl: text does not exist yet
test_ac2_negative() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qF 'concerning patterns'; then
    pass "AC2-negative: WARN guidance references 'concerning patterns'"
  else
    fail "AC2-negative: WARN guidance missing 'concerning patterns' examples"
  fi
}

# AC2-boundary: "silent PASS" anti-pattern explicitly referenced
# RED before impl: text does not exist yet
test_ac2_boundary() {
  local body
  body=$(extract_verifier_prompt)
  if echo "$body" | grep -qF 'silent PASS'; then
    pass "AC2-boundary: 'silent PASS' anti-pattern referenced"
  else
    fail "AC2-boundary: missing 'silent PASS' anti-pattern reference"
  fi
}

# ============================================================
# AC3: Existing 5 verification categories preserved
# ============================================================
echo ""
echo "--- AC3: Existing 5 categories preserved ---"

# AC3-happy: all 5 categories exist in verifier prompt template
# Regression: all 5 already exist
test_ac3_happy() {
  local body
  body=$(extract_verifier_prompt)
  local has_il1 has_layer has_test_suf has_anti has_worker
  has_il1=$(echo "$body" | grep -c 'IL-1 Evidence Gate')
  has_layer=$(echo "$body" | grep -c 'Layer Enforcement')
  has_test_suf=$(echo "$body" | grep -c 'Test Sufficiency')
  has_anti=$(echo "$body" | grep -c 'Anti-Gaming')
  has_worker=$(echo "$body" | grep -c 'Worker Process Audit')
  if (( has_il1 >= 1 && has_layer >= 1 && has_test_suf >= 1 && has_anti >= 1 && has_worker >= 1 )); then
    pass "AC3-happy: all 5 categories present (IL1=$has_il1, Layer=$has_layer, TestSuf=$has_test_suf, Anti=$has_anti, Worker=$has_worker)"
  else
    fail "AC3-happy: missing categories (IL1=$has_il1, Layer=$has_layer, TestSuf=$has_test_suf, Anti=$has_anti, Worker=$has_worker)"
  fi
}

# AC3-negative: reasoning JSON has all 5 check entries (additive, not replacing)
# Regression: 5 checks already exist
test_ac3_negative() {
  local body
  body=$(extract_verifier_prompt)
  local check_count
  check_count=$(echo "$body" | grep -o '"check":' | wc -l | tr -d ' ')
  if (( check_count >= 5 )); then
    pass "AC3-negative: reasoning JSON has $check_count check entries (>= 5)"
  else
    fail "AC3-negative: reasoning JSON has only $check_count check entries (expected >= 5)"
  fi
}

# AC3-boundary: 4 non-IL1 categories appear in both verification steps AND reasoning JSON
# Regression: dual presence already exists
test_ac3_boundary() {
  local body
  body=$(extract_verifier_prompt)
  local cats=("Layer Enforcement" "Test Sufficiency" "Anti-Gaming" "Worker Process Audit")
  local dual_count=0
  for cat in "${cats[@]}"; do
    local step_count reason_count
    step_count=$(echo "$body" | grep -v '"check"' | grep -c "$cat")
    reason_count=$(echo "$body" | grep '"check"' | grep -c "$cat")
    if (( step_count >= 1 && reason_count >= 1 )); then
      (( dual_count++ ))
    fi
  done
  if (( dual_count >= 4 )); then
    pass "AC3-boundary: $dual_count/4 categories appear in both steps and reasoning JSON"
  else
    fail "AC3-boundary: only $dual_count/4 categories in both steps and reasoning JSON"
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
# E2E: Comprehensive verifier prompt verification
# ============================================================
echo ""
echo "--- E2E: Comprehensive verifier prompt verification ---"

# E2E-init: both anti-rubber-stamp and WARN guidance present in template
# RED before impl: neither text exists yet
test_e2e_init() {
  local body
  body=$(extract_verifier_prompt)
  local has_rubber has_warn
  has_rubber=$(echo "$body" | grep -c '100% pass rate')
  has_warn=$(echo "$body" | grep -c 'PASS with explicit warning')
  if (( has_rubber >= 1 && has_warn >= 1 )); then
    pass "E2E-init: both anti-rubber-stamp ($has_rubber) and WARN guidance ($has_warn) present in template"
  else
    fail "E2E-init: missing content (rubber=$has_rubber, warn=$has_warn)"
  fi
}

# E2E-existing: anti-rubber-stamp text confined to verifier prompt template section only
# RED before impl: text doesn't exist at all (section_count=0)
test_e2e_existing() {
  local total_count section_count
  total_count=$(grep -c '100% pass rate' "$INIT")
  section_count=$(extract_verifier_prompt | grep -c '100% pass rate')
  if (( section_count >= 1 && total_count == section_count )); then
    pass "E2E-existing: anti-rubber-stamp text confined to verifier template (section=$section_count, total=$total_count)"
  else
    fail "E2E-existing: confinement check failed (section=$section_count, total=$total_count)"
  fi
}

# E2E-categories: all 5 mandatory categories confirmed in extracted template
# Regression: all 5 already exist
test_e2e_categories() {
  local body
  body=$(extract_verifier_prompt)
  local found=0
  for cat in "IL-1 Evidence Gate" "Layer Enforcement" "Test Sufficiency" "Anti-Gaming" "Worker Process Audit"; do
    if echo "$body" | grep -qF "$cat"; then
      (( found++ ))
    fi
  done
  if (( found == 5 )); then
    pass "E2E-categories: all 5/5 mandatory categories confirmed in template"
  else
    fail "E2E-categories: only $found/5 mandatory categories found"
  fi
}

test_e2e_init
test_e2e_existing
test_e2e_categories

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
